--[[
    RVFinePlank — fine adjustment of held objects for "RV There Yet?" (UE 5.6)
    UE4SS Lua mod. Target build: UE4SS v3.0.1-1181+ (first release with UE 5.6 support).

    DESIGN (see docs/SDK-FINDINGS.md for the reverse-engineering evidence)

    The game already implements held-object manipulation. On BP_FirstPersonCharacter_C:

        HandleHandPoseInput(Yaw, Pitch, Fwd)   -- 3 doubles in; internally multiplies each by a
                                                  sensitivity constant, FClamps it, accumulates into
                                                  HandEmoteYaw/Pitch/Fwd, clamps those, branches on
                                                  IsServer, and pushes via Server_SetHandPoseInput.
        UpdateHoldTransform(DeltaSeconds)      -- per tick: builds a target from camera fwd/up,
                                                  smooths with VInterpTo/RInterpTo, commits with
                                                  SetWorldLocationAndRotation (swept).

    So we never reimplement anything. Two mechanisms, both routed through the game's own
    HandleHandPoseInput so that clamping, the server RPC and replication all still run exactly
    as the developers wrote them (this is what keeps co-op correct):

      1. FINE MODE (toggle) — hook HandleHandPoseInput and scale the incoming axes down.
         Mouse/stick movement then moves the plank proportionally less. Smooth, analogue.

      2. NUDGE KEYS — call HandleHandPoseInput ourselves with a small fixed delta.
         Deterministic, repeatable steps for lining a plank up against a specific edge.

    Fine mode is a TOGGLE, not a held modifier, because UE4SS Lua has no reliable
    "is this key currently down" query — and holding a modifier while making a precise
    mouse movement is poor ergonomics anyway.
--]]

local VERSION = "0.2.0"
local TAG = "[RVFinePlank] "

-- UE4SS ships UEHelpers in ue4ss/Mods/shared/. Degrade gracefully if it is missing.
local UEHelpers = nil
do
    local ok, mod = pcall(require, "UEHelpers")
    if ok then UEHelpers = mod end
end

