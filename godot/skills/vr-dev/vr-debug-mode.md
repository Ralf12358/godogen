# VR Debug Mode — Driving the Rig Without a Headset

This is how a project runs on a machine that has no XR runtime. The user
keeps pressing F5 (or `godot --path .`) and the scene loads — they just
see a normal desktop window instead of two eye buffers. To actually
*develop* the VR experience, opt in to debug mode and use the VR player
to drive the rig.

## The opt-in surface

The single source of truth is `examples/VRDebugAutoload.gd`. Add it as an
autoload (`Project → Project Settings → Autoload`) named `VRDebug`. It:

- reads `OS.get_cmdline_user_args()` for `--vr-debug`
- reads `OS.get_environment("VR_DEBUG")`
- exposes `VRDebug.enabled` (bool) and `VRDebug.toggle()` (callable)

Nothing else in the project should re-implement this check.

```gdscript
# examples/VRDebugAutoload.gd
extends Node

signal enabled_changed(enabled: bool)

var enabled: bool = false

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    enabled = _detect()
    if not OS.has_feature("editor") and not enabled:
        # Production / F5 with headset: skip everything.
        return
    set_process(true)

func _detect() -> bool:
    if OS.get_environment("VR_DEBUG") in ["1", "true", "yes", "on"]:
        return true
    for arg in OS.get_cmdline_user_args():
        if arg == "--vr-debug":
            return true
    return false

func toggle() -> void:
    enabled = not enabled
    enabled_changed.emit(enabled)
```

(Production: do not register the autoload. The whole point is that the
debug path is opt-in. The autoload itself is the only file that knows
the flag exists.)

## Driving the rig — `VRPlayer.gd`

Attach `examples/VRPlayer.gd` to the `XROrigin3D` in the consumer's scene.
It does three things, all gated on `VRDebug.enabled`:

1. **Play-space movement** — `XROrigin3D` translation. WASD moves on the
   XZ plane, Shift/Ctrl are down/up, Q/E roll, R resets.
2. **Head rotation** — `XRCamera3D` rotation. Mouse delta in `_unhandled_input`.
   Hold RMB to grab the head (like every first-person controller).
3. **Controller simulation** — both `XRController3D` nodes get poses driven
   by the keyboard (IJKL left hand, arrow keys right hand) and trigger/grip
   buttons mapped to Space/Enter and Z/X.

The script never runs at all when `VRDebug.enabled` is false, so the
runtime takes over the rig on a real headset and the script's
`_process` is a no-op (it just returns at the top).

Read the script for the full mapping. Key conventions:

- Camera rotation is yaw/pitch only (no roll) — feels VR-correct, no
  nausea on long sessions
- Head height is clamped to `[0.4, 2.5] m`
- IPD is a constant at the top of the file, default `0.064` m
- The script prints every binding to stdout on `_ready` so the user
  always knows the controls

## HUD

`VRPlayer.gd` installs a small `CanvasLayer` with a `Label` in the
top-left. It shows:

- `VR_DEBUG=1` banner
- origin transform
- camera rotation
- left/right controller position
- FPS (5-frame moving average)

The HUD is added by `VRPlayer.gd` as a child of itself when the debug
flag flips on. To make a screenshot, hide it by pressing F2 (the
script binds it) or by setting `_hud.visible = false` from outside.

## Toggling the flag at runtime

In the running scene:

- `F1` — toggle the entire debug path on/off
- `F2` — toggle the HUD
- `F3` — reset the play space to (0, 0, 0)

These shortcuts come from `VRPlayer.gd`. They only fire when
`VRDebug.enabled` is true, so they do not exist on a real headset
machine.

## What to add to a fresh scene

1. Add `XROrigin3D` + `XRCamera3D` + two `XRController3D` (with the
   `tracker = "left_hand"` / `"right_hand"` set in the inspector — Godot
   sets them automatically when you right-click the XROrigin3D and pick
   "Add XR Children").
2. Parent any player-attached geometry under the `XROrigin3D`.
3. Attach `VRPlayer.gd` to the `XROrigin3D`.
4. (Optional) Add the autoload.
5. (Optional) Drop a `CanvasLayer` for a custom HUD.

For a non-VR project that wants to preview the rig on a desktop, the
same five steps apply, but skip the autoload and just keep the player
script always-on via `OS.get_environment("VR_DEBUG") == "1"`.

## Common mistakes

- **Driving `XRCamera3D.global_transform` from a script that also runs
  on a real headset.** The runtime owns that transform. Read it, do not
  write it. The debug script only writes when `VRDebug.enabled` is true.
- **Setting `use_xr = true` in `main.gd` regardless of init.** Always
  guard on `is_initialized()`.
- **Reading `Input.is_action_pressed("ui_up")` for VR motion.** That
  reads keyboard, not controllers. Use the action map.
