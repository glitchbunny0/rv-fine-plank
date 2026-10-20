--[[ RVFinePlank — configuration and keymap defaults.

    Edit this file to rebind. Key names are UE4SS `Key` table entries; an unknown
    name is warned about at load and simply left unbound, so a typo here cannot
    stop the mod from working.

    KEY CHOICE RATIONALE
    The numpad was a mistake in 0.1-0.2: your right hand is on the mouse and your
    left on WASD, so reaching it means abandoning one, and plenty of keyboards do
    not have one at all. Defaults now use the arrow cluster and the nav block,
    which a WASD-movement game is very unlikely to bind. Fine mode itself needs no
    keys during use — it scales the mouse you are already holding.
--]]

return {
    -- ---------------------------------------------------------------- behaviour
    fine_scale   = 0.15,   -- input multiplier while fine mode is on

    -- Nudge sizes in REAL UNITS. Valid once calibration has run (it converts
    -- these into the game's opaque input units automatically).
    nudge_deg    = 1.0,    -- degrees per tap, yaw and pitch
    nudge_cm     = 1.0,    -- cm per tap on the push/pull axis

    snap_deg     = 15.0,   -- snapping increment when snap mode is on
    snap_enabled = false,  -- off by default; it changes feel significantly

    -- Coarse reach (writes LookAtDistanceWhenHoldingItem — see README caveat)
    reach_step   = 5.0,
    reach_min    = 40.0,
    reach_max    = 400.0,

    -- ---------------------------------------------------------------- feedback
    hud          = true,   -- on-screen readout while holding something
    hud_interval = 0.1,    -- seconds between HUD refreshes
    guides       = true,   -- world-space alignment guides
    guide_length = 600.0,  -- cm; how far to project the plank's axis
    verbose      = false,  -- log every action to the UE4SS console

    -- Calibration: measure the game's input sensitivity once so that nudge_deg
    -- really means degrees. Without it we fall back to raw input units.
    calibrate       = true,
    calibrate_probe = 0.05,  -- probe delta used for the measurement

    -- Freeze fallback: if the UpdateHoldTransform post-hook cannot be installed,
    -- re-apply the frozen transform on this interval instead (seconds).
    freeze_fallback_interval = 0.016,

    -- ---------------------------------------------------------------- keymap
    keys = {
        fine_toggle  = "F3",          -- scale mouse input down
        hud_toggle   = "F4",
        guides_toggle= "F5",
        probe        = "F6",          -- dump everything to the UE4SS console
        recalibrate  = "F7",

        yaw_minus    = "LEFT",
        yaw_plus     = "RIGHT",
        pitch_plus   = "UP",
        pitch_minus  = "DOWN",

        push         = "PAGE_UP",     -- fine, replicated (hand-pose Fwd axis)
        pull         = "PAGE_DOWN",

        reach_out    = "INSERT",      -- coarse, possibly local-only
        reach_in     = "DELETE",

        snap_toggle  = "HOME",
        zero_pose    = "END",         -- return the pose to neutral
        freeze       = "F9",          -- park the plank in world space and look around
        reset_all    = "F8",          -- restore stock reach + clear state
    },
}
