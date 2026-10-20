--[[ RVFinePlank — hold manipulation: calibration, nudging, snapping, reach.

    The game's HandleHandPoseInput(Yaw, Pitch, Fwd) multiplies each axis by an
    unknown sensitivity, clamps it, accumulates into HandEmoteYaw/Pitch/Fwd, then
    pushes the result through Server_SetHandPoseInput. We always drive that
    function rather than writing the accumulators, so clamping and replication
    keep working exactly as shipped.

    The accumulators are named Yaw/Pitch, so they are taken to be degrees; the
    sensitivity we measure is therefore "degrees per unit of input". That makes
    snapping to 15 degrees and nudging by 1 degree meaningful instead of opaque.
--]]

local mathx = require("rvfp_math")
local ue    = require("rvfp_ue")

local M = {}

M.state = {
    sens        = nil,    -- degrees per input unit, measured at runtime
    calibrated  = false,
    calib_note  = "not attempted",
    orig_reach  = nil,
    actions     = 0,
}

local function try(fn, ...)
    local ok, a = pcall(fn, ...)
    if ok then return a end
    return nil
end

-- ------------------------------------------------------------------- reading

function M.hold_flags(char)
    return try(function() return char.IsHolding and true or false end) or false,
           try(function() return char.IsHandPosing and true or false end) or false
end

-- Current pose, in the accumulators' own units (degrees, by the naming).
function M.pose(char)
    return try(function() return char.HandEmoteYaw end),
           try(function() return char.HandEmotePitch end),
           try(function() return char.HandEmoteFwd end)
end

function M.reach(char)
    local v = try(function() return char.LookAtDistanceWhenHoldingItem end)
    if type(v) == "number" then return v end
    return nil
end

-- --------------------------------------------------------------- driving it

-- Raw call into the game's handler. `dy/dp/df` are INPUT units.
local function raw_input(char, dy, dp, df)
    local ok = pcall(function() char:HandleHandPoseInput(dy or 0, dp or 0, df or 0) end)
    if ok then M.state.actions = M.state.actions + 1 end
    return ok
end

M.raw_input = raw_input

--[[ Calibration.

    Apply a known probe, see how far the accumulator moved, then undo the probe.
    If the first direction does not move at all we are probably sitting against
    the game's clamp, so we measure in the other direction instead (which also
    moves us off the clamp) and restore afterwards.

    Returns sens or nil, plus a human-readable note for the HUD/log.
--]]
function M.calibrate(char, probe)
    probe = probe or 0.05
    local st = M.state

    local holding = M.hold_flags(char)
    if not holding then
        st.calib_note = "needs an object in hand"
        return nil, st.calib_note
    end

    local before = select(1, M.pose(char))
    if type(before) ~= "number" then
        st.calib_note = "accumulator unreadable"
        return nil, st.calib_note
    end

    -- attempt 1: positive probe
    if not raw_input(char, probe, 0, 0) then
        st.calib_note = "HandleHandPoseInput call failed"
        return nil, st.calib_note
    end
    local after = select(1, M.pose(char))
    local s = mathx.sensitivity(before, after, probe)

    if s then
        raw_input(char, -probe, 0, 0)          -- undo
        st.sens, st.calibrated = s, true
        st.calib_note = string.format("%.3f deg per unit", s)
        return s, st.calib_note
    end

    -- attempt 2: negative probe (we were likely clamped at the top)
    before = select(1, M.pose(char))
    if not raw_input(char, -probe, 0, 0) then
        st.calib_note = "second probe failed"
        return nil, st.calib_note
    end
    after = select(1, M.pose(char))
    s = mathx.sensitivity(before, after, -probe)

    if s then
        raw_input(char, probe, 0, 0)           -- undo
        st.sens, st.calibrated = s, true
        st.calib_note = string.format("%.3f deg per unit (reverse probe)", s)
        return s, st.calib_note
    end

    st.calib_note = "pose did not respond (clamped both ways, or input ignored)"
    return nil, st.calib_note
end

-- Apply a change in REAL units (degrees / cm). Falls back to passing the value
-- straight through when uncalibrated, so the mod still works, just coarsely.
function M.apply(char, dyaw_deg, dpitch_deg, dfwd_cm)
    local s = M.state.sens
    return raw_input(char,
        mathx.to_input(dyaw_deg   or 0, s),
        mathx.to_input(dpitch_deg or 0, s),
        mathx.to_input(dfwd_cm    or 0, s))
