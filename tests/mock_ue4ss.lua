--[[
    Mock UE4SS environment + a fake BP_FirstPersonCharacter_C.

    Purpose: exercise RVFinePlank's logic off-game. We cannot verify *feel* without
    the game, but we can verify the parts that silently break mods: hook-path
    derivation, param scaling math, guard conditions, and keybind registration.

    The fake character reproduces what the SDK dump told us HandleHandPoseInput does
    (multiply by a sensitivity constant -> clamp -> accumulate -> clamp), so the test
    sees the same shape of behaviour the real game will produce.
--]]

local M = {}

M.registry = {
    keybinds = {},   -- [key] = fn
    hooks    = {},   -- [path] = {pre=, post=}
    commands = {},   -- [name] = fn
    notifies = {},
    loops    = {},
    delays   = {},
    output   = {},
}

-- ---------------------------------------------------------------- fake engine

-- The game's own constants, per the Blueprint graph structure in the SDK dump:
-- input is scaled then the accumulator is clamped to a finite range.
local SENS       = 2.0
local YAW_LIMIT  = 45.0
local PITCH_LIMIT= 45.0
local FWD_LIMIT  = 60.0

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function new_vector(x, y, z) return { X = x, Y = y, Z = z } end
local function new_rotator(p, y, r) return { Pitch = p, Yaw = y, Roll = r } end

function M.new_character(opts)
    opts = opts or {}
    local char
    char = {
        -- state flags (bools in the real layout at 0xB68 / 0xB69)
        IsHolding    = opts.holding ~= false,
        IsHandPosing = opts.posing  ~= false,

        -- accumulators (consecutive doubles at 0xB70 / 0xB78 / 0xB80)
        HandEmoteYaw   = 0.0,
        HandEmotePitch = 0.0,
        HandEmoteFwd   = 0.0,
        HandEmoteRight = false,
        HandEmoteLeft  = false,

        LookAtDistanceWhenHoldingItem = 150.0,

        -- 3x double each (0xA50 / 0xA68)
        HoldTransformTargetLocation = new_vector(10.5, -3.25, 88.0),
        HoldTransformTargetRotation = new_rotator(0.0, 90.0, 0.0),

        CurrentPickUpActor = {
            IsValid     = function() return true end,
            GetFullName = function() return "BP_Interactable_Actor_C /Game/Maps/Valley.Valley:PersistentLevel.Plank_01" end,
        },

        -- call log so tests can assert exact arguments
        calls = {},
    }

    function char:IsValid() return true end

    function char:GetClass()
        return {
            IsValid     = function() return true end,
            GetFullName = function()
                return opts.class_full_name or
                    "BlueprintGeneratedClass /Game/Blueprints/Character/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C"
            end,
        }
    end

    -- Reproduces the dumped graph: multiply -> clamp -> accumulate -> clamp.
    function char:HandleHandPoseInput(Yaw, Pitch, Fwd)
        self.calls[#self.calls + 1] = { Yaw = Yaw, Pitch = Pitch, Fwd = Fwd }
        self.HandEmoteYaw   = clamp(self.HandEmoteYaw   + clamp(Yaw   * SENS, -10, 10), -YAW_LIMIT,   YAW_LIMIT)
        self.HandEmotePitch = clamp(self.HandEmotePitch + clamp(Pitch * SENS, -10, 10), -PITCH_LIMIT, PITCH_LIMIT)
        self.HandEmoteFwd   = clamp(self.HandEmoteFwd   + clamp(Fwd   * SENS, -10, 10), -FWD_LIMIT,   FWD_LIMIT)
    end

    function char:Server_SetHandPoseInput(v)
        self.calls[#self.calls + 1] = { rpc = v }
    end

    return char
end

-- ------------------------------------------------------------ mock UE4SS API

function M.install(character, opts)
    opts = opts or {}
    local reg = M.registry

    _G.__mock_character = character

    _G.print = function(s)
        reg.output[#reg.output + 1] = tostring(s)
    end

    _G.Key = {
        F3 = 114, F4 = 115,
        NUM_FOUR = 100, NUM_SIX = 102, NUM_EIGHT = 104, NUM_TWO = 98,
        ADD = 107, SUBTRACT = 109,
    }
    if opts.drop_key then _G.Key[opts.drop_key] = nil end

    _G.ModifierKey = { SHIFT = 1, CONTROL = 2, ALT = 4 }

    _G.RegisterKeyBind = function(k, fn)
        assert(k ~= nil, "RegisterKeyBind called with nil key")
        reg.keybinds[k] = fn
    end

    _G.RegisterHook = function(path, pre, post)
        reg.hooks[path] = { pre = pre, post = post }
        return 1, 2
    end

    _G.RegisterConsoleCommandHandler = function(name, fn)
        reg.commands[name] = fn
    end

    _G.ExecuteInGameThread    = function(fn) fn() end
    _G.ExecuteWithDelay       = function(_, fn) reg.delays[#reg.delays + 1] = fn end
    _G.LoopAsync              = function(_, fn) reg.loops[#reg.loops + 1] = fn; fn() end
    _G.NotifyOnNewObject      = function(cls, fn) reg.notifies[cls] = fn end
    _G.FindFirstOf            = function(_) return _G.__mock_character end

    if opts.with_uehelpers then
        package.preload["UEHelpers"] = function()
            return { GetPlayer = function() return _G.__mock_character end }
        end
    else
        package.preload["UEHelpers"] = nil
        package.loaded["UEHelpers"]  = nil
    end
end

function M.reset()
    M.registry = {
        keybinds = {}, hooks = {}, commands = {},
        notifies = {}, loops = {}, delays = {}, output = {},
    }
end

-- A RemoteUnrealParam stand-in: get()/set() over a boxed value.
function M.param(v)
    local box = { v = v }
    return {
        get = function() return box.v end,
        set = function(_, nv) box.v = nv end,
        _box = box,
    }
end

M.SENS = SENS
return M
