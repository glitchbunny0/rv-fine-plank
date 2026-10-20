# RVFinePlank

Fine adjustment of held objects (planks especially) for **RV There Yet?** — a UE4SS Lua mod.

The game already has held-object manipulation; it is just coarse. This mod makes it precise
in two ways, and deliberately does **not** reimplement any of the game's own logic.

| Key | Action |
|---|---|
| `F3` | Toggle fine mode (scales hand-pose input to 15%) |
| `F4` | Probe — dump live hold values to the UE4SS console |
| Numpad `4` / `6` | Yaw the held object by one step |
| Numpad `8` / `2` | Pitch the held object by one step |
| Numpad `+` / `-` | Push away / pull closer by one step |

Console: `rvfine [probe|on|off|scale <f>|step <f>|verbose|hook]`

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

Logic is covered by an off-game test suite (`lua tests/test_main.lua` — 49 assertions against a
mocked UE4SS and a fake character). **Nothing has been verified in the running game yet**; see
`docs/TEST-PLAN.md` for what must be confirmed and `docs/SDK-FINDINGS.md` for which facts are
reverse-engineered certainty versus inference.

## Licence

MIT.
