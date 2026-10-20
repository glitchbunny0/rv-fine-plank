# SDK findings — RV There Yet? held-object system

All of this was recovered **without installing the game**, by mining the Dumper-7 SDK published
in [`LeoCholvy/RV_there_yet_SteeringWheel_Compatibility_Mod`](https://github.com/LeoCholvy/RV_there_yet_SteeringWheel_Compatibility_Mod)
(`SDK/Assertions.inl`, 28 MB, 27,377 types). Dumper-7 emits `static_assert(offsetof(...))` lines
per type, which gives exact member names and offsets; it also emits one struct per function
containing that function's parameters *and its Blueprint graph temporaries*, which leaks the
shape of the logic.

Game: app `3949040`, `installdir` **Ride**, binary `Ride-Win64-Shipping.exe`, **Unreal Engine 5.6**.

## Certain (read directly from the dump)

### `BP_FirstPersonCharacter_C` members

| Offset | Member | Type (from offset delta) |
|---|---|---|
| `0x007B0` | `HoldTransform` | — |
| `0x00808` | `LookAtDistanceWhenHoldingItem` | double |
| `0x00918` | `CurrentPickUpActor` | object ptr |
| `0x00980` | `InitialHoldTransform` | FTransform (0x60) |
| `0x009F0` | `CachedInitialHoldTransform` | FTransform (0x60) |
| `0x00A50` | `HoldTransformTargetLocation` | FVector, 3×double (0x18) |
| `0x00A68` | `HoldTransformTargetRotation` | FRotator, 3×double (0x18) |
| `0x00B68` | `IsHolding` | bool |
| `0x00B69` | `IsHandPosing` | bool |
| `0x00B70` | `HandEmoteYaw` | double |
| `0x00B78` | `HandEmotePitch` | double |
| `0x00B80` | `HandEmoteFwd` | double |
| `0x00B88` | `HandEmoteRight` | bool |
| `0x00B89` | `HandEmoteLeft` | bool |

### Relevant functions

- `HandleHandPoseInput(Yaw, Pitch, Fwd)` — three doubles in.
- `Server_SetHandPoseInput(HandEmoteInput)` — single parameter, server RPC.
- `UpdateHoldTransform(DeltaSeconds)`
- `SetNewAttachTransform(NewTransform) -> Success`
- `RepositionLocalAttachPointPrevisActor`, `TryCreateLocalAttachPointPrevisActor`
- Input actions present on the character include `IA_ToggleHandMode`, `IA_Drop`, `IA_Interact`,
  `IA_MouseWheel`, `IA_Emotes`, `IA_PrimaryFire`, `IA_SecondaryFire`.

### Graph structure leaked by the param structs

`HandleHandPoseInput` temporaries, in order: `Multiply_DoubleDouble` ×2, `FClamp` ×2,
`Multiply_DoubleDouble` ×2, `NearlyEqual_FloatFloat` ×2, `SelectFloat` ×2,
`Add_DoubleDouble` ×2, `FClamp` ×2, `Add_DoubleDouble`, `FClamp`, `MakeVector`,
**`IsServer`**, then further `Add_DoubleDouble` / `FClamp` pairs.

→ multiply by sensitivity, clamp, deadzone-check, accumulate, clamp the accumulator,
pack into a vector, branch on server/client.

`UpdateHoldTransform` temporaries: `IsLocallyControlled`, `K2_GetComponentLocation/Rotation`,
`GetBaseAimRotation`, **`RInterpTo`**, **`VInterpTo`**, `BreakTransform`,
`K2_SetWorldLocationAndRotation` (with `SweepHitResult`), `BreakVector_X/Y/Z`,
`GetBaseAimRotation_1`, `Conv_DoubleToVector`, `GetUpVector`, `GetForwardVector`,
`Multiply_VectorVector`, `Conv_DoubleToVector_1`, `Multiply_VectorVector_1`,
`K2_GetComponentLocation_1`, `Add_VectorVector`, `Add_VectorVector_1`.

Read in offset order that is an unambiguous construction:

```
target = CameraLocation
       + UpVector      * A      -- Conv_DoubleToVector  -> Multiply_VectorVector
       + ForwardVector * B      -- Conv_DoubleToVector_1 -> Multiply_VectorVector_1
```

where `A` and `B` are doubles pulled out by `BreakVector_X/Y/Z` — i.e. components of the
hand-pose vector that `HandleHandPoseInput` assembles with `MakeVector`. The result is smoothed
by `VInterpTo`/`RInterpTo` and committed with a swept `SetWorldLocationAndRotation`, only for the
locally controlled pawn.

**Consequence for distance control:** the *Fwd* hand-pose axis is the along-view distance term, so
pushing and pulling the held object is the same code path as rotating it — and it inherits the
`FClamp` from `HandleHandPoseInput`, which bounds how far it can travel.
`LookAtDistanceWhenHoldingItem` (`0x808`, double, sits directly after `LookAtDistance` at `0x800`)
is the separate baseline with no such clamp.

### Planks are not a dedicated class

There is no plank actor class. Planks are instances of the generic **`ABP_Interactable_Actor_C`**,
which carries its own `HoldTransform` (`0x2D0`), `FPPHoldOffset` (`0x510`), `TPPHoldOffset` (`0x570`),
a replicated `Nails` array (`0x730`) with `OnRep_Nails`, and the functions `GetCustomHoldTransform`,
`ShouldUseHoldTransform`, `GetAttachOffset`, `SetNewAttachTransform`, plus the physics-state
setters `SetPickedUpPhysicsState` / `SetAttachedPhysicsState` / `SetFastenedPhysicsState` /
`SetDroppedPhysicsState`.

Per-item hold tuning is therefore a first-class concept in their design — a plank-only profile is
legitimate rather than a hack.

Nailing is server-authoritative: `BP_FirstPersonPlayerController_C::Server_TrySpawnNail`,
`Server_TrySpawnNailProjectile`, `Server_TryRemoveNailOnPlank`, and a `BPI_Interact` interface
with `AddNail` / `CanBeNailed` / `RemoveNail` implemented across many actors.

## Inferred (not certain — verify in game)

1. **`HandEmoteInput` is probably an `FVector`** packing (Yaw, Pitch, Fwd), because
   `HandleHandPoseInput` contains a `MakeVector` immediately before its `IsServer` branch.
   *The mod avoids depending on this* by calling `HandleHandPoseInput` rather than the RPC.
2. **The sensitivity constant and clamp limits are unknown.** Blueprint literals are not in the
   dump. This is why `nudge_*` needs in-game calibration.
3. **Whether hand-pose input is gated on `IsHandPosing`.** The mod logs a note but still calls
   through, letting the game decide.
4. **Whether writing `LookAtDistanceWhenHoldingItem` replicates.** It does not pass through
   `Server_SetHandPoseInput`, and `UpdateHoldTransform` is `IsLocallyControlled`-gated, so the
   coarse reach control may be local-only. If so, a nail placed after a reach change lands where
   the *server* thinks the plank is. This is the single most important thing to test.
5. **Whether the server quantizes the replicated pose.** Would look smooth locally and steppy to
   other players. Only a two-client test shows this.
6. **Mouse wheel is probably not hold distance.** `IA_MouseWheel` has exactly one handler on the
   character and its body lives in the ubergraph, so it is not readable from the dump — but the
   character also owns `Radial_Wheel_AC` with `On_Active_Slot_Changed` / `On_Selection_Changed`,
   which suggests the wheel drives item selection rather than distance.
7. **The `/Game/` asset path of `BP_FirstPersonCharacter`.** Not recoverable from the dump, hence
   runtime path discovery.

## Caveat on offsets

The offsets above come from one community dump of one build and **will shift on game updates**.
They are documentation, not a runtime dependency: the mod binds everything by reflection name.