end

-- ------------------------------------------------------------ snap and zero

--[[ Drive one axis to a target value.

    This has to iterate. The game FClamps how much a SINGLE call may contribute
    (the dump shows a clamp on the per-call term, not just on the accumulator), so
    asking for a large delta in one call is silently truncated. Zeroing a pose that
    sits at 45 degrees, or snapping across a wide gap, both exceed that budget.

    Stops when: close enough, out of iterations, or the accumulator stopped moving
    (which means the game's own clamp is refusing to go further — not a failure we
    can do anything about, but we report it rather than spinning).

    Returns reached(bool), iterations, final_value.
--]]
local AXIS_GET = {
    yaw   = function(c) return try(function() return c.HandEmoteYaw end) end,
    pitch = function(c) return try(function() return c.HandEmotePitch end) end,
    fwd   = function(c) return try(function() return c.HandEmoteFwd end) end,
}

function M.drive_axis(char, axis, target, tol, max_iters)
    local get = AXIS_GET[axis]
    if not get then return false, 0, nil end
    tol = tol or 1e-4
    max_iters = max_iters or 16

    local cur = get(char)
    if type(cur) ~= "number" then return false, 0, nil end

    for i = 1, max_iters do
        local d = target - cur
        if math.abs(d) <= tol then return true, i - 1, cur end

        local dy, dp, df = 0, 0, 0
        if     axis == "yaw"   then dy = d
        elseif axis == "pitch" then dp = d
        else                        df = d end
        M.apply(char, dy, dp, df)

        local after = get(char)
        if type(after) ~= "number" then return false, i, cur end
        if math.abs(after - cur) < 1e-9 then
            return false, i, after      -- clamped: cannot get closer
        end
        cur = after
    end
    return math.abs(target - cur) <= tol, max_iters, cur
end

--[[ Snap the pose onto the nearest multiple of `step` degrees.

    Returns applied_yaw_delta, applied_pitch_delta (degrees, 0 when already on the
    grid) so the caller can report what actually happened.
--]]
function M.snap(char, step)
    local yaw, pitch = M.pose(char)
    if type(yaw) ~= "number" or type(pitch) ~= "number" then return nil, nil end

    local ty = mathx.snap_to(yaw, step)
    local tp = mathx.snap_to(pitch, step)
    local dy = (math.abs(ty - yaw)   <= 1e-6) and 0 or (ty - yaw)
    local dp = (math.abs(tp - pitch) <= 1e-6) and 0 or (tp - pitch)
    if dy == 0 and dp == 0 then return 0, 0 end

    if dy ~= 0 then M.drive_axis(char, "yaw",   ty) end
    if dp ~= 0 then M.drive_axis(char, "pitch", tp) end
    return dy, dp
end

-- Return the pose to neutral on every axis.
function M.zero_pose(char)
    local yaw = select(1, M.pose(char))
    if type(yaw) ~= "number" then return false end
    local oky = M.drive_axis(char, "yaw",   0.0)
    local okp = M.drive_axis(char, "pitch", 0.0)
    local okf = M.drive_axis(char, "fwd",   0.0)
    local ny, np, nf = M.pose(char)
    return (oky and okp and okf), ny, np, nf
end

-- ------------------------------------------------------------------- reach

function M.reach_adjust(char, delta, cfg)
    local cur = M.reach(char)
    if not cur then return nil, "LookAtDistanceWhenHoldingItem unreadable" end

    if M.state.orig_reach == nil then M.state.orig_reach = cur end

    local want = mathx.clamp(cur + delta, cfg.reach_min, cfg.reach_max)
    local ok = pcall(function() char.LookAtDistanceWhenHoldingItem = want end)
    if not ok then return nil, "write failed" end

    local now = M.reach(char)
    if now and math.abs(now - want) > 0.001 then
        return nil, string.format("write did not stick (wanted %.1f, read %.1f)", want, now)
    end
    return want, nil
end

function M.reach_restore(char)
    if M.state.orig_reach == nil then return nil, "never modified" end
    local ok = pcall(function() char.LookAtDistanceWhenHoldingItem = M.state.orig_reach end)
    if not ok then return nil, "restore failed" end
    return M.state.orig_reach, nil
end

function M.reset(char)
    local restored = select(1, M.reach_restore(char))
    M.state.orig_reach = nil
    return restored
end

return M