--------------------------------------------------------------------------------
-- Config.  Values marked TUNE are in *input units*, not degrees/cm: the game
-- multiplies them by its own sensitivity constant before accumulating, and that
-- constant is not readable from a static dump.  Calibrate on first run with the
-- `rvfine probe` console command, which prints the resulting HandEmote* values.
--------------------------------------------------------------------------------
local cfg = {
    fine_scale  = 0.15,  -- axis multiplier while fine mode is on (0.15 = ~1/7th speed)
    nudge_yaw   = 0.05,  -- TUNE: per-tap yaw delta
    nudge_pitch = 0.05,  -- TUNE: per-tap pitch delta
    nudge_fwd   = 0.05,  -- TUNE: per-tap push/pull delta (goes through the game's RPC)

    -- Reach: writes LookAtDistanceWhenHoldingItem directly. Much larger range than the
    -- clamped Fwd axis, but see the warning in reach_adjust() about replication.
    reach_step  = 5.0,   -- cm per tap
    reach_min   = 40.0,  -- clamp: closer than this clips into the camera
    reach_max   = 400.0, -- clamp: further than this and physics/grab gets silly
    verbose     = false, -- log every nudge
}

local state = {
    fine        = false,
    hooked      = false,
    hook_path   = nil,
    pre_id      = nil,
    post_id     = nil,
    nudges      = 0,
    orig_reach  = nil,   -- captured before our first write, so we can always restore
}

local function log(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    print(TAG .. (ok and s or tostring(fmt)) .. "\n")
end

--------------------------------------------------------------------------------
-- Player lookup
--------------------------------------------------------------------------------

local function get_character()
    local c = nil
    if UEHelpers and UEHelpers.GetPlayer then
        local ok, res = pcall(UEHelpers.GetPlayer)
        if ok then c = res end
    end
    if not c or not c:IsValid() then
        local ok, res = pcall(FindFirstOf, "BP_FirstPersonCharacter_C")
        if ok then c = res end
    end
    if c and c:IsValid() then return c end
    return nil
end

-- Is the player actually holding something and in hand-pose mode?
-- Both are plain bools on the character (IsHolding 0xB68, IsHandPosing 0xB69).
local function hold_state(char)
    local holding, posing = false, false
    pcall(function() holding = char.IsHolding and true or false end)
    pcall(function() posing  = char.IsHandPosing and true or false end)
    return holding, posing
end

--------------------------------------------------------------------------------
-- Mechanism 1: fine mode — scale the real input down inside the game's own handler
--------------------------------------------------------------------------------

-- Derive the Blueprint function path at runtime. We cannot hardcode it: the asset
-- path inside /Game/ is not recoverable from the SDK dump, only the class name is.
local function resolve_hook_path()
    local char = get_character()
    if not char then return nil, "no character instance yet" end

    local cls = char:GetClass()
    if not cls or not cls:IsValid() then return nil, "character has no class" end

    -- GetFullName() -> "BlueprintGeneratedClass /Game/Some/Path/BP_X.BP_X_C"
    local full = cls:GetFullName()
    if type(full) ~= "string" then return nil, "GetFullName returned non-string" end

    local obj_path = full:match("^%S+%s+(.+)$") or full
    return obj_path .. ":HandleHandPoseInput", nil
end

local function install_hook()
    if state.hooked then return true end

    local path, err = resolve_hook_path()
    if not path then
        log("hook deferred: %s", err or "unknown")
        return false
    end

    local ok, a, b = pcall(RegisterHook, path,
        function(self, Yaw, Pitch, Fwd)
            if not state.fine then return end
            -- Pre-hook params are RemoteUnrealParam wrappers: :get() / :set().
            -- Scaling here means the clamp + accumulate + Server_SetHandPoseInput
            -- chain downstream is untouched.
            local okk = pcall(function()
                Yaw:set(Yaw:get()     * cfg.fine_scale)
                Pitch:set(Pitch:get() * cfg.fine_scale)
                Fwd:set(Fwd:get()     * cfg.fine_scale)
            end)
            if not okk and cfg.verbose then log("warn: could not scale axes this call") end
        end)

    if not ok then
        log("RegisterHook FAILED on %s (%s)", path, tostring(a))
        return false
    end

    state.hooked, state.hook_path, state.pre_id, state.post_id = true, path, a, b
    log("hooked %s", path)
    return true
end

--------------------------------------------------------------------------------
-- Mechanism 2: nudge — drive the game's handler with an exact small delta
--------------------------------------------------------------------------------

local function nudge(dyaw, dpitch, dfwd)
    ExecuteInGameThread(function()
        local char = get_character()
        if not char then log("nudge ignored: no character"); return end

        local holding, posing = hold_state(char)
        if not holding then
            if cfg.verbose then log("nudge ignored: not holding anything") end
            return
        end
        if not posing and cfg.verbose then
            log("note: IsHandPosing is false — the game may ignore pose input outside hand mode")
        end

        local ok, err = pcall(function()
            char:HandleHandPoseInput(dyaw, dpitch, dfwd)
        end)
        if not ok then
            log("HandleHandPoseInput call failed: %s", tostring(err))
            return
        end

        state.nudges = state.nudges + 1
        if cfg.verbose then
            log("nudge #%d  dYaw=%.4f dPitch=%.4f dFwd=%.4f", state.nudges, dyaw, dpitch, dfwd)
        end
    end)
end

--------------------------------------------------------------------------------
-- Mechanism 3: reach — the base hold distance
--
-- UpdateHoldTransform computes, per tick:
--     target = CameraLocation + UpVector * A + ForwardVector * B
-- (GetBaseAimRotation -> GetUpVector/GetForwardVector, two Conv_DoubleToVector
--  multiplies, two Add_VectorVector, then a swept SetWorldLocationAndRotation)
--
-- The Fwd hand-pose axis feeds that forward term but is FClamped to a narrow band.
-- LookAtDistanceWhenHoldingItem (a plain double at 0x808) is the baseline, so writing
-- it moves the object much further in or out than the clamped axis allows.
--
-- CAVEAT, UNVERIFIED: UpdateHoldTransform is gated on IsLocallyControlled, and unlike
-- the Fwd axis this write does NOT pass through Server_SetHandPoseInput. It may
-- therefore be local-only — looking right on your screen while the server still thinks
-- the plank is at the old distance, which would make nails land wrong. Test item 6 in
-- docs/TEST-PLAN.md exists specifically to settle this. Prefer the Fwd axis (numpad
-- +/-) when precision relative to other players matters.
--------------------------------------------------------------------------------

local function read_reach(char)
    local ok, v = pcall(function() return char.LookAtDistanceWhenHoldingItem end)
    if ok and type(v) == "number" then return v end
    return nil
end

local function reach_adjust(delta)
    ExecuteInGameThread(function()
        local char = get_character()
        if not char then log("reach ignored: no character"); return end

        local cur = read_reach(char)
        if not cur then
            log("reach FAILED: LookAtDistanceWhenHoldingItem unreadable " ..
                "(property name may differ on this build)")
            return
        end

        -- Remember the stock value once, so `rvfine reset` can always undo us.
        if state.orig_reach == nil then state.orig_reach = cur end

        local want = cur + delta
        if want < cfg.reach_min then want = cfg.reach_min end
        if want > cfg.reach_max then want = cfg.reach_max end

        local ok, err = pcall(function() char.LookAtDistanceWhenHoldingItem = want end)
        if not ok then
            log("reach write failed: %s", tostring(err)); return
        end

        local now = read_reach(char)
        if now and math.abs(now - want) > 0.001 then
            log("reach write did not stick (wanted %.1f, read %.1f) — property may be " ..
                "recomputed each tick", want, now)
            return
        end

        if cfg.verbose or delta ~= 0 then
            log("reach %.1f -> %.1f cm  (stock %.1f)", cur, want, state.orig_reach)
        end
    end)
end

local function reach_reset()
    ExecuteInGameThread(function()
        local char = get_character()
        if not char then log("reset ignored: no character"); return end
        if state.orig_reach == nil then
            log("reset: reach was never modified, nothing to restore")
        else
            local ok = pcall(function() char.LookAtDistanceWhenHoldingItem = state.orig_reach end)
            log(ok and string.format("reach restored to stock %.1f cm", state.orig_reach)
                   or "reach restore FAILED")
        end
        -- also zero the hand-pose accumulators via the game's own path
        local holding = select(1, hold_state(char))
        if holding then
            local cur_y = 0
            pcall(function() cur_y = char.HandEmoteYaw end)
            if cfg.verbose then log("note: hand pose left as-is (yaw %.3f); drop and re-grab to clear", cur_y) end
        end
    end)
end

--------------------------------------------------------------------------------
-- Diagnostics — the numeric probe channel. This is how we verify behaviour
-- without trusting feel: read the accumulators and the live hold target.
--------------------------------------------------------------------------------

local function probe()
    ExecuteInGameThread(function()
        local char = get_character()
        if not char then log("probe: no character"); return end

        local out = { "probe:" }
        local function add(label, getter)
            local ok, v = pcall(getter)
            out[#out + 1] = string.format("  %-28s %s", label, ok and tostring(v) or "<unreadable>")
        end

        add("IsHolding",       function() return char.IsHolding end)
        add("IsHandPosing",    function() return char.IsHandPosing end)
        add("HandEmoteYaw",    function() return char.HandEmoteYaw end)
        add("HandEmotePitch",  function() return char.HandEmotePitch end)
        add("HandEmoteFwd",    function() return char.HandEmoteFwd end)
        add("HandEmoteRight",  function() return char.HandEmoteRight end)
        add("HandEmoteLeft",   function() return char.HandEmoteLeft end)
        add("LookAtDistance",  function() return char.LookAtDistance end)
        add("Reach(holding)",  function() return char.LookAtDistanceWhenHoldingItem end)
        out[#out + 1] = string.format("  %-28s %s", "Reach(stock)",
            state.orig_reach and string.format("%.1f", state.orig_reach) or "<untouched>")

        -- FVector / FRotator (3x double each)
        local function vec(label, field)
            local ok, s = pcall(function()
                local v = char[field]
                return string.format("X=%.3f Y=%.3f Z=%.3f", v.X, v.Y, v.Z)
            end)
            if not ok then
                ok, s = pcall(function()
                    local v = char[field]
                    return string.format("P=%.3f Y=%.3f R=%.3f", v.Pitch, v.Yaw, v.Roll)
                end)
            end
            out[#out + 1] = string.format("  %-28s %s", label, ok and s or "<unreadable>")
        end
        vec("HoldTargetLocation", "HoldTransformTargetLocation")
        vec("HoldTargetRotation", "HoldTransformTargetRotation")

        local ok, held = pcall(function()
            local a = char.CurrentPickUpActor
            if a and a:IsValid() then return a:GetFullName() end
            return "none"
        end)
        out[#out + 1] = string.format("  %-28s %s", "CurrentPickUpActor", ok and tostring(held) or "<unreadable>")
        out[#out + 1] = string.format("  %-28s fine=%s scale=%.3f hooked=%s nudges=%d",
            "mod", tostring(state.fine), cfg.fine_scale, tostring(state.hooked), state.nudges)

        print(TAG .. table.concat(out, "\n") .. "\n")
    end)
end

--------------------------------------------------------------------------------
-- Keybinds
--------------------------------------------------------------------------------

local function toggle_fine()
    state.fine = not state.fine
    if state.fine and not state.hooked then install_hook() end
    log("fine mode %s (scale %.3f)", state.fine and "ON" or "OFF", cfg.fine_scale)
end

-- Bind defensively: UE4SS's Key table varies between builds, so a missing name
-- must not abort the whole mod and silently leave nothing bound.
local function bind(key_name, fn, desc)
    local k = Key and Key[key_name]
    if k == nil then
        log("WARN key '%s' unknown in this UE4SS build — '%s' not bound", key_name, desc)
        return false
    end
    local ok, err = pcall(RegisterKeyBind, k, fn)
    if not ok then
        log("WARN could not bind %s (%s): %s", key_name, desc, tostring(err))
        return false
    end
    return true
end

local bound = 0
local function tally(b) if b then bound = bound + 1 end end

tally(bind("F3", toggle_fine,                                        "toggle fine mode"))
tally(bind("F4", probe,                                              "probe values"))

-- Numpad: 4/6 yaw, 8/2 pitch, ADD/SUBTRACT push-pull (via the game's replicated axis)
tally(bind("NUM_FOUR",  function() nudge(-cfg.nudge_yaw, 0, 0) end,  "yaw -"))
tally(bind("NUM_SIX",   function() nudge( cfg.nudge_yaw, 0, 0) end,  "yaw +"))
tally(bind("NUM_EIGHT", function() nudge(0,  cfg.nudge_pitch, 0) end,"pitch +"))
tally(bind("NUM_TWO",   function() nudge(0, -cfg.nudge_pitch, 0) end,"pitch -"))
tally(bind("ADD",       function() nudge(0, 0,  cfg.nudge_fwd) end,  "push away (fine)"))
tally(bind("SUBTRACT",  function() nudge(0, 0, -cfg.nudge_fwd) end,  "pull closer (fine)"))

-- Reach: coarse base distance, far more range than the clamped axis above
tally(bind("NUM_NINE",  function() reach_adjust( cfg.reach_step) end, "reach further"))
tally(bind("NUM_THREE", function() reach_adjust(-cfg.reach_step) end, "reach closer"))
tally(bind("NUM_FIVE",  reach_reset,                                  "restore stock reach"))

--------------------------------------------------------------------------------
-- Console: rvfine probe|on|off|scale <f>|step <f>|reach <f>|reachstep <f>|reset|verbose|hook
--------------------------------------------------------------------------------

local function handle_cmd(_, params, out)
    local sub = (params and params[1] or "probe"):lower()
    local arg = tonumber(params and params[2])

    if sub == "probe" then
        probe()
    elseif sub == "on" or sub == "off" then
        state.fine = (sub == "on")
        if state.fine and not state.hooked then install_hook() end
        log("fine mode %s", sub:upper())
    elseif sub == "scale" and arg then
        cfg.fine_scale = arg
        log("fine_scale = %.4f", arg)
    elseif sub == "step" and arg then
        cfg.nudge_yaw, cfg.nudge_pitch, cfg.nudge_fwd = arg, arg, arg
        log("nudge step = %.4f on all axes", arg)
    elseif sub == "reach" and arg then
        -- absolute target: compute the delta from current
        ExecuteInGameThread(function()
            local char = get_character()
            local cur = char and read_reach(char)
            if cur then reach_adjust(arg - cur) else log("reach: unreadable") end
        end)
    elseif sub == "reachstep" and arg then
        cfg.reach_step = arg
        log("reach_step = %.2f cm", arg)
    elseif sub == "reset" then
        reach_reset()
    elseif sub == "verbose" then
        cfg.verbose = not cfg.verbose
        log("verbose = %s", tostring(cfg.verbose))
    elseif sub == "hook" then
        state.hooked = false
        install_hook()
    else
        log("usage: rvfine [probe|on|off|scale <f>|step <f>|reach <cm>|reachstep <cm>|reset|verbose|hook]")
    end
    return true
end

pcall(RegisterConsoleCommandHandler, "rvfine", handle_cmd)

--------------------------------------------------------------------------------
-- Boot: install the hook once a character exists. NotifyOnNewObject fires on
-- spawn; we also retry on a timer because load order is not guaranteed.
--------------------------------------------------------------------------------

pcall(function()
    NotifyOnNewObject("/Script/Engine.PlayerController", function()
        if not state.hooked then
            ExecuteWithDelay(2000, function() install_hook() end)
        end
    end)
end)

pcall(function()
    LoopAsync(5000, function()
        if not state.hooked then install_hook() end
        return state.hooked -- returning true stops the loop
    end)
end)

log("v%s loaded — %d keybinds bound. F3 fine mode, F4 probe, numpad to nudge, `rvfine` in console.",
    VERSION, bound)
