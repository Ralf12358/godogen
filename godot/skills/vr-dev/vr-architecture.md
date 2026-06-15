# VR Architecture — Reading the Rig at Runtime

A Godot VR project uses three core node types from Godot's XR module. This
file is the contract every VR feature must follow.

## The node trio

```text
XROrigin3D            — room-anchored play space
├── XRCamera3D        (HMD pose)         — head, inside the play space
├── XRController3D    (left hand)        — pose only
└── XRController3D    (right hand)       — pose only
```

The two transforms answer different questions:

- **`XROrigin3D` transform = "where is the play space in the room?"**
  The runtime sets this once when the play space is established (room-scale
  setup, recenter, teleport). It does **not** change frame-to-frame from
  head motion. Smooth-locomotion code may translate it when the player
  presses a stick, but head tracking alone does not move it.
- **`XRCamera3D` transform = "where is the user's head inside the play
  space?"** This is what the runtime writes every frame from head tracking.
  It can change rapidly and is the only thing the runtime moves for pure
  head motion (looking around, leaning, crouching).

If you want to drive a "VR player" in debug mode, move the `XRCamera3D`'s
local transform. Do **not** move the `XROrigin3D` for head motion — that
mocks room-scale translation, not head tracking, and gives a misleading
verification image when the scene has play-space-attached objects.

## What moves what

| Action                 | Runtime writes...         | Debug path writes...        |
|------------------------|---------------------------|------------------------------|
| User looks around      | `XRCamera3D.basis`        | `XRCamera3D.basis`           |
| User leans / crouches  | `XRCamera3D.origin`       | `XRCamera3D.origin` (local)  |
| User physically walks  | `XROrigin3D.origin` (room) | `XROrigin3D.origin`          |
| Smooth-locomotion stick| `XROrigin3D.origin` (teleport) | `XROrigin3D.origin`     |
| User waves a hand      | `XRController3D`          | `XRController3D`             |

In a play-space-attached object, the world transform is the parent's
transform times the local transform. So:

- Head-only motion: the play-space-attached object's world position does
  not change relative to the room.
- Play-space translation: the attached object's world position moves with
  the play space, so from the user's point of view the object stays at
  the same place inside the play space while the world moves past.

## Parentage: where do my objects go?

Two layouts, pick by intent:

```text
; World-fixed: floor, walls, props, skybox, all stationary items.
; These do NOT move with the player.
[node name="Floor" type="MeshInstance3D" parent="."]

; Play-space-attached: hand-held tools, body-worn UI, the cubes the
; user has picked up. These follow the player when they teleport or
; the play space recenters. With head-only motion they look stationary.
[node name="Tool" type="MeshInstance3D" parent="XROrigin3D"]
```

Both layouts are correct; choose based on what the object is *for*. The
verification scene `test/world_test.tscn` (in this skill) puts the markers
at the root (world-fixed) so that walking visibly moves them across the
frame — that is the right choice for verifying rig motion. A consumer
project that puts the demo objects under the `XROrigin3D` is making a
"props the player carries" choice, which is correct for that intent but
makes rig-motion verification confusing because the props follow the
player. See `vr-verification.md` for the full explanation.

## Runtime detection — the only correct way

```gdscript
var xr_interface: XRInterface = XRServer.find_interface("OpenXR")
if xr_interface and xr_interface.is_initialized():
    get_viewport().use_xr = true
```

Patterns to avoid:

- `OpenXRInterface` as a literal type — use `XRInterface` and check the
  interface name. The same code is correct on any future XR backend.
- `OS.has_feature("OpenXR")` — returns true when the module is compiled in,
  not when a runtime is present. Lies on a dev machine.
- Caching the interface in a global at autoload time — the interface can be
  initialised *after* the first frame on some backends. Re-query in
  `_ready()`.

When the runtime is missing, `xr_interface` is non-null but
`is_initialized()` is false, and `use_xr` stays false. The viewport renders
as a normal 3D scene. **This is the state the debug path exploits.**

## Pose queries

Always go through the nodes, never through `XRServer.get_reference_frame()`:

- HMD position: `xr_camera.global_transform.origin`
- HMD forward: `-xr_camera.global_transform.basis.z`
- HMD up: `xr_camera.global_transform.basis.y`
- HMD right: `xr_camera.global_transform.basis.x`
- Controller pose: `xr_controller.global_transform`

For hand-relative maths (UI rays, grab points), use
`xr_controller.global_transform` directly — do not manually transform the
controller pose into world space, the node already does that for you.

## Eye offsets and IPD

The two eye views come from `XRInterface.get_render_target_size()` and
`XRServer.get_primary_interface().get_view_transforms()`. In debug mode
those calls still work when the interface is initialised; when the
interface is not initialised, you must compute the eye transforms
manually — see `vr-capture.md`.

Default IPD is 0.064 m (64 mm). Make it configurable in the debug HUD
so the user can sanity-check the stereo separation.

## Action map

The action map asset (typically `openxr_action_map.tres` at the project
root) is the source of truth for button and axis names. Reads in code:

```gdscript
@onready var trigger: XRController3D = $XROrigin3D/RightController
if trigger.is_button_pressed("trigger_click"):
    ...
```

Do not hard-code `ax_button`, `by_button` etc. in code — look them up in
the .tres file. If a project does not have an action map, the capture
script and VR player can fall back to keyboard simulation (see
`vr-debug-mode.md`); for real runtime usage the consumer must author an
action map.

## Where to put VR code

| Feature | Lives on / under |
|---------|------------------|
| Player movement (debug + real) | `XROrigin3D` (transform = play space) |
| HMD-relative things (reticle, fade) | `XRCamera3D` (transform = head) |
| Hand interactions (grab, point) | `XRController3D` (left and right) |
| World-fixed (floor, props, walls) | scene root |
| Teleport anchors | `XROrigin3D` (so they move with player) |

If you find yourself writing `XRCamera3D.global_transform.basis` from
something *not* parented to the camera, stop and parent it correctly. The
scene tree is the contract; do not recreate it in code.
