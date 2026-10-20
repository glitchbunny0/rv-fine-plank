-- Integration tests for RVFinePlank against a mocked UE4SS.
-- Run: lua tests/test_main.lua  (from the repo root)

local mock = dofile("tests/mock_ue4ss.lua")

-- Capture the REAL print before any mock is installed. Grabbing it later would
-- capture the mock's capturing stub and silently swallow all test output.
local real_print = print

local passed, failed, failures = 0, 0, {}
local function check(name, cond, detail)
    if cond then passed = passed + 1; real_print("  PASS  " .. name)
    else
        failed = failed + 1; failures[#failures + 1] = name
        real_print("  FAIL  " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
    end
end
local function near(a, b, eps)
    if type(a) ~= "number" or type(b) ~= "number" then return false end
    return math.abs(a - b) <= (eps or 1e-6)
end

-- Redirect print into a buffer for the duration of fn (for output written AFTER load).
local function capture(fn)
    local buf = {}
    _G.print = function(s) buf[#buf + 1] = tostring(s) end
    local ok, err = pcall(fn)
    _G.print = real_print
    if not ok then real_print("    (capture error: " .. tostring(err) .. ")") end
    return table.concat(buf, "\n")
end

-- Load the mod fresh. Returns the handle table it exports, or nil + error.
-- `tweak` runs against a fresh config copy before load, for testing rebinds.
local current   -- handle of the most recently loaded mod
local function load_mod(character, opts, tweak)
    mock.install(character, opts)
    if tweak then
        local cfgmod = dofile("RVFinePlank/Scripts/rvfp_config.lua")
        tweak(cfgmod)
        package.loaded["rvfp_config"] = cfgmod
    end
    local chunk, lerr = loadfile("RVFinePlank/Scripts/main.lua")
    if not chunk then _G.print = real_print; return nil, lerr end
    local ok, res = pcall(chunk)
    _G.print = real_print
    if not ok then return nil, res end
    current = res
    -- UE4SS would fire the retry loop shortly after load; do the same so the mod
    -- reaches the steady state (hook installed, first feedback tick done).
    capture(function() mock.pump_loops() end)
    return res
end

local function reg() return mock.registry end
local function K(name) return _G.Key[name] end

-- Press the key that the CONFIG assigns to an action (not the action name itself).
local function press(action)
    local name = current and current._cfg.keys[action]
    assert(name, "no key configured for action '" .. tostring(action) .. "'")
    local code = _G.Key[name]
    assert(code, "key name '" .. name .. "' missing from the mock Key table")
    local fn = reg().keybinds[code]
    assert(fn, "action '" .. action .. "' is not bound to " .. name)
    return fn()
end

real_print("\n=== RVFinePlank integration ===\n")

-- ---------------------------------------------------------------------------
real_print("[1] loads, resolves its modules, registers its surface")
do
    local char = mock.new_character()
    local mod, err = load_mod(char)
    check("mod loads and returns a handle", type(mod) == "table", err)
    if type(mod) ~= "table" then
        real_print("  (aborting: nothing else can be tested)")
    else
        local n = 0
        for _ in pairs(reg().keybinds) do n = n + 1 end
        check("all 16 keybinds registered", n == 16, "got " .. n)
        check("console command registered", reg().commands["rvfine"] ~= nil)
        check("hook retry loop installed", #reg().loops >= 1)
        check("feedback loop installed", #reg().loops >= 2, #reg().loops)
        check("spawn notify installed", reg().notifies["/Script/Engine.PlayerController"] ~= nil)
    end
end

-- ---------------------------------------------------------------------------
real_print("\n[2] ERGONOMICS: nothing lands on the numpad any more")
do
    local char = mock.new_character()
    load_mod(char)
    local numpad = { "NUM_ONE","NUM_TWO","NUM_THREE","NUM_FOUR","NUM_FIVE",
                     "NUM_SIX","NUM_SEVEN","NUM_EIGHT","NUM_NINE","ADD","SUBTRACT" }
    local offenders = {}
    for _, name in ipairs(numpad) do
        local code = _G.Key[name]
        if code and reg().keybinds[code] then offenders[#offenders + 1] = name end
    end
    check("no numpad keys bound", #offenders == 0, table.concat(offenders, ","))
    check("arrows are bound instead",
        reg().keybinds[K("LEFT")] ~= nil and reg().keybinds[K("RIGHT")] ~= nil and
        reg().keybinds[K("UP")] ~= nil and reg().keybinds[K("DOWN")] ~= nil)
end

-- ---------------------------------------------------------------------------
real_print("\n[3] keymap is honoured from config (rebinding works)")
do
    local char = mock.new_character()
    load_mod(char, {}, function(c)
        c.keys.yaw_minus, c.keys.yaw_plus = "Z", "X"
    end)
    check("rebound keys are bound", reg().keybinds[K("Z")] ~= nil and reg().keybinds[K("X")] ~= nil)
    check("the old default is no longer bound", reg().keybinds[K("LEFT")] == nil)
    check("rebound key actually nudges", (function()
        local before = char.HandEmoteYaw
        capture(function() press("recalibrate"); press("yaw_plus") end)
        return char.HandEmoteYaw > before
    end)(), char.HandEmoteYaw)
end

-- ---------------------------------------------------------------------------
real_print("\n[4] hook path derived at runtime, adapts to a moved asset")
do
    local char = mock.new_character()
    load_mod(char)
    local want = "/Game/Blueprints/Character/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C:HandleHandPoseInput"
    check("default path resolved", reg().hooks[want] ~= nil, next(reg().hooks))

    local char2 = mock.new_character({
        class_full_name = "BlueprintGeneratedClass /Game/Elsewhere/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C",
    })
    load_mod(char2)
    check("relocated path resolved",
        reg().hooks["/Game/Elsewhere/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C:HandleHandPoseInput"] ~= nil)
end

-- ---------------------------------------------------------------------------
real_print("\n[5] CALIBRATION finds the game's real sensitivity")
do
    local char = mock.new_character()
    local mod = load_mod(char)
    capture(function() press("recalibrate") end)
    local hold = require("rvfp_hold")
    check("sensitivity measured", near(hold.state.sens, mock.SENS, 1e-6),
          tostring(hold.state.sens) .. " expected " .. mock.SENS)
    check("marked calibrated", hold.state.calibrated == true)
    check("calibration left the pose where it started", near(char.HandEmoteYaw, 0.0, 1e-6),
          char.HandEmoteYaw)
end

real_print("\n[5b] calibration recovers when the pose is pinned at the clamp")
do
    -- start saturated at the positive yaw limit: a positive probe cannot move it
    local char = mock.new_character({ yaw = mock.YAW_LIMIT })
    load_mod(char)
    capture(function() press("recalibrate") end)
    local hold = require("rvfp_hold")
    check("still measured via the reverse probe", near(hold.state.sens, mock.SENS, 1e-6),
          tostring(hold.state.sens) .. " note=" .. tostring(hold.state.calib_note))
    check("note records the reverse probe",
          tostring(hold.state.calib_note):find("reverse", 1, true) ~= nil, hold.state.calib_note)
end

real_print("\n[5c] calibration reports failure when input is ignored entirely")
do
    local char = mock.new_character({ ignore_input = true })
    load_mod(char)
    local blob = capture(function() press("recalibrate") end)
    local hold = require("rvfp_hold")
    check("not calibrated", hold.state.calibrated ~= true)
    check("failure is explained", tostring(hold.state.calib_note):find("did not respond", 1, true) ~= nil,
          hold.state.calib_note)
end

-- ---------------------------------------------------------------------------
real_print("\n[6] nudges are in REAL DEGREES once calibrated")
do
    local char = mock.new_character()
    local mod = load_mod(char)
    mod._cfg.nudge_deg = 1.0
    capture(function() press("recalibrate") end)
    local before = char.HandEmoteYaw
    capture(function() press("yaw_plus") end)
    check("one tap moves exactly 1 degree", near(char.HandEmoteYaw - before, 1.0, 1e-6),
          char.HandEmoteYaw - before)

    capture(function() press("yaw_minus"); press("yaw_minus") end)
    check("opposite direction symmetric", near(char.HandEmoteYaw - before, -1.0, 1e-6),
          char.HandEmoteYaw - before)

    mod._cfg.nudge_deg = 0.25
    local b2 = char.HandEmoteYaw
    capture(function() press("yaw_plus") end)
    check("step size is configurable", near(char.HandEmoteYaw - b2, 0.25, 1e-6),
          char.HandEmoteYaw - b2)

    local p0 = char.HandEmotePitch
    capture(function() press("pitch_plus") end)
    check("pitch axis works too", near(char.HandEmotePitch - p0, 0.25, 1e-6))

    local f0 = char.HandEmoteFwd
    mod._cfg.nudge_cm = 2.0
    capture(function() press("push") end)
    check("push axis uses nudge_cm", near(char.HandEmoteFwd - f0, 2.0, 1e-6),
          char.HandEmoteFwd - f0)
    capture(function() press("pull") end)
    check("pull reverses it", near(char.HandEmoteFwd, f0, 1e-6))
end

-- ---------------------------------------------------------------------------
real_print("\n[7] SNAPPING to a degree grid")
do
    local char = mock.new_character()
    local mod = load_mod(char)
    mod._cfg.snap_deg = 15.0
    capture(function() press("recalibrate") end)

    -- walk to 14 degrees in reachable steps (the game clamps a single call's
    -- contribution, so 14 in one go would be truncated — see [7b])
    mod._cfg.nudge_deg = 7.0
    capture(function() press("yaw_plus"); press("yaw_plus") end)
    check("pose is at 14", near(char.HandEmoteYaw, 14.0, 1e-6), char.HandEmoteYaw)
    capture(function() mod._handle_cmd(nil, { "level" }) end)
    check("snapped onto 15", near(char.HandEmoteYaw, 15.0, 1e-6), char.HandEmoteYaw)

    capture(function() mod._handle_cmd(nil, { "level" }) end)
    check("no-op when already on grid", near(char.HandEmoteYaw, 15.0, 1e-6), char.HandEmoteYaw)

    -- snap mode on: every nudge lands back on the grid
    mod._cfg.nudge_deg = 4.0
    capture(function() press("snap_toggle") end)
    check("snap toggled on", mod._state.snap == true)
    capture(function() press("yaw_plus") end)
    check("nudge with snap on lands on grid", near(char.HandEmoteYaw % 15.0, 0.0, 1e-6),
          char.HandEmoteYaw)
end

real_print("\n[7b] large moves converge despite the game's per-call clamp")
do
    -- The engine clamps how much ONE HandleHandPoseInput call may contribute, so
    -- naive single-shot deltas silently under-shoot. These must iterate.
    local char = mock.new_character()
    local mod = load_mod(char)
    capture(function() press("recalibrate") end)
    local hold = require("rvfp_hold")

    -- a single call can only move 10 deg (PER_CALL / SENS * SENS); ask for 40
    local reached, iters, final = nil, nil, nil
    capture(function() reached, iters, final = hold.drive_axis(char, "yaw", 40.0) end)
    check("reached a far target", reached == true and near(final, 40.0, 1e-4),
          tostring(final) .. " reached=" .. tostring(reached))
    check("it took more than one call", (iters or 0) > 1, iters)

    -- zeroing from near the clamp must also converge, not under-shoot
    capture(function() hold.drive_axis(char, "yaw", mock.YAW_LIMIT) end)
    check("pose parked at the limit", near(char.HandEmoteYaw, mock.YAW_LIMIT, 1e-4),
          char.HandEmoteYaw)
    capture(function() press("zero_pose") end)
    check("zero from the limit reaches 0", near(char.HandEmoteYaw, 0.0, 1e-4), char.HandEmoteYaw)

    -- and an impossible target reports failure instead of spinning
    local ok2, it2 = nil, nil
    capture(function() ok2, it2 = hold.drive_axis(char, "yaw", 10000.0) end)
    check("impossible target gives up", ok2 == false)
    check("gives up in bounded iterations", (it2 or 99) <= 16, it2)
end

-- ---------------------------------------------------------------------------
real_print("\n[8] zero pose returns to neutral")
do
    local char = mock.new_character()
    local mod = load_mod(char)
    capture(function() press("recalibrate") end)
    mod._cfg.nudge_deg = 7.0
    capture(function() press("yaw_plus"); press("pitch_plus") end)
    check("pose is off-neutral", math.abs(char.HandEmoteYaw) > 1)
    capture(function() press("zero_pose") end)
    check("yaw back to ~0", near(char.HandEmoteYaw, 0.0, 1e-6), char.HandEmoteYaw)
    check("pitch back to ~0", near(char.HandEmotePitch, 0.0, 1e-6), char.HandEmotePitch)
end

-- ---------------------------------------------------------------------------
real_print("\n[9] HUD readout: on screen, in place, with real numbers")
do
    local char = mock.new_character()
    local mod = load_mod(char)
    mock.pump_loops()

    local scr = reg().screen
    check("something was printed to screen", #scr > 0, #scr)
    local hudline = reg().screen_by_key["rvfp_hud"]
    check("HUD uses a stable key", hudline ~= nil)
    check("HUD names the mod", hudline and hudline:find("RVFinePlank", 1, true) ~= nil)
    check("HUD shows yaw/pitch/push", hudline and hudline:find("yaw", 1, true) and
          hudline:find("pitch", 1, true) and hudline:find("push", 1, true))
    check("HUD shows tilt", hudline and hudline:find("tilt", 1, true) ~= nil, hudline)
    check("HUD shows reach", hudline and hudline:find("reach", 1, true) ~= nil)
    check("printed with bPrintToScreen", scr[#scr].screen == true)

    -- in-place replacement: same key, new text after the pose changes
    local first = reg().screen_by_key["rvfp_hud"]
    capture(function() press("recalibrate") end)
    mod._cfg.nudge_deg = 9.0
    capture(function() press("yaw_plus") end)
    mock.pump_loops()
    local second = reg().screen_by_key["rvfp_hud"]
    check("HUD text updates", second ~= first)
    check("HUD reports the new yaw", second:find("9.00", 1, true) ~= nil, second)

    -- uncalibrated state is called out honestly
    local char2 = mock.new_character()
    load_mod(char2)
    mock.pump_loops()
    check("warns when uncalibrated",
        reg().screen_by_key["rvfp_hud"]:find("UNCALIBRATED", 1, true) ~= nil)
end

real_print("\n[9b] HUD says so plainly when hands are empty")
do
    local char = mock.new_character({ holding = false })
    load_mod(char)
    mock.pump_loops()
    local hudline = reg().screen_by_key["rvfp_hud"]
    check("reports empty hands", hudline and hudline:find("nothing in hand", 1, true) ~= nil, hudline)
end

-- ---------------------------------------------------------------------------
real_print("\n[10] world guides: oriented footprint + axis + level reference")
do
    local char = mock.new_character()
    load_mod(char)
    mock.pump_loops()

    local boxes, lines = reg().draws.box, reg().draws.line
    check("a footprint box is drawn", #boxes >= 1, #boxes)
    check("box carries the actor rotation", boxes[1] and boxes[1].rotation ~= nil and
          near(boxes[1].rotation.Yaw, 90.0), boxes[1] and boxes[1].rotation and boxes[1].rotation.Yaw)
    check("box uses the actor extent", boxes[1] and near(boxes[1].extent.X, 120.0),
          boxes[1] and boxes[1].extent.X)
    check("axis + level reference + 2 plumb lines", #lines >= 4, #lines)

    -- a level plank draws green; a tilted one draws amber
    local flat = boxes[1].color
    check("level plank is green", flat and flat.G > 0.9 and flat.R < 0.5,
          flat and (flat.R .. "," .. flat.G))

    local tilted = mock.new_actor({ rot = { Pitch = 20.0, Yaw = 90.0, Roll = 0.0 } })
    local char2 = mock.new_character({ actor = tilted })
    load_mod(char2)
    mock.pump_loops()
    local c2 = reg().draws.box[1] and reg().draws.box[1].color
    check("tilted plank is amber", c2 and c2.R > 0.9 and c2.G > 0.5 and c2.G < 0.9,
          c2 and (c2.R .. "," .. c2.G))
end

real_print("\n[10b] guides and HUD can be switched off")
do
    local char = mock.new_character()
    local mod = load_mod(char)
    capture(function() press("guides_toggle"); press("hud_toggle") end)
    check("both flags off", mod._state.guides == false and mod._state.hud == false)
    mock.reset()
    mock.pump_loops()
    check("nothing drawn", #reg().draws.box == 0 and #reg().draws.line == 0)
    check("nothing printed to screen", reg().screen_by_key["rvfp_hud"] == nil)
end

-- ---------------------------------------------------------------------------
real_print("\n[11] missing engine APIs disable the feature instead of spamming")
do
    local char = mock.new_character()
    load_mod(char, { no_print = true, no_draw = true })
    local ok = pcall(function() mock.pump_loops(); mock.pump_loops() end)
    check("feedback loop survives an unavailable PrintString/DrawDebug", ok)
    check("nothing recorded on screen", reg().screen_by_key["rvfp_hud"] == nil)
    local hud = require("rvfp_hud")
    check("HUD marked unavailable", hud.state.hud_ok == false, tostring(hud.state.hud_ok))
    check("drawing marked unavailable", hud.state.draw_ok == false, tostring(hud.state.draw_ok))
end

-- ---------------------------------------------------------------------------
real_print("\n[12] fine mode still scales the real input, and only when on")
do
    local char = mock.new_character()
    local mod = load_mod(char)
    local path = "/Game/Blueprints/Character/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C:HandleHandPoseInput"
    local pre = reg().hooks[path].pre

    local y = mock.param(4.0)
    pre(char, y, mock.param(0), mock.param(0))
    check("off: untouched", near(y:get(), 4.0))

    capture(function() press("fine_toggle") end)
    local y2 = mock.param(4.0)
    pre(char, y2, mock.param(0), mock.param(0))
    check("on: scaled by fine_scale", near(y2:get(), 4.0 * mod._cfg.fine_scale), y2:get())

    capture(function() press("fine_toggle") end)
    local y3 = mock.param(4.0)
    pre(char, y3, mock.param(0), mock.param(0))
    check("toggles back off", near(y3:get(), 4.0))
end

-- ---------------------------------------------------------------------------
real_print("\n[13] reach: steps, clamps, exact restore, honest failures")
do
    local char = mock.new_character({ reach = 150.0 })
    local mod = load_mod(char)
    capture(function() press("reach_out") end)
    check("reach_out adds a step", near(char.LookAtDistanceWhenHoldingItem, 155.0),
          char.LookAtDistanceWhenHoldingItem)
    capture(function() press("reach_in"); press("reach_in") end)
    check("reach_in subtracts", near(char.LookAtDistanceWhenHoldingItem, 145.0),
          char.LookAtDistanceWhenHoldingItem)
    capture(function() for _ = 1, 200 do press("reach_out") end end)
    check("clamped at max", near(char.LookAtDistanceWhenHoldingItem, mod._cfg.reach_max),
          char.LookAtDistanceWhenHoldingItem)
    capture(function() for _ = 1, 400 do press("reach_in") end end)
    check("clamped at min", near(char.LookAtDistanceWhenHoldingItem, mod._cfg.reach_min),
          char.LookAtDistanceWhenHoldingItem)
    capture(function() press("reset_all") end)
    check("reset restores the stock value exactly",
          near(char.LookAtDistanceWhenHoldingItem, 150.0), char.LookAtDistanceWhenHoldingItem)

    -- a property that refuses writes must be reported
    local char2 = mock.new_character({ reach = 150.0 })
    load_mod(char2)
    setmetatable(char2, {
        __index = function(_, k) return k == "LookAtDistanceWhenHoldingItem" and 150.0 or nil end,
        __newindex = function() end,
    })
    char2.LookAtDistanceWhenHoldingItem = nil
    local blob = capture(function() press("reach_out") end)
    local onscreen = reg().screen_by_key["rvfp_toast"] or ""
    check("non-sticking write is surfaced",
          (blob .. onscreen):find("did not stick", 1, true) ~= nil, blob .. " | " .. onscreen)
end

-- ---------------------------------------------------------------------------
real_print("\n[14] guards: empty hands, no character, unknown key, bad console input")
do
    local char = mock.new_character({ holding = false })
    load_mod(char)
    capture(function() press("yaw_plus") end)
    check("no pose call with empty hands", #char.calls == 0, #char.calls)
    check("told the player on screen",
          (reg().screen_by_key["rvfp_toast"] or ""):find("nothing in hand", 1, true) ~= nil)

    local ok = pcall(function()
        mock.install(nil, {})
        _G.FindFirstOf = function() return nil end
        local chunk = loadfile("RVFinePlank/Scripts/main.lua")
        pcall(chunk); _G.print = real_print
        if reg().keybinds[K("RIGHT")] then reg().keybinds[K("RIGHT")]() end
        mock.pump_loops()
    end)
    _G.print = real_print
    check("survives having no character", ok)

    local char3 = mock.new_character()
    local mod3 = load_mod(char3, { drop_key = "HOME" })
    local n = 0
    for _ in pairs(reg().keybinds) do n = n + 1 end
    check("one unknown key costs exactly one binding", n == 15, "got " .. n)
    local warned = false
    for _, l in ipairs(reg().output) do
        if l:find("key 'HOME'", 1, true) then warned = true end
    end
    check("the unbound key is named in the log", warned)

    check("unknown subcommand does not error", pcall(mod3._handle_cmd, nil, { "wat" }))
    check("console handler returns handled", mod3._handle_cmd(nil, { "probe" }) == true)
end

-- ---------------------------------------------------------------------------
real_print("\n[15] probe reports every field, including the new ones")
do
    local char = mock.new_character()
    load_mod(char)
    local blob = capture(function() press("probe") end)
    for _, f in ipairs({ "IsHolding", "IsHandPosing", "HandEmoteYaw", "HandEmotePitch",
                         "HandEmoteFwd", "reach", "sensitivity", "calibration",
                         "held actor", "actor location", "actor rotation",
                         "off level", "can print to screen", "can draw in world" }) do
        check("probe reports " .. f, blob:find(f, 1, true) ~= nil)
    end
    check("no unreadable fields", blob:find("<unreadable>", 1, true) == nil)
end

real_print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then real_print("failures: " .. table.concat(failures, ", ")); os.exit(1) end
os.exit(0)
