# VR Capture — Screenshots and Video of the Stereo View

How to produce a visual proof of the VR scene on a machine without a
runtime. Output: per-eye PNGs + a side-by-side stereo image + an
optional video clip.

## Output layout

```text
screenshots/vr-debug/
├── left.png             # what the left eye would see
├── right.png            # what the right eye would see
├── sidebyside.png       # left/right stitched, viewer-friendly
├── frames/
│   └── frame000001.png  # raw movie frames (when --video)
└── video.mp4            # animated side-by-side (when --video)
```

The output directory is created by the script — it does not need to
exist. `screenshots/.gdignore` is required so Godot does not import
the PNGs as textures; `tools/vr_debug.sh` creates it.

## How it works

`examples/VRDebugCapture.gd` is a `SceneTree` script (extends
`SceneTree`, not `Node`). It:

1. Loads `main.tscn` (or whatever the user passes via `--vr-scene`)
2. Sets up two `SubViewport`s sized to the configured eye resolution,
   each with a `Camera3D` placed at
   `XRCamera3D.global_transform` with `±IPD/2` X-offset and a
   Y-fov that matches the HMD's reported fov
3. In `_process`, blits each SubViewport to a `TextureRect` in a
   root-level `CanvasLayer` so the main window sees them side by side
4. On `--vr-screenshot`, calls `Image.save_png()` once per eye and once
   for the side-by-side
5. On `--vr-video`, uses `--write-movie` (Godot writes a PNG sequence)
   and the shell script then runs `ffmpeg` to encode `video.mp4`

When the XR interface is not initialised (the normal debug case), the
script queries `XRCamera3D`'s FOV from the active `Camera3D` and uses
that instead. The pose and FOV are kept consistent with what the real
HMD would have used.

## Running the screenshot path

```bash
bash ${VR_DEV_SKILL_DIR}/tools/vr_debug.sh capture
```

Under the hood, the script:

```bash
# 1. detect display / GPU
# 2. set VR_DEBUG=1, --xr-mode off
# 3. invoke godot with the capture script
godot --path . --display-driver headless \
    --script ${VR_DEV_SKILL_DIR}/examples/VRDebugCapture.gd \
    -- --vr-screenshot --vr-out screenshots/vr-debug
```

The `--` separator forwards everything after it to
`OS.get_cmdline_user_args()`. The capture script reads them.

## Running the video path

```bash
bash ${VR_DEV_SKILL_DIR}/tools/vr_debug.sh video
```

Same as above, but with `--vr-video` and a higher frame count, then
the shell script pipes the frames through `ffmpeg` to `video.mp4`.

## Headless vs windowed

- `headless` display driver works for screenshots (no window needed)
  but the per-eye SubViewports render to textures directly, so the
  output PNGs are correct even with no window.
- For the video path you still need a window because the main viewport
  is where the movie is recorded from. `tools/vr_debug.sh video`
  wraps godot in `xvfb-run` when no display is present.

## IPD and FOV

The capture script reads both at runtime:

- IPD: a constant at the top of the script (default `0.064` m), which
  the user can override with `--vr-ipd=0.065`. Do not be tempted to
  read it from `XRServer.primary_interface.get_eye_view(0, ...).size`
  — that returns the eye's *render target size*, not the eye's *offset*.
- FOV: read `camera.fov` (vertical degrees) and derive horizontal from
  the SubViewport's aspect ratio: `h_fov = 2 * atan(tan(v_fov/2) * aspect)`.
  If the camera's `fov` is zero (the `XRCamera3D` default without a
  runtime), a fallback constant is used.

Hard-coded eye offsets / FOVs in the capture script are a smell —
everything should come from the scene or the CLI.

## What to verify in the captures

- Both eyes show the same scene from a 64 mm offset — easy to
  confirm by checking the left image is shifted right relative to the
  right image
- The side-by-side image is two equal-width halves, not two stacked
  halves (Google Cardboard is SBS, not over-under)
- FPS in the HUD is the same as the FPS shown in the bottom-right of
  Godot's editor when you run with `--xr-mode off` — proves the rig
  is not being held back by something VR-specific
- For the video, frame 0 is junk (the camera is at (0, 0, 0) before
  `_Process` runs) — the well-formed frames start at frame 1. This
  matches the existing `godogen` skill's `--write-movie` quirk
  (frame 0 renders before `_Process`).

## Combining with `godogen` capture

The `godogen` skill's capture wrapper and `--write-movie` flow can be
reused unchanged — they only care about the rendering backend, not
about XR. The only thing `vr-dev` adds is the per-eye SubViewport setup
and the eye offset, which is done in user code in the capture script.
