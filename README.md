# RVFinePlank

[![tests](https://github.com/glitchbunny0/rv-fine-plank/actions/workflows/test.yml/badge.svg)](https://github.com/glitchbunny0/rv-fine-plank/actions/workflows/test.yml)

Fine adjustment of held objects (planks especially) for **RV There Yet?** — a UE4SS Lua mod.

The game already has held-object manipulation; it is just coarse. This mod makes it precise
in two ways, and deliberately does **not** reimplement any of the game's own logic.

| Key | Action |
|---|---|
| `F3` | Toggle fine mode (scales hand-pose input to 15%) |
| `F4` | Toggle the on-screen readout |
| `F5` | Toggle the world alignment guides |
| `F6` | Probe — dump everything to the UE4SS console |
| `F7` | Re-measure the input sensitivity |
| `F8` | Reset (restore stock reach, clear state) |
| `←` / `→` | Yaw by one step (degrees) |
| `↑` / `↓` | Pitch by one step (degrees) |
| `PgUp` / `PgDn` | Push away / pull closer, **fine** (replicated) |
| `Ins` / `Del` | Reach further / closer, **coarse** (see caveat) |
| `Home` | Toggle snapping to a degree grid |
| `End` | Return the pose to neutral |
| `F9` | **Freeze** — park the plank in world space and look around |

Every key is rebindable in `RVFinePlank/Scripts/rvfp_config.lua`. Nothing is on the numpad:
your right hand is on the mouse and your left on WASD, and plenty of keyboards have no numpad.

Console: `rvfine [probe|on|off|scale f|deg f|cm f|snap [f]|nosnap|zero|level|hud|guides|reach cm|reachstep cm|calibrate|reset|verbose|hook]`

## What actually makes placement hard

Worth stating, because it shaped the design. The game holds objects at
`target = CameraLocation + Up×A + Forward×B`, smoothed with `VInterpTo`/`RInterpTo`. So:

1. **The object is welded to your view.** Moving it moves your view *of* it — you can never hold
   it still and inspect the alignment from somewhere else.
2. **It always lags toward its target**, so what you see is not where it will come to rest.
3. **You have no numbers.**

Smaller increments barely touch any of that. This mod therefore leads with **information** (the
readout and the guides), **structure** (snapping, levelling) and **real units** (runtime
calibration), and treats fine mode as the last-millimetre tool it actually is.

## Real degrees, measured at runtime

The game multiplies hand-pose input by a sensitivity constant that is not recoverable from a
static dump, so early versions had opaque step sizes. The mod now **measures it**: it applies a
known probe, observes how far the accumulator moved, and undoes the probe. If the pose happens to
be pinned against the game's clamp it re-probes in the other direction.

After that, `nudge_deg = 1.0` really means one degree, snapping to 15° is meaningful, and the
readout shows true values. `F7` re-measures; the HUD says `UNCALIBRATED` if it has not run.

Large moves iterate, because the game clamps how much a *single* call may contribute — zeroing a
pose from 45° in one call would silently under-shoot.

## Feedback: readout and guides

**On-screen readout** (`F4`) uses `PrintString` with a stable key, so it refreshes in place
instead of scrolling. It shows the live yaw/pitch/push offsets, the plank's **tilt in degrees**
(green under 1.5°, amber above), the current reach against its stock value, and whether
calibration has run. A separate short-lived line confirms each action.

**World guides** (`F5`) draw with the `DrawDebug` family:

- an **oriented footprint box** at the plank's real rotation and extent, so you see the volume
  rather than guessing;
- the plank's **long axis projected** out to where it points — the thing you actually need when
  bridging a gap;
- a **level reference line** along the same heading with zero pitch. The visible gap between that
  and the axis line *is* your tilt error;
- **plumb lines** from each end, to check the ends are over the ledges and not over the gap.

Both self-disable if the engine APIs are unreachable, rather than erroring every frame.

## Freeze (`F9`) — the one that fixes cause #1

Press `F9` while holding a plank and it stops following your camera: it stays exactly where it
was in world space, so you can walk sideways, crouch, and look along the ledge to check whether
it is genuinely seated. Press again to hand it back to the game.

Implemented as a **post-hook** on `UpdateHoldTransform`: the game's own logic runs completely
untouched and the frozen transform is simply written afterwards, so there is no interpolation to
fight. If that hook cannot be installed the mod falls back to a fast timer, which is less smooth
but still works — `rvfine probe` reports which path is active.

It releases itself rather than misbehaving: if the held object changes, or a transform write is
refused, freeze turns off and says why.

**This is a local inspection aid.** `UpdateHoldTransform` is `IsLocallyControlled`-gated and the
write goes through no RPC, so other players still see the plank following your camera while it is
frozen. Nothing persists — unfreeze and the game resumes control — but **unfreeze before nailing**,
so the server agrees about where the plank is.

## Moving the object closer and further

There are two separate distance mechanisms, and the difference matters.

**Fine, and properly networked — numpad `+` / `-`.** `UpdateHoldTransform` computes the hold
target each tick as `CameraLocation + UpVector*A + ForwardVector*B`, and the hand-pose *Fwd* axis
feeds that forward term. Driving it through `HandleHandPoseInput` means the value travels over the
game's own `Server_SetHandPoseInput` RPC, so everyone in the session sees the same plank position.
The game `FClamp`s this axis, so its range is limited — it is for precision, not for reaching
across a ravine.

**Coarse, with a caveat — numpad `9` / `3`.** `LookAtDistanceWhenHoldingItem` is the baseline
distance, a plain double on the character. Writing it moves the object much further in or out than
the clamped axis allows. But `UpdateHoldTransform` is gated on `IsLocallyControlled` and this write
does *not* pass through the server RPC, so **it may be local-only** — correct on your screen while
the server still has the plank at the old distance, which would make nails land in the wrong place.
This is unverified; test item 6 in `docs/TEST-PLAN.md` exists to settle it. Until then, prefer the
fine axis when precision relative to other players matters.

Reach writes are clamped to 40–400 cm, the stock value is captured before the first write, and
numpad `5` (or `rvfine reset`) always restores it — so a stuck key cannot leave your hold distance
permanently wrong.

## How it works

Everything routes through the game's own `BP_FirstPersonCharacter_C::HandleHandPoseInput(Yaw, Pitch, Fwd)`.

- **Fine mode** hooks that function and scales the incoming axes down, so your existing
  mouse movement moves the object proportionally less.
- **Nudge keys** call the same function with a small fixed delta, for repeatable steps.

This matters for co-op: the game's own clamping, its `Server_SetHandPoseInput` RPC and all
replication still run exactly as the developers wrote them. A mod that instead wrote the
transform directly would look correct on your screen and desync for everyone else.

The Blueprint path is resolved at runtime from the live class (`GetFullName()`), never
hardcoded, and all binding is by reflection name rather than SDK offset — so a game patch
does not silently break it.

## Install

Requires **UE4SS v3.0.1-1181 or newer** — that is the first build with UE 5.6 support, which
is the engine this game ships. Get `UE4SS_v3.0.1-<build>.zip` from the
[experimental-latest release](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest).

Unpack UE4SS so that `dwmapi.dll` sits next to `Ride-Win64-Shipping.exe`:

```
<Steam>/steamapps/common/Ride/Ride/Binaries/Win64/
├── Ride-Win64-Shipping.exe
├── dwmapi.dll
└── ue4ss/
    ├── UE4SS.dll
    └── Mods/
        ├── mods.txt
        └── RVFinePlank/        <- this folder
            ├── enabled.txt
            └── Scripts/main.lua
```

`enabled.txt` is enough; no `mods.txt` edit needed. Use `tools/install.sh` on Linux or
`tools/install.ps1` on Windows to copy it into place.

**On Linux/Proton**, UE4SS needs its proxy DLL loaded. Set this as the game's Steam launch option:

```
WINEDLLOVERRIDES="dwmapi=n,b" %command%
```

## Tuning

`nudge_*` values are in *input units*, not degrees or centimetres: the game multiplies them by
its own sensitivity constant before accumulating, and that constant is not readable from a
static dump. The defaults (`0.05`) are a starting guess.

Calibrate in-game: hold a plank, press `F4` to read `HandEmoteYaw`, tap Numpad `6` once, press
`F4` again, and compare. Then set the step you actually want with `rvfine step <f>`.

## Status

Logic is covered by two off-game suites (`./tools/run_tests.sh` — **164 assertions**: 51 pure-maths
and 113 integration against a mocked UE4SS, both run in CI). **Nothing has been verified in the
running game yet**; see `docs/TEST-PLAN.md` for what must be confirmed and `docs/SDK-FINDINGS.md`
for which facts are reverse-engineering certainty versus inference.

Still to come: a ghost placement preview built on the game's own `BP_PrevisActorComponent`.

## Layout

```
RVFinePlank/Scripts/
  main.lua          wiring: keybinds, console, feedback loop, boot
  rvfp_config.lua   all tuning and the keymap — the only file you need to edit
  rvfp_math.lua     pure maths (snapping, calibration arithmetic, geometry)
  rvfp_ue.lua       every engine call, each one guarded
  rvfp_hold.lua     calibration, nudging, snapping, zeroing, reach
  rvfp_hud.lua      the readout and the world guides
  rvfp_freeze.lua   parking the plank in world space
```

`main.lua` puts its own directory on `package.path` before requiring, with a `dofile` fallback,
because UE4SS's own path setup varies between builds.

## Legal

This repository contains no game code, assets, or binaries. The interface names and offsets in
`docs/SDK-FINDINGS.md` were recovered from a community-published Dumper-7 dump and are recorded
only as far as needed to call the game's own functions — which is what interoperability
reverse engineering is for (EU Software Directive 2009/24/EC Art. 6; §69e UrhG in Germany).

The mod changes nothing for other players beyond what the game's own replicated RPC already
carries, and is not a cheat: it makes an existing mechanic finer, nothing more.

## Licence

MIT.
