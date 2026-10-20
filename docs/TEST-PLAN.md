# In-game test plan

Nothing below has been run yet. Ordered so that each step de-risks the next, and the two
genuinely uncertain things (calibration, multiplayer quantization) come before any polish.

## 0. Harness

- UE4SS v3.0.1-1181+ installed next to `Ride-Win64-Shipping.exe`; `ue4ss/UE4SS.log` exists after launch.
- On Proton: launch option `WINEDLLOVERRIDES="dwmapi=n,b" %command%`.
- Confirm the load line appears in the log: `[RVFinePlank] v0.1.0 loaded — 8 keybinds bound.`
  - If it says fewer than 8, a `Key` name differs in that UE4SS build; the log names which one.

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

1. `rvfine probe` → note `HandEmoteYaw`.
2. Tap Numpad `6` once.
3. `rvfine probe` → note the new value.

The delta per tap equals `nudge_yaw × <sensitivity>`. Compute the sensitivity, then set a step that
corresponds to roughly 1° per tap via `rvfine step <f>`. Record the number in the README.

Also note the clamp ceiling: hold Numpad `6` until the value stops rising. That is the usable range,
and it determines whether fine mode needs a complementary coarse mode to cover distance.

## 4. Fine mode feel

`F3` on, move the mouse in hand mode, confirm the plank moves visibly slower; `F3` off, confirm it
returns to stock speed. Try `rvfine scale 0.05` and `0.4` to find a comfortable value.

Check that fine mode does **not** affect normal camera look — it must only touch hand-pose input.
If camera movement is also damped, the hook is on the wrong function.

## 5. The point of the whole exercise

Line a plank up against a ledge with fine mode, then nail it with the nail gun.

- The nail must land where the plank visually is.
- Nailing goes through `Server_TrySpawnNail` server-side, so this is the real test of whether the
  finely-placed transform actually reached the server.

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
