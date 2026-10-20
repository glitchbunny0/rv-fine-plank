-- Test suite for RVFinePlank. Run: lua tests/test_main.lua  (from repo root)

local mock = dofile("tests/mock_ue4ss.lua")

-- Capture the REAL print before any mock is installed. Grabbing it later would
-- capture the mock's capturing stub and silently swallow all test output.
local real_print = print

local passed, failed, failures = 0, 0, {}

local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print(string.format("  PASS  %s", name))
    else
        failed = failed + 1
        failures[#failures + 1] = name
        print(string.format("  FAIL  %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
    end
end

local function near(a, b, eps)
    return math.abs(a - b) <= (eps or 1e-9)
end

-- Run fn with print() redirected into a buffer, then restore. Needed because
-- load_mod hands print back to stdout, so anything the mod logs *after* load
-- (probe output, runtime warnings) would otherwise never reach the buffer.
local function capture(fn)
    local buf = {}
    _G.print = function(s) buf[#buf + 1] = tostring(s) end
    local ok, err = pcall(fn)
    _G.print = real_print
    if not ok then real_print("    (capture error: " .. tostring(err) .. ")") end
    return table.concat(buf, "\n")
end

-- Load the mod fresh against a given character + options.
local function load_mod(character, opts)
    mock.reset()
    mock.install(character, opts)
    local chunk = assert(loadfile("RVFinePlank/Scripts/main.lua"))
    local ok, err = pcall(chunk)
    _G.print = real_print
    return ok, err
end

print("\n=== RVFinePlank test suite ===\n")

-- ---------------------------------------------------------------------------
print("[1] loads cleanly and registers its surface")
do
    local char = mock.new_character()
    local ok, err = load_mod(char, { with_uehelpers = true })
    check("mod loads without error", ok, err)

    local n = 0
    for _ in pairs(mock.registry.keybinds) do n = n + 1 end
    check("all 11 keybinds registered", n == 11, "got " .. n)
    check("console command 'rvfine' registered", mock.registry.commands["rvfine"] ~= nil)
    check("retry loop installed", #mock.registry.loops >= 1)
    check("spawn notify installed", mock.registry.notifies["/Script/Engine.PlayerController"] ~= nil)
end

-- ---------------------------------------------------------------------------
print("\n[2] derives the Blueprint hook path at runtime (never hardcoded)")
do
    local char = mock.new_character()
    load_mod(char, { with_uehelpers = true })
    local expected = "/Game/Blueprints/Character/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C:HandleHandPoseInput"
    check("hook path stripped of class prefix", mock.registry.hooks[expected] ~= nil,
          "hooks: " .. tostring(next(mock.registry.hooks)))

    -- A different asset path must still resolve — proves we are not pattern-matching a guess.
    local char2 = mock.new_character({
        class_full_name = "BlueprintGeneratedClass /Game/Totally/Other/Place/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C",
    })
    load_mod(char2, { with_uehelpers = true })
    local expected2 = "/Game/Totally/Other/Place/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C:HandleHandPoseInput"
    check("adapts to a relocated asset path", mock.registry.hooks[expected2] ~= nil)
end

-- ---------------------------------------------------------------------------
print("\n[3] fine mode scales the real input, and only when enabled")
do
    local char = mock.new_character()
    load_mod(char, { with_uehelpers = true })
    local path = "/Game/Blueprints/Character/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C:HandleHandPoseInput"
    local pre = mock.registry.hooks[path].pre

    -- fine mode OFF: params must pass through untouched
    local y, p, f = mock.param(4.0), mock.param(-2.0), mock.param(1.0)
    pre(char, y, p, f)
    check("off: yaw untouched",   near(y:get(),  4.0))
    check("off: pitch untouched", near(p:get(), -2.0))
    check("off: fwd untouched",   near(f:get(),  1.0))

    -- toggle ON via the F3 keybind closure
    mock.registry.keybinds[_G.Key.F3]()

    local y2, p2, f2 = mock.param(4.0), mock.param(-2.0), mock.param(1.0)
    pre(char, y2, p2, f2)
    check("on: yaw scaled 0.15",   near(y2:get(),  4.0 * 0.15), y2:get())
    check("on: pitch scaled 0.15", near(p2:get(), -2.0 * 0.15), p2:get())
    check("on: fwd scaled 0.15",   near(f2:get(),  1.0 * 0.15), f2:get())

    -- toggle OFF again
    mock.registry.keybinds[_G.Key.F3]()
    local y3 = mock.param(4.0)
    pre(char, y3, mock.param(0), mock.param(0))
    check("toggles back off", near(y3:get(), 4.0))
end

-- ---------------------------------------------------------------------------
print("\n[4] nudge drives the game's own handler with exact deltas")
do
    local char = mock.new_character()
    load_mod(char, { with_uehelpers = true })

    mock.registry.keybinds[_G.Key.NUM_SIX]()   -- yaw +
    check("one call made", #char.calls == 1, #char.calls)
    check("yaw delta is cfg.nudge_yaw", char.calls[1] and near(char.calls[1].Yaw, 0.05),
          char.calls[1] and char.calls[1].Yaw)
    check("other axes zero", char.calls[1] and near(char.calls[1].Pitch, 0) and near(char.calls[1].Fwd, 0))

    mock.registry.keybinds[_G.Key.NUM_FOUR]()  -- yaw -
    check("opposite key sends negative", char.calls[2] and near(char.calls[2].Yaw, -0.05))

    mock.registry.keybinds[_G.Key.ADD]()       -- push
    check("ADD pushes on Fwd axis", char.calls[3] and near(char.calls[3].Fwd, 0.05))
    mock.registry.keybinds[_G.Key.SUBTRACT]()  -- pull
    check("SUBTRACT pulls on Fwd axis", char.calls[4] and near(char.calls[4].Fwd, -0.05))

    mock.registry.keybinds[_G.Key.NUM_EIGHT]()
    check("NUM_EIGHT raises pitch", char.calls[5] and near(char.calls[5].Pitch, 0.05))

    -- accumulator moved in the right direction through the game's own math
    check("accumulator responded", char.HandEmotePitch > 0, char.HandEmotePitch)
end

-- ---------------------------------------------------------------------------
print("\n[5] guard conditions")
do
    -- not holding anything -> must not call into the game
    local char = mock.new_character({ holding = false })
    load_mod(char, { with_uehelpers = true })
    mock.registry.keybinds[_G.Key.NUM_SIX]()
    check("no call when IsHolding is false", #char.calls == 0, #char.calls)

    -- holding but not in hand-pose mode -> still calls (game decides), no crash
    local char2 = mock.new_character({ holding = true, posing = false })
    load_mod(char2, { with_uehelpers = true })
    mock.registry.keybinds[_G.Key.NUM_SIX]()
    check("calls when holding even if not posing", #char2.calls == 1, #char2.calls)

    -- no character at all -> no crash
    local ok = pcall(function()
        mock.reset(); mock.install(nil, { with_uehelpers = false })
        _G.FindFirstOf = function() return nil end
        local chunk = assert(loadfile("RVFinePlank/Scripts/main.lua"))
        pcall(chunk)
        _G.print = real_print
        if mock.registry.keybinds[_G.Key.NUM_SIX] then
            mock.registry.keybinds[_G.Key.NUM_SIX]()
        end
    end)
    _G.print = real_print
    check("survives having no character instance", ok)
end

-- ---------------------------------------------------------------------------
print("\n[6] UEHelpers absent -> FindFirstOf fallback still works")
do
    local char = mock.new_character()
    local ok = load_mod(char, { with_uehelpers = false })
    check("loads without UEHelpers", ok)
    mock.registry.keybinds[_G.Key.NUM_SIX]()
    check("fallback lookup found the character", #char.calls == 1, #char.calls)
end

-- ---------------------------------------------------------------------------
print("\n[7] a missing Key name degrades instead of aborting")
do
    local char = mock.new_character()
    local ok = load_mod(char, { with_uehelpers = true, drop_key = "ADD" })
    check("still loads with an unknown key", ok)
    local n = 0
    for _ in pairs(mock.registry.keybinds) do n = n + 1 end
    check("binds the remaining 10", n == 10, "got " .. n)
    local warned = false
    for _, line in ipairs(mock.registry.output) do
        if line:find("WARN key 'ADD'", 1, true) then warned = true end
    end
    check("warns about the unbound key", warned)
end

-- ---------------------------------------------------------------------------
print("\n[8] console command surface")
do
    local char = mock.new_character()
    load_mod(char, { with_uehelpers = true })
    local cmd = mock.registry.commands["rvfine"]
    local path = "/Game/Blueprints/Character/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C:HandleHandPoseInput"
    local pre = mock.registry.hooks[path].pre

    check("returns true (handled)", cmd("rvfine scale 0.5", { "scale", "0.5" }, nil) == true)
    cmd("rvfine on", { "on" }, nil)
    local y = mock.param(10.0)
    pre(char, y, mock.param(0), mock.param(0))
    check("scale command took effect", near(y:get(), 5.0), y:get())

    cmd("rvfine step 0.2", { "step", "0.2" }, nil)
    local before = #char.calls
    mock.registry.keybinds[_G.Key.NUM_SIX]()
    check("step command changed nudge size", char.calls[before + 1] and near(char.calls[before + 1].Yaw, 0.2),
          char.calls[before + 1] and char.calls[before + 1].Yaw)

    cmd("rvfine off", { "off" }, nil)
    local y2 = mock.param(10.0)
    pre(char, y2, mock.param(0), mock.param(0))
    check("off command disables scaling", near(y2:get(), 10.0))

    check("unknown subcommand does not error", pcall(cmd, "rvfine wat", { "wat" }, nil))
end

-- ---------------------------------------------------------------------------
print("\n[9] probe reads every field the SDK promised")
do
    local char = mock.new_character()
    load_mod(char, { with_uehelpers = true })
    local blob = capture(function()
        mock.registry.keybinds[_G.Key.F4]()   -- probe
    end)

    for _, field in ipairs({
        "IsHolding", "IsHandPosing", "HandEmoteYaw", "HandEmotePitch", "HandEmoteFwd",
        "HandEmoteRight", "HandEmoteLeft", "LookAtDistance",
        "HoldTargetLocation", "HoldTargetRotation", "CurrentPickUpActor",
    }) do
        check("probe reports " .. field, blob:find(field, 1, true) ~= nil)
    end
    check("probe read the vector components", blob:find("X=10.500", 1, true) ~= nil)
    check("probe read the rotator components", blob:find("Y=90.000", 1, true) ~= nil)
    check("probe did not hit unreadable fields", blob:find("<unreadable>", 1, true) == nil, blob)
end

-- ---------------------------------------------------------------------------
print("\n[10] reach — coarse hold distance, with a safe restore")
do
    local char = mock.new_character({ reach = 150.0 })
    load_mod(char, { with_uehelpers = true })

    -- further / closer
    capture(function() mock.registry.keybinds[_G.Key.NUM_NINE]() end)
    check("NUM_NINE pushes reach out by reach_step", near(char.LookAtDistanceWhenHoldingItem, 155.0),
          char.LookAtDistanceWhenHoldingItem)
    capture(function()
        mock.registry.keybinds[_G.Key.NUM_THREE]()
        mock.registry.keybinds[_G.Key.NUM_THREE]()
    end)
    check("NUM_THREE pulls reach in", near(char.LookAtDistanceWhenHoldingItem, 145.0),
          char.LookAtDistanceWhenHoldingItem)

    -- restore must return exactly the stock value, not an accumulated guess
    capture(function() mock.registry.keybinds[_G.Key.NUM_FIVE]() end)
    check("NUM_FIVE restores the stock reach exactly", near(char.LookAtDistanceWhenHoldingItem, 150.0),
          char.LookAtDistanceWhenHoldingItem)
end

print("\n[11] reach clamps, so a held key cannot wreck the hold")
do
    local char = mock.new_character({ reach = 150.0 })
    load_mod(char, { with_uehelpers = true })
    capture(function()
        for _ = 1, 200 do mock.registry.keybinds[_G.Key.NUM_NINE]() end
    end)
    check("clamped at reach_max", near(char.LookAtDistanceWhenHoldingItem, 400.0),
          char.LookAtDistanceWhenHoldingItem)
    capture(function()
        for _ = 1, 400 do mock.registry.keybinds[_G.Key.NUM_THREE]() end
    end)
    check("clamped at reach_min", near(char.LookAtDistanceWhenHoldingItem, 40.0),
          char.LookAtDistanceWhenHoldingItem)
    -- and the original is still recoverable after all that
    capture(function() mock.registry.keybinds[_G.Key.NUM_FIVE]() end)
    check("stock value survived the clamping", near(char.LookAtDistanceWhenHoldingItem, 150.0),
          char.LookAtDistanceWhenHoldingItem)
end

print("\n[12] reach console surface + absolute targeting")
do
    local char = mock.new_character({ reach = 150.0 })
    load_mod(char, { with_uehelpers = true })
    local cmd = mock.registry.commands["rvfine"]

    capture(function() cmd("rvfine reach 220", { "reach", "220" }, nil) end)
    check("`reach <cm>` sets an absolute distance", near(char.LookAtDistanceWhenHoldingItem, 220.0),
          char.LookAtDistanceWhenHoldingItem)

    capture(function() cmd("rvfine reachstep 25", { "reachstep", "25" }, nil) end)
    capture(function() mock.registry.keybinds[_G.Key.NUM_NINE]() end)
    check("`reachstep` changes the per-tap amount", near(char.LookAtDistanceWhenHoldingItem, 245.0),
          char.LookAtDistanceWhenHoldingItem)

    capture(function() cmd("rvfine reset", { "reset" }, nil) end)
    check("`reset` restores stock", near(char.LookAtDistanceWhenHoldingItem, 150.0),
          char.LookAtDistanceWhenHoldingItem)

    -- reset with nothing to undo must not error or invent a value
    local char2 = mock.new_character({ reach = 180.0 })
    load_mod(char2, { with_uehelpers = true })
    local blob = capture(function()
        mock.registry.commands["rvfine"]("rvfine reset", { "reset" }, nil)
    end)
    check("reset is a no-op when untouched", near(char2.LookAtDistanceWhenHoldingItem, 180.0))
    check("reset says so", blob:find("never modified", 1, true) ~= nil)
end

print("\n[13] reach failure modes are reported, not swallowed")
do
    -- property missing entirely (e.g. renamed in a game patch)
    local char = mock.new_character()
    char.LookAtDistanceWhenHoldingItem = nil
    load_mod(char, { with_uehelpers = true })
    local blob = capture(function() mock.registry.keybinds[_G.Key.NUM_NINE]() end)
    check("unreadable property is reported", blob:find("unreadable", 1, true) ~= nil, blob)

    -- property that refuses to hold a written value (recomputed each tick)
    local char2 = mock.new_character({ reach = 150.0 })
    load_mod(char2, { with_uehelpers = true })
    setmetatable(char2, {
        __index = function(_, k) return k == "LookAtDistanceWhenHoldingItem" and 150.0 or nil end,
        __newindex = function() end,  -- swallow writes
    })
    char2.LookAtDistanceWhenHoldingItem = nil   -- force reads through the metatable
    local blob2 = capture(function() mock.registry.keybinds[_G.Key.NUM_NINE]() end)
    check("a write that does not stick is detected", blob2:find("did not stick", 1, true) ~= nil, blob2)
end

-- ---------------------------------------------------------------------------
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then
    print("failures: " .. table.concat(failures, ", "))
    os.exit(1)
end
os.exit(0)
