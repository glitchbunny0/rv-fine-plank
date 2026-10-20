--[[ RVFinePlank — precise placement of held objects in "RV There Yet?" (UE 5.6)

    UE4SS Lua mod. Target: UE4SS v3.0.1-1181+ (first build with UE 5.6 support).

    WHY THIS EXISTS, AND WHAT ACTUALLY MAKES PLACEMENT HARD

    The game holds objects at  target = CameraLocation + Up*A + Forward*B, smoothed
    with VInterpTo/RInterpTo. Three consequences drive this mod's design:

      1. The object is welded to your view. Moving it moves your view OF it, so you
         can never hold it still and inspect the alignment from elsewhere.
      2. The object always lags toward its target, so what you see is not where it
         will come to rest.
      3. You have no numbers — only vibes.

    Smaller increments barely touch any of that, which is why this mod leads with
    information (HUD, world guides), structure (snapping, levelling) and real units
    (runtime calibration), and treats fine mode as the last-millimetre tool it is.

    Everything that changes the object goes through the game's own
    HandleHandPoseInput, so clamping, the Server_SetHandPoseInput RPC and
    replication all still run as shipped — which is what keeps co-op correct.

    See docs/SDK-FINDINGS.md for the reverse-engineering evidence.
--]]

local VERSION = "0.3.0"
local TAG = "[RVFinePlank] "

-- ------------------------------------------------------------- module loading
-- Put this script's own directory on package.path first, so that both this file
-- and the modules it loads can use plain require(). UE4SS's package.path setup
-- varies between builds, so we do not rely on it.
do
    local src = debug.getinfo(1, "S").source
    local dir = src and src:match("^@(.*[/\\])") or nil
    if dir then package.path = dir .. "?.lua;" .. package.path end
end

local function need(name)
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then return mod end
    -- fallback: load straight off disk next to this script
    local src = debug.getinfo(1, "S").source
    local dir = src and src:match("^@(.*[/\\])") or ""
    local ok2, mod2 = pcall(dofile, dir .. name .. ".lua")
    if ok2 and type(mod2) == "table" then return mod2 end
    print(TAG .. "FATAL: cannot load module '" .. name .. "' (" ..
          tostring(mod) .. " / " .. tostring(mod2) .. ")\n")
    return nil
end

local cfg   = need("rvfp_config")
local mathx = need("rvfp_math")
local ue    = need("rvfp_ue")
local hold  = need("rvfp_hold")
local hud   = need("rvfp_hud")

if not (cfg and mathx and ue and hold and hud) then
    print(TAG .. "aborting: module load failed\n")
    return
end

-- --------------------------------------------------------------------- state

local state = {
    fine      = false,
    snap      = cfg.snap_enabled and true or false,
    hud       = cfg.hud and true or false,
    guides    = cfg.guides and true or false,
    hooked    = false,
    hook_path = nil,
    bound     = 0,
}

