--[[ RVFinePlank — feedback: on-screen readout and world-space alignment guides.

    The point of this module is that precision needs *information*, not smaller
    increments. Two channels:

      HUD     numbers for the things you cannot eyeball — exact yaw/pitch offsets,
              how many degrees off level the plank actually is, the live reach.
              One PrintString with a stable Key, so it refreshes in place instead
              of scrolling.

      GUIDES  an oriented footprint box (DrawDebugBox takes a rotation, so it
              shows the real volume), the plank's long axis projected out to where
              it points, and a level reference line along the same heading with
              zero pitch — the gap between those two lines *is* your tilt error.
--]]

local mathx = require("rvfp_math")
local ue    = require("rvfp_ue")

local M = {}

M.state = {
    hud_ok      = nil,   -- nil = untested, false = unavailable
    draw_ok     = nil,
    last_hud    = 0.0,
    warned      = false,
}

local LEVEL_TOLERANCE = 1.5   -- degrees; below this we call it flat and go green

-- ------------------------------------------------------------------ readout

--[[ Build the readout text. Pure string assembly, so it is testable without UE.

    `info` is a plain table so the caller decides where the numbers come from:
      holding, posing, fine, snap, snap_deg, sens, calib_note,
      yaw, pitch, fwd, reach, orig_reach, off_level, frozen
--]]
function M.format_hud(info, cfg)
    local L = {}

    local mode = {}
    if info.fine   then mode[#mode + 1] = "FINE x" .. mathx.fmt(cfg.fine_scale, 2) end
    if info.snap   then mode[#mode + 1] = "SNAP " .. mathx.fmt(cfg.snap_deg, 0) .. "d" end
    if info.frozen then mode[#mode + 1] = "FROZEN" end
    if #mode == 0 then mode[1] = "normal" end
    L[#L + 1] = "RVFinePlank  [" .. table.concat(mode, "  ") .. "]"

    if not info.holding then
        L[#L + 1] = "  nothing in hand"
        return table.concat(L, "\n")
    end

    L[#L + 1] = string.format("  yaw %s   pitch %s   push %s",
        mathx.fmt(info.yaw or 0, 2), mathx.fmt(info.pitch or 0, 2), mathx.fmt(info.fwd or 0, 2))

    if info.off_level ~= nil then
        local tag = (info.off_level <= LEVEL_TOLERANCE) and "LEVEL" or "off"
        L[#L + 1] = string.format("  tilt %s deg  (%s)", mathx.fmt(info.off_level, 1), tag)
    end

    if info.reach then
        local stock = info.orig_reach and (" / stock " .. mathx.fmt(info.orig_reach, 0)) or ""
        L[#L + 1] = string.format("  reach %s cm%s", mathx.fmt(info.reach, 0), stock)
    end

    if not info.posing then
        L[#L + 1] = "  (hand mode off — the game may ignore pose input)"
    end

    if info.sens then
        L[#L + 1] = string.format("  cal %s", info.calib_note or "ok")
    else
        L[#L + 1] = "  UNCALIBRATED — steps are raw input units"
    end

    return table.concat(L, "\n")
end

function M.show(info, cfg)
    if M.state.hud_ok == false then return false end
    local text = M.format_hud(info, cfg)
    local colour = ue.color.white
    if info.off_level ~= nil then
        colour = (info.off_level <= LEVEL_TOLERANCE) and ue.color.green or ue.color.amber
    end
    local ok = ue.print_screen(text, (cfg.hud_interval or 0.1) + 0.15, "rvfp_hud", colour)
    M.state.hud_ok = ok
    return ok
end

-- ------------------------------------------------------------------- guides

--[[ Draw the alignment guides around the held actor.

    Returns the number of primitives drawn, so a caller (or a test) can tell the
    difference between "drew nothing because there is nothing to draw" and
    "drawing is unavailable".
--]]
function M.draw_guides(actor, cfg)
    if M.state.draw_ok == false then return 0 end
    if not actor then return 0 end

    local xf = ue.actor_transform(actor)
    if not xf then return 0 end
    local fwd = ue.actor_forward(actor)
    local ext = ue.actor_extent(actor)
    local drawn = 0
    local dur = (cfg.guide_interval or 0.05) + 0.02

    local tilt = mathx.off_level(xf.rot.Pitch, xf.rot.Roll)
    local axis_colour = (tilt <= LEVEL_TOLERANCE) and ue.color.green or ue.color.amber

    -- 1. oriented footprint: the actual volume, at the actual rotation
    if ext then
        if ue.draw_box(xf.loc, ext, axis_colour, xf.rot, dur, 2.0) then drawn = drawn + 1 end
    end

    -- 2. the plank's long axis, projected out to where it is pointing
    if fwd then
        local a, b = mathx.axis_endpoints(xf.loc, fwd, cfg.guide_length or 600.0)
        if ue.draw_line(a, b, axis_colour, dur, 2.0) then drawn = drawn + 1 end

        -- 3. level reference: same heading, zero pitch. The visible gap between
        --    this and the axis line above is exactly the tilt error.
        local yaw_rad = math.rad(xf.rot.Yaw or 0)
        local flat = { X = math.cos(yaw_rad), Y = math.sin(yaw_rad), Z = 0.0 }
        local c, d = mathx.axis_endpoints(xf.loc, flat, cfg.guide_length or 600.0)
        if ue.draw_line(c, d, ue.color.blue, dur, 1.0) then drawn = drawn + 1 end
    end

    -- 4. plumb lines from each end, so you can see whether the ends are actually
    --    over the ledges rather than over the gap
    if fwd and ext then
        local half = math.max(ext.X or 0, ext.Y or 0)
        for _, s in ipairs({ -1, 1 }) do
            local e = {
                X = xf.loc.X + fwd.X * half * s,
                Y = xf.loc.Y + fwd.Y * half * s,
                Z = xf.loc.Z + fwd.Z * half * s,
            }
            local below = { X = e.X, Y = e.Y, Z = e.Z - (cfg.plumb_length or 300.0) }
            if ue.draw_line(e, below, ue.color.grey, dur, 1.0) then drawn = drawn + 1 end
        end
    end

    if drawn == 0 then M.state.draw_ok = false end
    return drawn
end

function M.clear_warnings()
    M.state.hud_ok, M.state.draw_ok, M.state.warned = nil, nil, false
end

M.LEVEL_TOLERANCE = LEVEL_TOLERANCE

return M
