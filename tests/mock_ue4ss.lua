--[[
    Mock UE4SS environment for RVFinePlank.

    Covers: the globals the mod registers against, a KismetSystemLibrary stand-in
    recording PrintString / DrawDebug* calls, a fake BP_FirstPersonCharacter_C, and
    a fake held actor with a real world transform.

    The fake character reproduces what the SDK dump says HandleHandPoseInput does
    (multiply by sensitivity -> per-call clamp -> accumulate -> accumulator clamp),
    so calibration and snapping are exercised against realistic behaviour including
    saturation at the limits.
--]]

local M = {}

-- The game's own constants, as far as the dump reveals their shape. SENS is the
-- value the mod must discover at runtime; tests assert it finds exactly this.
local SENS        = 2.0
local YAW_LIMIT   = 45.0
local PITCH_LIMIT = 45.0
local FWD_LIMIT   = 60.0
local PER_CALL    = 10.0   -- inner FClamp on a single call's contribution

M.SENS = SENS
M.YAW_LIMIT, M.PITCH_LIMIT, M.FWD_LIMIT = YAW_LIMIT, PITCH_LIMIT, FWD_LIMIT

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function blank_registry()
    return {
        keybinds = {}, hooks = {}, commands = {},
        notifies = {}, loops = {}, delays = {},
        output = {},          -- print() lines
        screen = {},          -- PrintString calls, newest last
        screen_by_key = {},   -- key -> latest text (in-place replacement semantics)
        draws = { line = {}, box = {} },
    }
end

M.registry = blank_registry()

-- ------------------------------------------------------------- fake held actor

function M.new_actor(opts)
    opts = opts or {}
    local loc = opts.loc or { X = 1000.0, Y = 2000.0, Z = 300.0 }
    local rot = opts.rot or { Pitch = 0.0, Yaw = 90.0, Roll = 0.0 }
    local ext = opts.extent or { X = 120.0, Y = 15.0, Z = 5.0 }   -- plank-ish
    local a = {}
    function a:IsValid() return true end
    function a:GetFullName()
        return opts.name or "BP_Interactable_Actor_C /Game/Maps/Valley.Valley:PersistentLevel.Plank_01"
    end
    function a:K2_GetActorLocation() return { X = loc.X, Y = loc.Y, Z = loc.Z } end
    function a:K2_GetActorRotation() return { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll } end
    function a:GetActorForwardVector()
        local y, p = math.rad(rot.Yaw), math.rad(rot.Pitch)
        return { X = math.cos(y) * math.cos(p), Y = math.sin(y) * math.cos(p), Z = math.sin(p) }
    end
    function a:GetActorBounds(_) return loc, { X = ext.X, Y = ext.Y, Z = ext.Z } end
    a.set_rot = function(p, yw, r) rot = { Pitch = p, Yaw = yw, Roll = r } end
    return a
end

-- -------------------------------------------------------------- fake character

