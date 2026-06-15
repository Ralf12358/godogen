# VR Architecture — The Rig and Its Two Transforms

The single most important fact about an OpenXR rig in Godot is that
**the player moving their body and the player moving through the world
are two different transforms**. Once that clicks, every other rule
falls out of it.

## The two transforms

A Godot XR rig has exactly two transforms that matter:

| Node | What it represents | What moves it |
|------|--------------------|---------------|
| `XROrigin3D` | Where the player's body is in the **world** (the play space anchor) | Player physically walking, recentre, teleport, smooth-locomotion stick |
| `XRCamera3D` | Where the player's **head** is relative to the body | Head tracking — every frame, as the player looks around, leans, crouches |

```text
XROrigin3D            — play space anchor in the world
├── XRCamera3D        — head, inside the play space
├── XRController3D    — left hand, inside the play space
└── XRController3D    — right hand, inside the play space
```

- **Player physically walks around the room** → the runtime moves
  `XROrigin3D`. The camera, being a child, follows the body.
- **Player looks around, leans, crouches** → the runtime moves
  `XRCamera3D` *only*. `XROrigin3D` stays put.
- **Player presses the smooth-locomotion stick** → game code moves
  `XROrigin3D` (mimicking a walk). The camera, being a child, follows.

In every case, the camera's world transform is
`origin.global_transform * camera.transform`. That single formula
explains the rest of this document.

## What moves what (runtime vs your code)

| Action | Runtime writes | Your code can write |
|--------|----------------|---------------------|
| User looks around | `XRCamera3D.basis` | Never — the runtime owns the head pose |
| User leans / crouches | `XRCamera3D.origin` (local) | Never |
| User physically walks | `XROrigin3D.origin` | Never — the runtime owns room-scale |
| User recentres | `XROrigin3D.basis + origin` | Never |
| Smooth-locomotion stick | — | `XROrigin3D.origin` (and optionally `XROrigin3D.basis` for snap/smooth turn) |
| Teleport | — | `XROrigin3D.origin` |
| User waves a hand | `XRController3D` (left + right) | Never — the runtime owns hand pose |

The split is the same on every backend (OpenXR, OpenXR + SteamVR,
WebXR via godot-webxr, etc.). Do not hard-code `OpenXRInterface` —
use the typed `XRInterface` superclass.

## Where to put your objects: world-fixed vs play-space-attached

Pick by intent. There is no "right" answer in isolation — both are
correct, but they answer different questions.

```text
; World-fixed: floor, walls, ceiling, skybox, scenery, furniture,
; all stationary items. They do NOT move with the player.
[node name="Floor" type="MeshInstance3D" parent="."]

; Play-space-attached: the tool the player is holding, the watch on
; their wrist, anything that is conceptually "on the player's body"
; and should follow them when they teleport.
[node name="HeldTool" type="MeshInstance3D" parent="XROrigin3D"]
```

The rule: **does this object live in the world, or on the player?**

- A wall is world-fixed. Putting it under `XROrigin3D` means it
  travels with the player when they walk — the wall is "in their
  pocket". That's almost never what you want for static geometry.
- A floating UI panel the user is reading, anchored 30 cm in front
  of their face, is play-space-attached. Putting it at the scene
  root means the user has to physically walk to it every time it
  recentres. That's almost never what you want for body-locked UI.
- A pickable prop is more subtle: in the world when no one is holding
  it, attached to the holding hand when grabbed. Toggle its parent
  at grab/release.

The cheap mistake to avoid: decorating a room with cubes parented
under `XROrigin3D`. They look fine when the player is at world
origin; the moment the player walks (or the play space recentres),
the room comes with them and the illusion of being *in* a place
breaks.

## Where to put your code

| Feature | Lives on / under | Why |
|---------|------------------|-----|
| Player movement (smooth-loco, teleport) | `XROrigin3D` | That node *is* the play space |
| HMD-relative things (reticle, fade, body-locked UI) | `XRCamera3D` | That node *is* the head |
| Hand interactions (grab, point, ray UI) | `XRController3D` (left and right) | That node *is* the hand |
| World-fixed (floor, props, walls) | scene root | The world |
| Body-locked but not head-locked (belt UI, wrist menu) | `XROrigin3D` (a child of it, not the camera) | Moves with body, not head |
| Teleport anchors | scene root | Anchors belong to the world |

If you find yourself writing `XRCamera3D.global_transform.basis`
from something *not* parented to the camera, stop and parent it
correctly. The scene tree is the contract; do not recreate it in
code.

## Pose queries

Always go through the nodes, never through
`XRServer.get_reference_frame()`:

- HMD position: `xr_camera.global_transform.origin`
- HMD forward: `-xr_camera.global_transform.basis.z`
- HMD up: `xr_camera.global_transform.basis.y`
- HMD right: `xr_camera.global_transform.basis.x`
- Controller pose: `xr_controller.global_transform`

For hand-relative maths (UI rays, grab points), use
`xr_controller.global_transform` directly — do not manually transform the
controller pose into world space, the node already does that for you.

## Runtime detection — the only correct way

```gdscript
var xr_interface: XRInterface = XRServer.find_interface("OpenXR")
if xr_interface and xr_interface.is_initialized():
    get_viewport().use_xr = true
```

Patterns to avoid:

- `OpenXRInterface` as a literal type — use `XRInterface` and check the
  interface name. The same code is correct on any future XR backend.
- `OS.has_feature("OpenXR")` — returns true when the module is compiled
  in, not when a runtime is present. Lies on a dev machine.
- Caching the interface in a global at autoload time — the interface
  can be initialised *after* the first frame on some backends. Re-query
  in `_ready()`.

When the runtime is missing, `xr_interface` is non-null but
`is_initialized()` is false, and `use_xr` stays false. The viewport renders
as a normal 3D scene. **This is the state the debug path exploits.**

## Eye offsets and IPD

The two eye views come from `XRInterface.get_render_target_size()` and
`XRServer.get_primary_interface().get_view_transforms()`. In debug mode
those calls still work when the interface is initialised; when the
interface is not initialised, you must compute the eye transforms
manually — see the capture recipe in `vr-capture.md`.

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
