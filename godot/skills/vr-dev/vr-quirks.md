# VR Quirks — Godot 4.6 + OpenXR Gotchas

Things that look wrong and are not bugs in your code. If you hit any of
these, fix the cause — do not add a fallback. Fallbacks hide the real
issue and make it unfixable later.

## Runtime-less launch

When the workstation has no `active_runtime.json`, Godot prints
`OpenXR was requested but failed to start. HMD was not detected or a
required feature was not supported.` and falls back to desktop mode.
The scene loads, the XR nodes are present but the runtime is **not**
initialised, so `XRServer.primary_interface.is_initialized()` returns
false and no transforms get written.

This is the state the debug path uses. Do not try to "force" the
runtime — the user wants the rig to be drivable from the keyboard.
Add `--xr-mode off` to suppress the warning when running CI.

## `use_xr` is a one-way latch

`Viewport.use_xr = true` engages the runtime's render pipeline. The
inverse, `use_xr = false`, does **not** disengage cleanly if any
`XRController3D` is in the tree — the controller nodes keep tracking
nothing. Always check `is_initialized()` *before* setting `use_xr = true`.
Never set it to false at runtime.

## `XRServer.find_interface("OpenXR")` returns non-null without a runtime

`find_interface` returns the registered interface object regardless of
whether the runtime is present. Always check `.is_initialized()`
afterwards. The interface can be `null` only if the OpenXR module was
not compiled in (very rare on official builds).

## `XRController3D` has no `transform` on construction

In the editor, the inspector shows the pose, but at runtime the
transform stays at identity until the runtime pushes the first pose.
Reading `controller.global_transform` on frame 0 of a real session
gives identity. The debug path writes the transform from input — make
sure `VRPlayer.gd` writes *every* frame, not just on input, or the
first frame of a screenshot is the wrong pose.

## `OpenXR` is a string, not a class name

`XRInterface` is the typed superclass. `OpenXRInterface` exists but
hard-coding it locks the project to OpenXR. Use
`XRServer.find_interface("OpenXR")` so future backends work too.

## IPD is not exposed on the interface

`XRInterface` has `get_render_target_size()` and
`get_view_transforms()` (for the active eye) but not a public IPD
constant. For a rig that wants to show IPD in the HUD, store it on
the camera or read it from a project setting. Default 0.064 m is
the engineering convention, not an API guarantee.

## `--xr-mode` CLI flag values

- `default` — engine's pick (respects `openxr/enabled` in
  `project.godot`)
- `on` — force XR on, fail loudly if no runtime
- `off` — force XR off, do not even try to initialise

The debug path uses `off` so we get a deterministic desktop window
with no warning spam.

## `XRController3D` button names come from the action map, not Godot

`controller.is_button_pressed("trigger_click")` looks up the action
in the project's action map asset (typically
`openxr_action_map.tres`). If the action is missing, the call returns
false silently. Always verify the action name exists in the .tres
file before binding UI to it.

## The `viewport.use_xr = true` call happens once, in `_ready`

The init script should do this in `_ready()`. If a scene is loaded
later (e.g. from a main menu), the new viewport is the root viewport,
and the runtime keeps using the original one. Always re-check on
scene change. Note this for future multi-scene work.

## Headless XR initialisation always fails — by design

There is no useful "headless XR" mode in Godot 4.6: even with
`--headless`, OpenXR initialisation tries to talk to the loader and
fails the same way it does without `--headless`. The fallback is
`is_initialized() == false`, not a special code path. The capture
script relies on this — it never sets `use_xr = true` and reads
poses directly from the `XRCamera3D` node.

## Audio spatializer needs explicit init

`AudioServer.set_bus_layout()` does not include a spatializer bus
automatically. If you ship a project with `Godot AudioServer
Spacialization: MSHR`, the runtime will not add the bus until you
enable the project setting `audio/general/3d_audio`. Not a VR
quirk, but easy to trip over when migrating from a desktop project.

## `--write-movie` and SubViewports

The movie writer captures the main viewport. SubViewports are
*not* captured. If the screenshot path uses SubViewports, you must
either (a) blit them into the main viewport via a CanvasLayer
(as the capture script does), or (b) call `save_png` directly from
script. The capture script does (a) for the side-by-side preview
and (b) for the per-eye PNGs.

## XRCamera3D as a child of XROrigin3D — never the reverse

If you put the origin under the camera, the camera's global
transform becomes identity every frame (because the origin is at
identity relative to itself). Common mistake when reorganising a
scene. The right hierarchy is exactly: Origin > Camera, with the
camera as a direct child.