function M.new_character(opts)
    opts = opts or {}
    local char = {
        IsHolding    = opts.holding ~= false,
        IsHandPosing = opts.posing  ~= false,

        HandEmoteYaw   = opts.yaw   or 0.0,
        HandEmotePitch = opts.pitch or 0.0,
        HandEmoteFwd   = opts.fwd   or 0.0,
        HandEmoteRight = false,
        HandEmoteLeft  = false,

        LookAtDistance                = 250.0,
        LookAtDistanceWhenHoldingItem = opts.reach or 150.0,

        HoldTransformTargetLocation = { X = 10.5, Y = -3.25, Z = 88.0 },
        HoldTransformTargetRotation = { Pitch = 0.0, Yaw = 90.0, Roll = 0.0 },

        calls = {},
    }

    char.CurrentPickUpActor = (opts.holding ~= false)
        and (opts.actor or M.new_actor(opts.actor_opts)) or nil

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

    function char:HandleHandPoseInput(Yaw, Pitch, Fwd)
        self.calls[#self.calls + 1] = { Yaw = Yaw, Pitch = Pitch, Fwd = Fwd }
        if opts.ignore_input then return end
        self.HandEmoteYaw   = clamp(self.HandEmoteYaw   + clamp((Yaw   or 0) * SENS, -PER_CALL, PER_CALL), -YAW_LIMIT,   YAW_LIMIT)
        self.HandEmotePitch = clamp(self.HandEmotePitch + clamp((Pitch or 0) * SENS, -PER_CALL, PER_CALL), -PITCH_LIMIT, PITCH_LIMIT)
        self.HandEmoteFwd   = clamp(self.HandEmoteFwd   + clamp((Fwd   or 0) * SENS, -PER_CALL, PER_CALL), -FWD_LIMIT,   FWD_LIMIT)
    end

    function char:Server_SetHandPoseInput(v) self.calls[#self.calls + 1] = { rpc = v } end

    return char
end

-- ------------------------------------------ fake KismetSystemLibrary

local function new_ksl(reg, opts)
    local k = { _is_ksl = true }
    function k:IsValid() return true end
    function k:PrintString(_, str, toScreen, toLog, color, duration, key)
        if opts.no_print then error("PrintString unavailable") end
        reg.screen[#reg.screen + 1] = {
            text = str, screen = toScreen, log = toLog,
            color = color, duration = duration, key = key,
        }
        reg.screen_by_key[tostring(key)] = str
    end
    function k:DrawDebugLine(_, a, b, color, duration, thickness)
        if opts.no_draw then error("DrawDebugLine unavailable") end
        reg.draws.line[#reg.draws.line + 1] =
            { a = a, b = b, color = color, duration = duration, thickness = thickness }
    end
    function k:DrawDebugBox(_, center, extent, color, rotation, duration, thickness)
        if opts.no_draw then error("DrawDebugBox unavailable") end
        reg.draws.box[#reg.draws.box + 1] =
            { center = center, extent = extent, color = color,
              rotation = rotation, duration = duration, thickness = thickness }
    end
    return k
end

-- ------------------------------------------------------------- mock UE4SS API

-- Every key name the default config uses, plus the old numpad set so a rebind can
-- be tested. A build missing a name is simulated with opts.drop_key.
local KEYS = {
    F1=112, F2=113, F3=114, F4=115, F5=116, F6=117, F7=118, F8=119,
    LEFT=37, RIGHT=39, UP=38, DOWN=40,
    PAGE_UP=33, PAGE_DOWN=34, HOME=36, END=35, INSERT=45, DELETE=46,
    NUM_FOUR=100, NUM_SIX=102, NUM_EIGHT=104, NUM_TWO=98,
    NUM_NINE=105, NUM_THREE=99, NUM_FIVE=101, ADD=107, SUBTRACT=109,
    Z=90, X=88, C=67, V=86, Q=81, E=69, R=82, T=84, G=71,
}

function M.install(character, opts)
    opts = opts or {}
    M.registry = blank_registry()
    local reg = M.registry

    -- Our modules are require()d and therefore cached; clear them so each scenario
    -- starts with fresh module state (calibration, captured reach, HUD flags).
    for name in pairs(package.loaded) do
        if tostring(name):match("^rvfp_") then package.loaded[name] = nil end
    end

    _G.__mock_character = character
    _G.__mock_ksl = new_ksl(reg, opts)

    _G.print = function(s) reg.output[#reg.output + 1] = tostring(s) end

    _G.Key = {}
    for k, v in pairs(KEYS) do _G.Key[k] = v end
    if opts.drop_key then _G.Key[opts.drop_key] = nil end

    _G.ModifierKey = { SHIFT = 1, CONTROL = 2, ALT = 4 }

    _G.RegisterKeyBind = function(k, fn)
        assert(k ~= nil, "RegisterKeyBind called with nil key")
        reg.keybinds[k] = fn
    end
    _G.RegisterHook = function(path, pre, post)
        if opts.hook_fails then error("hook refused") end
        reg.hooks[path] = { pre = pre, post = post }; return 1, 2
    end
    _G.RegisterConsoleCommandHandler = function(name, fn) reg.commands[name] = fn end
    _G.ExecuteInGameThread = function(fn) fn() end
    _G.ExecuteWithDelay    = function(_, fn) reg.delays[#reg.delays + 1] = fn end
    _G.LoopAsync           = function(ms, fn) reg.loops[#reg.loops + 1] = { ms = ms, fn = fn } end
    _G.NotifyOnNewObject   = function(cls, fn) reg.notifies[cls] = fn end
    _G.FindFirstOf         = function(_) return _G.__mock_character end
    _G.StaticFindObject    = function(path)
        if type(path) == "string" and path:find("KismetSystemLibrary", 1, true) then
            return _G.__mock_ksl
        end
        return nil
    end

    if opts.with_uehelpers ~= false then
        package.loaded["UEHelpers"] = {
            GetPlayer              = function() return _G.__mock_character end,
            GetPlayerController    = function() return _G.__mock_character end,
            GetKismetSystemLibrary = function() return _G.__mock_ksl end,
        }
    else
        package.loaded["UEHelpers"]  = nil
        package.preload["UEHelpers"] = nil
    end
end

function M.reset() M.registry = blank_registry() end

-- Run every registered LoopAsync body once (the feedback loop is one of them).
function M.pump_loops()
    for _, l in ipairs(M.registry.loops) do pcall(l.fn) end
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

M.KEYS = KEYS
return M
