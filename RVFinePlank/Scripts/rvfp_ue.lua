--[[ RVFinePlank — all engine access lives here.

    Rules for this module:
      * every engine call is wrapped; a failure returns nil/false, never throws
      * capabilities are probed once and cached, so a missing API disables the
        feature that needs it instead of spamming the log every frame
      * nothing here knows about keybinds, config or game rules
--]]

local M = {}

local UEHelpers do
    local ok, mod = pcall(require, "UEHelpers")
    if ok then UEHelpers = mod end
end

local cache = {
    ksl       = nil,   -- KismetSystemLibrary default object
    probed    = false,
    can_print = false,
    can_draw  = false,
}

local function try(fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
    return nil
end

-- ------------------------------------------------------------------ lookups

function M.get_character()
    local c
    if UEHelpers and UEHelpers.GetPlayer then c = try(UEHelpers.GetPlayer) end
    if not c or not try(function() return c:IsValid() end) then
        c = try(FindFirstOf, "BP_FirstPersonCharacter_C")
    end
    if c and try(function() return c:IsValid() end) then return c end
    return nil
end

function M.get_controller()
    local pc
    if UEHelpers and UEHelpers.GetPlayerController then pc = try(UEHelpers.GetPlayerController) end
    if not pc or not try(function() return pc:IsValid() end) then
        pc = try(FindFirstOf, "BP_FirstPersonPlayerController_C")
    end
    if pc and try(function() return pc:IsValid() end) then return pc end
    return nil
end

-- KismetSystemLibrary gives us PrintString and the DrawDebug family.
function M.ksl()
    if cache.ksl and try(function() return cache.ksl:IsValid() end) then return cache.ksl end
    local k
    if UEHelpers and UEHelpers.GetKismetSystemLibrary then
        k = try(UEHelpers.GetKismetSystemLibrary)
    end
    if not k then
        k = try(StaticFindObject, "/Script/Engine.Default__KismetSystemLibrary")
    end
    if k and try(function() return k:IsValid() end) then cache.ksl = k; return k end
    return nil
end

-- Any live actor works as a world context object.
function M.world_context()
    return M.get_controller() or M.get_character()
end

-- ------------------------------------------------------------ capabilities

-- Probe once: can we print to screen, can we draw in the world? Features check
-- this and quietly turn themselves off rather than failing every tick.
function M.probe_capabilities()
    if cache.probed then return cache.can_print, cache.can_draw end
    local k, wc = M.ksl(), M.world_context()
    if k and wc then
        cache.can_print = type(k.PrintString) ~= "nil"
        cache.can_draw  = type(k.DrawDebugLine) ~= "nil" and type(k.DrawDebugBox) ~= "nil"
    end
    cache.probed = true
    return cache.can_print, cache.can_draw
end

function M.reset_capabilities()
    cache.probed, cache.ksl = false, nil
end

-- ------------------------------------------------------------------ output

local WHITE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }

--[[ On-screen text.

    The `Key` argument is the important one: PrintString replaces any previous
    message with the same key instead of stacking a new line, which is what makes
    a live readout possible rather than a scrolling wall of text.
--]]
function M.print_screen(text, duration, key, color)
    local k, wc = M.ksl(), M.world_context()
    if not k or not wc then return false end
    local ok = pcall(function()
        k:PrintString(wc, tostring(text), true, false, color or WHITE, duration or 0.2, key or "rvfp")
    end)
    return ok and true or false
end

function M.draw_line(a, b, color, duration, thickness)
    local k, wc = M.ksl(), M.world_context()
    if not k or not wc then return false end
    return pcall(function()
        k:DrawDebugLine(wc, a, b, color or WHITE, duration or 0.0, thickness or 1.0)
    end) and true or false
end

function M.draw_box(center, extent, color, rotation, duration, thickness)
    local k, wc = M.ksl(), M.world_context()
    if not k or not wc then return false end
    return pcall(function()
        k:DrawDebugBox(wc, center, extent, color or WHITE,
                       rotation or { Pitch = 0, Yaw = 0, Roll = 0 },
                       duration or 0.0, thickness or 1.0)
    end) and true or false
end

-- --------------------------------------------------------------- held actor

function M.held_actor(char)
    if not char then return nil end
    local a = try(function() return char.CurrentPickUpActor end)
    if a and try(function() return a:IsValid() end) then return a end
    return nil
end

-- World transform of an actor, as plain Lua tables so the maths module can use it.
function M.actor_transform(actor)
    if not actor then return nil end
    local loc = try(function()
        local v = actor:K2_GetActorLocation()
        return { X = v.X, Y = v.Y, Z = v.Z }
    end)
    local rot = try(function()
        local r = actor:K2_GetActorRotation()
        return { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
    end)
    if not loc or not rot then return nil end
    return { loc = loc, rot = rot }
end

function M.actor_forward(actor)
    if not actor then return nil end
    return try(function()
        local v = actor:GetActorForwardVector()
        return { X = v.X, Y = v.Y, Z = v.Z }
    end)
end

--[[ Half-extent of the held object, for drawing its footprint.

    GetPhysicsMesh is the game's own accessor (returns Success + PrimitiveComponent);
    we prefer it over guessing at component names. Falls back to the actor bounds.
--]]
function M.actor_extent(actor)
    if not actor then return nil end
    local ext = try(function()
        local origin, box = actor:GetActorBounds(false)
        return { X = box.X, Y = box.Y, Z = box.Z }
    end)
    if ext then return ext end
    return try(function()
        local ok, prim = actor:GetPhysicsMesh()
        if not ok or not prim then return nil end
        local b = prim:GetLocalBounds()
        return { X = b.BoxExtent.X, Y = b.BoxExtent.Y, Z = b.BoxExtent.Z }
    end)
end

-- Line trace straight down from a point, to find the surface under the plank.
function M.trace_down(from, distance)
    local k, wc = M.ksl(), M.world_context()
    if not k or not wc then return nil end
    local to = { X = from.X, Y = from.Y, Z = from.Z - (distance or 500.0) }
    local hit = try(function()
        local out = {}
        local blocked = k:LineTraceSingle(wc, from, to, 0, false, {}, 0, out, true,
                                          WHITE, WHITE, 0.0)
        if blocked then return out end
        return nil
    end)
    return hit
end

-- Write an actor's world transform. Used by freeze mode to hold a plank still
-- after the game's own UpdateHoldTransform has moved it.
-- bSweep=false, bTeleport=true: we want an exact placement, not a swept move
-- that could be blocked by the geometry we are trying to line up against.
function M.set_actor_transform(actor, loc, rot)
    if not actor or not loc or not rot then return false end
    return pcall(function()
        actor:K2_SetActorLocationAndRotation(loc, rot, false, true)
    end) and true or false
end

M.color = {
    white  = WHITE,
    green  = { R = 0.25, G = 1.00, B = 0.35, A = 1.0 },
    red    = { R = 1.00, G = 0.25, B = 0.25, A = 1.0 },
    amber  = { R = 1.00, G = 0.72, B = 0.20, A = 1.0 },
    blue   = { R = 0.35, G = 0.65, B = 1.00, A = 1.0 },
    grey   = { R = 0.60, G = 0.60, B = 0.60, A = 1.0 },
}

return M
