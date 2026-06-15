---
name: vr-dev
display_name: VR Development
short_description: Develop and test Godot VR (OpenXR) projects on a machine without a runtime
default_prompt: "Use ${VR_DEV_COMMAND} to develop, debug, and visually verify Godot/OpenXR projects on a non-VR machine without breaking F5 launch."
description: |
  Develop, debug, and visually verify a Godot/OpenXR VR project on a workstation
  that has no XR runtime installed. Provides a "VR debug" mode that drives the
  XR rig from keyboard + mouse, captures per-eye and side-by-side screenshots,
  and renders the HMD view to a SubViewport for inspection. Leaves F5 launch
  untouched for the user.
---

# VR Development — Headless-Friendly Godot/OpenXR Workflow

This skill is for **building, testing, and visually verifying** a Godot VR
project (Godot 4.6 + OpenXR) on a workstation that has no VR runtime and
no headset. It must never prevent the user from pressing F5 and stepping
into the real headset on the machine that *does* have one.

## Core idea

A single boolean — `VR_DEBUG` — flips the project into a debug mode that:

- keeps the existing `XROrigin3D` / `XRCamera3D` / `XRController3D` nodes
  untouched
- drives the rig from keyboard + mouse (a "VR player")
- renders the HMD view to a SubViewport that can be screenshotted or
  recorded
- exposes a small debug HUD that prints controller poses, FPS, eye offset

When `VR_DEBUG` is off (the default for F5 and CI), the debug script is a
no-op. The user does not see a HUD, the rig is left for the real runtime,
and the existing `use_xr = true` path is reached on a real headset machine.

## When to use

| You want to ... | Use |
|------------------|-----|
| Take a screenshot of what each eye sees | `vr-capture.md` |
| Drive the camera around with WASD/mouse | `vr-debug-mode.md` |
| Inspect controller positions / handedness at runtime | `vr-architecture.md` |
| Verify the VR scene builds on a non-VR machine | `vr-debug-mode.md` (default debug path) |
| Hand the project to a user with a real headset | Do nothing extra — F5 just works |
| Build a quick VR-only feature (teleport, hand grab, UI) | `vr-architecture.md` for the rig contract, then implement |

Read subdocs only when you reach the relevant stage. Do not pre-load them.

| File | Purpose | Read when ... |
|------|---------|---------------|
| `vr-architecture.md` | XR node contract, **origin vs camera semantics**, runtime detection, pose queries | you are touching the rig or writing features that depend on HMD/controller state |
| `vr-debug-mode.md` | `VR_DEBUG` flag, `VRPlayer` reference impl, HUD | you need to drive the rig or add a debug overlay |
| `vr-capture.md` | Per-eye + side-by-side SubViewport capture, screenshot, video | you need visual proof of the VR scene |
| `vr-verification.md` | Pixel-diff budgets, two-frame capture delay, parent-vs-root gotchas | you have a screenshot but want to know if the rig actually moved |
| `vr-quirks.md` | Godot 4.6 + OpenXR gotchas | something looks wrong; check here first |
| `tools/vr_debug.sh` | CLI wrapper: detect runtime, set `VR_DEBUG`, run godot | every time you run the project in this skill |
| `tools/xvfb-run` | In-tree Xvfb wrapper (Nix-friendly) | your shell does not have `xvfb-run` |
| `examples/VRPlayer.gd` | Reference "VR player" implementation | copying into a real project |
| `examples/VRDebugCapture.gd` | SceneTree capture script | copying into `test/` for automated screenshots |
| `examples/VRDebugAutoload.gd` | Optional `VRDebug` autoload | the project does not have a debug flag yet |
| `test/VRMotionTest.gd` | Drive HMD through a sequence, write labelled side-by-side PNGs | verifying that head motion propagates to the SubViewports |
| `test/world_test.tscn` | Verification scene: world-fixed markers, sparse world | `VRMotionTest.gd` scene to load |
| `test/diff.gd` | Pixel-diff two PNGs | verifying a capture actually changed |

All paths above are relative to `${VR_DEV_SKILL_DIR}` (the directory this
`SKILL.md` lives in). When the skill is published into a runtime repo, that
placeholder resolves to the absolute install path of the skill in the
target repo.

## Project-shape assumptions

This skill assumes the consuming project is a Godot 4.6 project with
`[xr] openxr/enabled=true`. It does **not** require a C# project, but it
also does not break one — the reference scripts are GDScript so they work
regardless of whether the consumer has the `[dotnet]` block. A consumer
can write the C# equivalent of `VRPlayer.gd` and follow the same
architectural contract from `vr-architecture.md`.

The capture script (`examples/VRDebugCapture.gd`) takes the scene path
via `--vr-scene` and the output directory via `--vr-out`, so it works
against any `.tscn` in the consumer's project, not a hard-coded one.

## The non-negotiable rule

**Default-off.** Every debug feature in this skill must default to off and
must only activate when an explicit opt-in is present. The opt-in surface is:

- CLI: `--vr-debug` (passed through `OS.get_cmdline_user_args()`)
- Env: `VR_DEBUG=1`
- Project setting: `vr_test/debug_enabled=true` (set only on a debug branch)

If the user presses F5 with a headset attached, none of those should be set,
and the project must behave exactly as it did before this skill was added.
Never make the debug path the implicit path.

## Workflow

```text
Read vr-debug-mode.md once.
    |
    +- Want to drive the rig? Copy examples/VRPlayer.gd into your scene's
    |  XROrigin3D and toggle VR_DEBUG.
    |
    +- Want a screenshot? Read vr-capture.md, copy examples/VRDebugCapture.gd
    |  to test/, then run tools/vr_debug.sh capture.
    |
    +- Hit something weird? Read vr-quirks.md.
```

## Capture invocation

```bash
bash ${VR_DEV_SKILL_DIR}/tools/vr_debug.sh capture
```

This:

1. Detects whether the workstation has a runtime. If yes, uses it. If no,
   sets `VR_DEBUG=1` and adds `--xr-mode off` so Godot falls back to a
   desktop window with the rig in scene.
2. Wraps the godot call in `xvfb-run` when no display is present.
3. Runs the project's main scene with the capture SceneTree script.
4. Writes PNG(s) to `screenshots/vr-debug/{left,right,sidebyside}.png` and
   the raw frame sequence to `screenshots/vr-debug/frames/`.

The default scene is `res://main.tscn`. Override with
`VR_SCENE=res://other.tscn` or `--vr-scene=res://other.tscn`.

## Verification standard

A VR change is "done" only when:

- `VR_DEBUG=1` build runs end-to-end on this machine without an XR runtime
- At least one side-by-side screenshot of the running scene exists
- The real-rig path is unchanged: `VR_DEBUG` unset, F5 launches as before
  (or would, on a machine with a runtime)
- No debug HUD is visible in the released scene (the autoload must check
  the flag in `_ready` and either add or skip the HUD node)

## Anti-patterns

- Do not branch on `OS.has_feature("editor")` to enable the debug HUD.
  Editor and CI are different environments; use `VR_DEBUG` explicitly.
- Do not write to `main.gd` to inject the debug player. Add a sibling
  script under the `XROrigin3D`. `main.gd` owns OpenXR init only.
- Do not put screenshot paths in code; pass them via CLI args
  (`--vr-capture-out=...`).
- Do not call `XRServer.find_interface("OpenXR")` and assume the result
  is non-null in the debug path — see `vr-quirks.md`.