local function log(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    print(TAG .. (ok and s or tostring(fmt)) .. "\n")
end

-- Short-lived on-screen confirmation, on a different PrintString key from the
-- persistent HUD so the two do not fight over the same slot.
local function toast(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    local msg = ok and s or tostring(fmt)
    ue.print_screen("RVFinePlank: " .. msg, 1.6, "rvfp_toast", ue.color.amber)
    if cfg.verbose then log("%s", msg) end
end

-- ------------------------------------------------------------- fine-mode hook

local function resolve_hook_path()
    local char = ue.get_character()
    if not char then return nil, "no character yet" end
    local cls = char:GetClass()
    if not cls then return nil, "no class" end
    local full = cls:GetFullName()
    if type(full) ~= "string" then return nil, "GetFullName not a string" end
    return (full:match("^%S+%s+(.+)$") or full) .. ":HandleHandPoseInput", nil
end

local function install_hook()
    if state.hooked then return true end
    local path, err = resolve_hook_path()
    if not path then
        if cfg.verbose then log("hook deferred: %s", err) end
        return false
    end
    local ok, a = pcall(RegisterHook, path, function(_, Yaw, Pitch, Fwd)
        if not state.fine then return end
        pcall(function()
            Yaw:set(Yaw:get()     * cfg.fine_scale)
            Pitch:set(Pitch:get() * cfg.fine_scale)
            Fwd:set(Fwd:get()     * cfg.fine_scale)
        end)
    end)
    if not ok then
        log("RegisterHook FAILED on %s (%s)", path, tostring(a))
        return false
    end
    state.hooked, state.hook_path = true, path
    log("hooked %s", path)
    return true
end

-- ------------------------------------------------------------------- actions
-- Every action runs on the game thread and refuses politely when nothing is held.

local function with_char(what, fn)
    ExecuteInGameThread(function()
        local char = ue.get_character()
        if not char then if cfg.verbose then log("%s: no character", what) end return end
        local holding = hold.hold_flags(char)
        if not holding then toast("nothing in hand") return end
        fn(char)
    end)
end

local function ensure_calibrated(char)
    if hold.state.calibrated or not cfg.calibrate then return end
    local s, note = hold.calibrate(char, cfg.calibrate_probe)
    if s then log("calibrated: %s", note) else log("calibration failed: %s", note) end
end

local function act_nudge(dyaw, dpitch, dfwd)
    with_char("nudge", function(char)
        ensure_calibrated(char)
        hold.apply(char, dyaw, dpitch, dfwd)
        if state.snap then hold.snap(char, cfg.snap_deg) end
    end)
end

local function act_snap_now()
    with_char("snap", function(char)
        ensure_calibrated(char)
        local dy, dp = hold.snap(char, cfg.snap_deg)
        if dy == nil then toast("snap: pose unreadable")
        elseif dy == 0 and dp == 0 then toast("already on %.0f deg grid", cfg.snap_deg)
        else toast("snapped %+.2f / %+.2f deg", dy, dp) end
    end)
end

local function act_zero()
    with_char("zero", function(char)
        ensure_calibrated(char)
        local ok = hold.zero_pose(char)
        toast(ok and "pose returned to neutral" or "could not zero pose")
    end)
end

local function act_reach(delta)
    with_char("reach", function(char)
        local v, err = hold.reach_adjust(char, delta, cfg)
        if err then toast("reach: %s", err) else toast("reach %.0f cm", v) end
    end)
end

local function act_reset()
    ExecuteInGameThread(function()
        local char = ue.get_character()
        if not char then return end
        local restored = hold.reset(char)
        state.fine = false
        hud.clear_warnings()
        ue.reset_capabilities()
        toast(restored and string.format("reset — reach back to %.0f cm", restored)
                        or "reset — nothing to restore")
    end)
end

local function act_recalibrate()
    with_char("calibrate", function(char)
        hold.state.calibrated = false
        local s, note = hold.calibrate(char, cfg.calibrate_probe)
        toast(s and ("calibrated: " .. note) or ("calibration failed: " .. note))
        log("recalibrate -> %s", note)
    end)
end

local function act_probe()
    ExecuteInGameThread(function()
        local char = ue.get_character()
        if not char then log("probe: no character"); return end
        local holding, posing = hold.hold_flags(char)
        local yaw, pitch, fwd = hold.pose(char)
        local actor = ue.held_actor(char)
        local xf = actor and ue.actor_transform(actor)
        local can_print, can_draw = ue.probe_capabilities()

        local out = { "probe:" }
        local function line(k, v) out[#out + 1] = string.format("  %-26s %s", k, tostring(v)) end
        line("IsHolding", holding); line("IsHandPosing", posing)
        line("HandEmoteYaw", yaw); line("HandEmotePitch", pitch); line("HandEmoteFwd", fwd)
        line("reach", hold.reach(char)); line("reach stock", hold.state.orig_reach)
        line("sensitivity", hold.state.sens); line("calibration", hold.state.calib_note)
        line("held actor", actor and actor:GetFullName() or "none")
        if xf then
            line("actor location", string.format("X=%.1f Y=%.1f Z=%.1f", xf.loc.X, xf.loc.Y, xf.loc.Z))
            line("actor rotation", string.format("P=%.2f Y=%.2f R=%.2f", xf.rot.Pitch, xf.rot.Yaw, xf.rot.Roll))
            line("off level (deg)", string.format("%.2f", mathx.off_level(xf.rot.Pitch, xf.rot.Roll)))
        end
        line("can print to screen", can_print); line("can draw in world", can_draw)
        line("mod", string.format("fine=%s snap=%s hud=%s guides=%s hooked=%s actions=%d",
            tostring(state.fine), tostring(state.snap), tostring(state.hud),
            tostring(state.guides), tostring(state.hooked), hold.state.actions))
        print(TAG .. table.concat(out, "\n") .. "\n")
    end)
end

-- ------------------------------------------------------------------ keybinds

local function bind(action, fn, desc)
    local name = cfg.keys and cfg.keys[action]
    if not name then
        log("WARN no key configured for '%s'", action); return false
    end
    local k = Key and Key[name]
    if k == nil then
        log("WARN key '%s' (for %s) unknown in this UE4SS build — not bound", name, desc or action)
        return false
    end
    local ok, err = pcall(RegisterKeyBind, k, fn)
    if not ok then
        log("WARN could not bind %s -> %s: %s", name, desc or action, tostring(err)); return false
    end
    return true
end

local function tally(b) if b then state.bound = state.bound + 1 end end

tally(bind("fine_toggle", function()
    state.fine = not state.fine
    if state.fine and not state.hooked then install_hook() end
    toast("fine mode %s", state.fine and "ON" or "off")
end, "fine mode"))

tally(bind("hud_toggle", function()
    state.hud = not state.hud
    hud.clear_warnings()
    toast("HUD %s", state.hud and "on" or "off")
end, "HUD"))

tally(bind("guides_toggle", function()
    state.guides = not state.guides
    hud.clear_warnings()
    toast("guides %s", state.guides and "on" or "off")
end, "guides"))

tally(bind("snap_toggle", function()
    state.snap = not state.snap
    toast("snap %s", state.snap and string.format("ON (%.0f deg)", cfg.snap_deg) or "off")
end, "snap"))

tally(bind("probe",       act_probe,       "probe"))
tally(bind("recalibrate", act_recalibrate, "recalibrate"))
tally(bind("zero_pose",   act_zero,        "zero pose"))
tally(bind("reset_all",   act_reset,       "reset"))

tally(bind("yaw_minus",  function() act_nudge(-cfg.nudge_deg, 0, 0) end, "yaw -"))
tally(bind("yaw_plus",   function() act_nudge( cfg.nudge_deg, 0, 0) end, "yaw +"))
tally(bind("pitch_plus", function() act_nudge(0,  cfg.nudge_deg, 0) end, "pitch +"))
tally(bind("pitch_minus",function() act_nudge(0, -cfg.nudge_deg, 0) end, "pitch -"))
tally(bind("push",       function() act_nudge(0, 0,  cfg.nudge_cm) end,  "push"))
tally(bind("pull",       function() act_nudge(0, 0, -cfg.nudge_cm) end,  "pull"))

tally(bind("reach_out",  function() act_reach( cfg.reach_step) end, "reach out"))
tally(bind("reach_in",   function() act_reach(-cfg.reach_step) end, "reach in"))

-- ------------------------------------------------------------------- console

local function handle_cmd(_, params)
    local sub = (params and params[1] or "probe"):lower()
    local arg = tonumber(params and params[2])

    if     sub == "probe"  then act_probe()
    elseif sub == "on"     then state.fine = true;  install_hook(); toast("fine mode ON")
    elseif sub == "off"    then state.fine = false; toast("fine mode off")
    elseif sub == "scale" and arg then cfg.fine_scale = arg; log("fine_scale = %.4f", arg)
    elseif sub == "deg"   and arg then cfg.nudge_deg  = arg; log("nudge_deg = %.3f", arg)
    elseif sub == "cm"    and arg then cfg.nudge_cm   = arg; log("nudge_cm = %.3f", arg)
    elseif sub == "snap"  then
        if arg then cfg.snap_deg = arg end
        state.snap = true; toast("snap ON (%.0f deg)", cfg.snap_deg)
    elseif sub == "nosnap" then state.snap = false; toast("snap off")
    elseif sub == "zero"   then act_zero()
    elseif sub == "level"  then act_snap_now()
    elseif sub == "hud"    then state.hud = not state.hud; hud.clear_warnings(); toast("HUD %s", tostring(state.hud))
    elseif sub == "guides" then state.guides = not state.guides; hud.clear_warnings(); toast("guides %s", tostring(state.guides))
    elseif sub == "reach" and arg then
        ExecuteInGameThread(function()
            local char = ue.get_character()
            local cur = char and hold.reach(char)
            if cur then act_reach(arg - cur) else toast("reach unreadable") end
        end)
    elseif sub == "reachstep" and arg then cfg.reach_step = arg; log("reach_step = %.2f", arg)
    elseif sub == "calibrate" then act_recalibrate()
    elseif sub == "reset"     then act_reset()
    elseif sub == "verbose"   then cfg.verbose = not cfg.verbose; log("verbose = %s", tostring(cfg.verbose))
    elseif sub == "hook"      then state.hooked = false; install_hook()
    else
        log("usage: rvfine [probe|on|off|scale f|deg f|cm f|snap [f]|nosnap|zero|level|" ..
            "hud|guides|reach cm|reachstep cm|calibrate|reset|verbose|hook]")
    end
    return true
end

pcall(RegisterConsoleCommandHandler, "rvfine", handle_cmd)

-- --------------------------------------------------------------- feedback loop

local function feedback_tick()
    if not (state.hud or state.guides) then return end
    ExecuteInGameThread(function()
        local char = ue.get_character()
        if not char then return end
        local holding, posing = hold.hold_flags(char)
        local actor = holding and ue.held_actor(char) or nil

        if state.hud then
            local yaw, pitch, fwd = hold.pose(char)
            local off
            if actor then
                local xf = ue.actor_transform(actor)
                if xf then off = mathx.off_level(xf.rot.Pitch, xf.rot.Roll) end
            end
            hud.show({
                holding = holding, posing = posing,
                fine = state.fine, snap = state.snap,
                yaw = yaw, pitch = pitch, fwd = fwd,
                reach = hold.reach(char), orig_reach = hold.state.orig_reach,
                off_level = off,
                sens = hold.state.sens, calib_note = hold.state.calib_note,
            }, cfg)
        end

        if state.guides and actor then
            hud.draw_guides(actor, cfg)
        end
    end)
end

-- --------------------------------------------------------------------- boot

pcall(function()
    NotifyOnNewObject("/Script/Engine.PlayerController", function()
        if not state.hooked then ExecuteWithDelay(2000, install_hook) end
    end)
end)

pcall(function()
    LoopAsync(5000, function()
        if not state.hooked then install_hook() end
        return state.hooked
    end)
end)

pcall(function()
    LoopAsync(math.max(33, math.floor((cfg.hud_interval or 0.1) * 1000)), function()
        feedback_tick()
        return false   -- run forever
    end)
end)

log("v%s loaded — %d keybinds bound. %s/%s yaw, %s/%s pitch, %s fine, %s HUD, `rvfine` in console.",
    VERSION, state.bound,
    cfg.keys.yaw_minus, cfg.keys.yaw_plus, cfg.keys.pitch_minus, cfg.keys.pitch_plus,
    cfg.keys.fine_toggle, cfg.keys.hud_toggle)

-- exported for the test suite
return {
    _state = state, _cfg = cfg, _install_hook = install_hook,
    _feedback_tick = feedback_tick, _handle_cmd = handle_cmd,
    _actions = { nudge = act_nudge, snap = act_snap_now, zero = act_zero,
                 reach = act_reach, reset = act_reset, probe = act_probe,
                 recalibrate = act_recalibrate },
}
