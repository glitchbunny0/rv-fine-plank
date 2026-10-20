--[[ RVFinePlank — freeze/park: hold the plank still while you move the camera.

    THE PROBLEM THIS SOLVES

    UpdateHoldTransform recomputes the hold target from the camera every tick:
        target = CameraLocation + Up*A + Forward*B
    so the plank is rigidly welded to your view. To adjust it you must move your
    head, which moves your view of the thing you are adjusting. You can never park
    it against a ledge and step sideways to check whether it is actually seated.

    HOW

    Capture the plank's world transform, then re-apply it immediately AFTER the
    game has moved it. A UE4SS *post* hook on UpdateHoldTransform is the right
    place: the game's logic runs untouched and we simply overwrite the result, so
    there is nothing to fight and no interpolation to unpick. If that hook cannot
    be installed we fall back to a fast timer, which is visibly less smooth but
    still usable.

    HONEST LIMITS

    This is a LOCAL inspection aid. UpdateHoldTransform is gated on
    IsLocallyControlled and our write does not go through any RPC, so other players
    keep seeing the plank follow your camera while it is frozen. Nothing permanent
    happens — unfreeze and the game resumes control — so no state can be corrupted,
    but do not freeze and then nail: unfreeze first, let the plank settle, and nail
    from the normal hold so the server agrees about where it is.
--]]

local ue = require("rvfp_ue")

local M = {}

M.state = {
    frozen        = false,
    loc           = nil,   -- captured world location
    rot           = nil,   -- captured world rotation
    actor         = nil,   -- the actor we froze (so we notice if it changes)
    post_hooked   = false, -- true once the UpdateHoldTransform post-hook is in
    reapplies     = 0,     -- how many times we have rewritten the transform
    last_error    = nil,
}

-- Capture the current transform and start holding it.
function M.freeze(actor)
    if not actor then
        M.state.last_error = "nothing to freeze"
        return false, M.state.last_error
    end
    local xf = ue.actor_transform(actor)
    if not xf then
        M.state.last_error = "could not read the actor transform"
        return false, M.state.last_error
    end
    M.state.loc, M.state.rot = xf.loc, xf.rot
    M.state.actor  = actor
    M.state.frozen = true
    M.state.reapplies = 0
    M.state.last_error = nil
    return true
end

function M.unfreeze()
    local was = M.state.frozen
    M.state.frozen = false
    M.state.actor, M.state.loc, M.state.rot = nil, nil, nil
    return was
end

function M.toggle(actor)
    if M.state.frozen then
        M.unfreeze()
        return false
    end
    local ok, err = M.freeze(actor)
    return ok, err
end

--[[ Re-apply the frozen transform. Safe to call every tick; cheap no-op when not
     frozen. Returns true when it actually wrote.

     If the held actor has changed under us (dropped and picked something else up)
     we release rather than teleporting the wrong object. --]]
function M.hold_still(current_actor)
    local st = M.state
    if not st.frozen then return false end
    if not st.actor then M.unfreeze(); return false end

    if current_actor ~= nil and current_actor ~= st.actor then
        st.last_error = "held object changed — released the freeze"
        M.unfreeze()
        return false
    end

    local ok = pcall(function() return st.actor:IsValid() end)
    if not ok then M.unfreeze(); return false end

    if ue.set_actor_transform(st.actor, st.loc, st.rot) then
        st.reapplies = st.reapplies + 1
        return true
    end

    st.last_error = "transform write failed — released the freeze"
    M.unfreeze()
    return false
end

--[[ Install the post-hook on UpdateHoldTransform.

    `class_path` is the already-resolved Blueprint class path (same one the
    fine-mode hook uses), so this module does no discovery of its own.
    `get_actor` is a callback returning the currently held actor, used to notice
    when it changes.
--]]
function M.install_post_hook(class_path, get_actor)
    if M.state.post_hooked then return true end
    if not class_path then return false, "no class path" end

    local path = class_path .. ":UpdateHoldTransform"
    local ok, err = pcall(RegisterHook, path,
        function() end,                                  -- pre: nothing to do
        function()                                       -- post: overwrite the result
            if not M.state.frozen then return end
            M.hold_still(get_actor and get_actor() or nil)
        end)

    if not ok then
        M.state.last_error = tostring(err)
        return false, M.state.last_error
    end
    M.state.post_hooked = true
    return true
end

return M
