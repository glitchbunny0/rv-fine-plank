# In-game test plan

Nothing below has been run yet. Ordered so that each step de-risks the next, and the two
genuinely uncertain things (calibration, multiplayer quantization) come before any polish.

## 0. Harness

- UE4SS v3.0.1-1181+ installed next to `Ride-Win64-Shipping.exe`; `ue4ss/UE4SS.log` exists after launch.
- On Proton: launch option `WINEDLLOVERRIDES="dwmapi=n,b" %command%`.
- Confirm the load line appears in the log: `[RVFinePlank] v0.4.0 loaded — 17 keybinds bound.`
  - If it says fewer than 17, a `Key` name differs in that UE4SS build; the log names which one.
- Confirm `freeze post-hook installed` also appears. If it says "unavailable", freeze will use
  the timer fallback — note it, because the feel will differ.

## 1. Hook attaches

Load a save, then run `rvfine probe`.

- Expect `hooked=true` and a resolved path in the log.
- If `hook deferred` persists, run `rvfine hook` manually once in-game and check the path printed.
- **Failure mode to watch:** `RegisterHook FAILED` means the derived path is wrong — capture the
  `GetFullName()` string from the log and compare against the real asset path.

## 2. Probe reads real values

Pick up a plank. `rvfine probe`.

- `IsHolding` must be `true`, `CurrentPickUpActor` must name a `BP_Interactable_Actor_C` instance.
- `HandEmoteYaw/Pitch/Fwd` must be readable numbers, not `<unreadable>`.
- **If any field reads `<unreadable>`**, the property name differs from the dump — stop and re-dump
  with UE4SS's own `.jmap`/`.usmap` dumper rather than guessing.

## 3. Calibrate the step size (the main unknown)

Hold a plank, enter hand mode (`IA_ToggleHandMode` — the game's own key).

Calibration now runs itself on first use, so start by just checking it worked: `rvfine probe` and
read `sensitivity` and `calibration`. Expect a number and a note like `0.350 deg per unit`.

- If it says `pose did not respond`, hand-pose input is being ignored — most likely you are not in
  the game's hand mode. Enter it and press `F7`.
- If it reports `reverse probe`, the pose was pinned at a clamp; harmless, and worth noting that
  the clamp is reachable.

Then verify the units are real: set `rvfine deg 1`, note `HandEmoteYaw` via `F6`, tap `→` once,
and confirm it moved by exactly 1.00. Then find the clamp ceiling by holding `→` until the HUD
stops changing, and record it — that figure decides whether fine adjustment alone covers the
range you need.

## 3b. Feedback channels

- `F4`: the readout should appear on screen and refresh in place (not scroll). If nothing appears,
  `rvfine probe` will say `can print to screen false` — that means `PrintString` is unreachable and
  the HUD has disabled itself.
- `F5`: guides should appear around the plank — an oriented box, a long axis line, a blue level
  reference, and two plumb lines. `can draw in world false` means the `DrawDebug` family is
  unreachable.
- Tilt the plank and confirm the box/axis turn amber above ~1.5° and the HUD `tilt` figure agrees
  with what you see.

## 4. Freeze

Hold a plank, aim it at a ledge, press `F9`.

- The plank must stop following the camera. Walk sideways and look along it.
- Press `F9` again: the game takes over and the plank snaps back to the camera-relative hold.
- `rvfine probe` should show `frozen true`, `freeze post-hook true` and a rising `freeze reapplies`.
- Drop the plank while frozen, or pick up something else, and confirm freeze releases itself with
  a reason rather than teleporting the wrong object.
- **Do not nail while frozen.** Unfreeze first. Then test whether nailing after an unfreeze lands
  correctly (this is part of step 5).

## 5. Fine mode feel

`F3` on, move the mouse in hand mode, confirm the plank moves visibly slower; `F3` off, confirm it
returns to stock speed. Try `rvfine scale 0.05` and `0.4` to find a comfortable value.

Check that fine mode does **not** affect normal camera look — it must only touch hand-pose input.
If camera movement is also damped, the hook is on the wrong function.

## 5. The point of the whole exercise

Line a plank up against a ledge with fine mode, then nail it with the nail gun.

- The nail must land where the plank visually is.
- Nailing goes through `Server_TrySpawnNail` server-side, so this is the real test of whether the
  finely-placed transform actually reached the server.

## 5b. Reach — settle whether it replicates (the biggest open question)

Solo first: hold a plank, `rvfine probe` to note `Reach(holding)`, tap numpad `9` five times,
probe again. The value should have moved by `5 × reach_step` and the plank should visibly sit
further away.

- If the log says **"write did not stick"**, the property is recomputed each tick and the coarse
  control is not viable — drop it and rely on the Fwd axis alone.
- Confirm numpad `5` restores the stock value, and that it survives dropping and re-grabbing.

Then with two clients, because this is the part that cannot be inferred: change reach as a client
and have the host watch the plank. If the host sees it at the **old** distance, the write is
local-only — in that case the coarse control must be documented as cosmetic-only and must never be
used before nailing. Verify by nailing after a reach change and checking where the nail lands on
the host's screen.

## 6. Multiplayer (do not skip)

Two clients, one hosting.

- Client adjusts a plank finely; **host watches**. Smooth on both screens, or steppy on the remote?
  Steppy remote = the server quantizes the pose; the fix is then to reduce the *rate* of nudges
  rather than their size, or accept coarser replication.
- Host adjusts; client watches. Same check.
- Nail a finely-placed plank as the client, confirm the host sees the nail in the same spot.
- Confirm the mod being absent on the other client causes no desync (it should not — all state
  flows through the game's own RPC).

## 7. Regression

Re-run `lua tests/test_main.lua` after any change; 49 assertions must stay green. Add a case for
anything found in-game that the mock got wrong — especially if the real sensitivity or clamp
behaviour differs from the mock's `SENS = 2.0` / `±45` assumptions.
