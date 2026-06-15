# VR Verification — Proving the Rig Works

A VR change is only "done" when the test artefacts **prove** it. Visual
diff alone ("the screenshot looks different") is not enough — a render
that is one frame stale or a parented-vs-root mistake can fool the eye.

This document is the standard recipe for verifying rig motion,
controller state, and stereo separation on a non-VR machine.

## Pick the right scene for what you are verifying

The single biggest source of "is this thing moving?" confusion is
choosing the wrong scene. The two transforms — `XROrigin3D` and
`XRCamera3D` — drive different parts of the rendered image, and a
scene full of play-space-attached objects will not show walking even
when walking works.

| What you want to verify | Scene layout | Why |
|--------------------------|--------------|-----|
| Head tracking (look around, lean, crouch) | Any | Head moves `XRCamera3D`; you can see it in any layout |
| Walking physically (play-space translation) | World-fixed objects (scene root) | Only world-fixed objects visibly move across the frame when the player walks |
| Smooth-locomotion stick | World-fixed objects | Same — only the world moves relative to the player |
| Smooth-turn stick | World-fixed objects | Rotating the play space should swing the world around the player |
| Teleport | World-fixed objects | The play space jumps; world-fixed objects confirm the new position |
| Hand interaction (grab, ray UI) | Either | Hands are tracked in the play space, not the world |
| Body-locked UI follows player | Play-space-attached UI | The UI must travel with the player, only visible when the parentage is right |

**The cheap mistake:** running a walking test against a scene where
all the scenery is parented under `XROrigin3D`. Walking will look
broken because the scenery travels with the player. The rig is fine —
the scene is wrong for the test. Use a sparse world-fixed scene for
rig-motion tests, then check the authored scene for its real
parentage layout.

The verification scene this skill ships — `test/world_test.tscn` —
uses world-fixed markers, which is the right layout for the recipes
in this file. The consumer's own main scene may use a different
parentage (e.g. body-locked UI) and that is fine *for its* purposes,
but not for the rig-motion tests below.

## Recipe: walk N meters, verify

1. Place a single reference object of known size at a known world
   position in a test scene (e.g. 0.4m cube at world (0, 1.4, -3)).
2. Set the HMD to a known starting pose.
3. Capture side-by-side PNG.
4. Move the HMD 1m forward (i.e. subtract 1m from the HMD's local Z).
5. Wait **two** process frames before reading the SubViewport texture.
6. Capture again.
7. Diff the two PNGs. A working rig produces a 5-30% pixel diff at
   1m, growing as you walk further. 0% means the camera didn't move
   or the SubViewport didn't re-render.

The 1m test is sensitive enough to catch a stuck HMD or a
one-frame-lag capture, but small enough to be fast.

## Recipe: turn N degrees, verify

Same idea, but instead of translating the HMD, rotate it. A 30° yaw
produces a ~30% pixel diff in a typical scene. 0% means the yaw never
made it to the camera or to the SubViewport.

## Why two frame delays

When you set a camera's `global_transform` in `_process`, the
SceneTree accepts the change immediately. But:

- Frame N: SceneTree processes `_process`. The new transform is
  committed. The SceneTree's render server queues a new render of
  every SubViewport that shares the world.
- Frame N+1: the GPU renders. The new transform is now in effect.
- Frame N+2: you can read the SubViewport texture and get the new
  image.

Reading in frame N+1 returns the **previous** render (N-1's image).
For a 30 Hz capture that's 33 ms of stale data — the HMD position
will be 33 ms behind. For a 90 Hz HMD it's 11 ms. Either way, the
image shows the HMD where it was, not where it is.

This is the same `--write-movie` frame-0 quirk documented in the
`godogen` skill (frame 0 renders before `_process` runs).

A two-frame delay is the safe minimum. If you see the test scene's
"step 0" look like a black frame or "step 1" look identical to
"step 0", the delay is too short. The `test/VRMotionTest.gd` script
in this skill uses two frames and `_pending_capture_frames`.

## Why Godot might re-import your PNGs

If you write PNGs to a path under `res://` (i.e. inside the project),
Godot's filesystem rescan will see them, treat them as new assets, and
generate `.png.import` files alongside. The import is fast, but:

- It slows down subsequent runs (Godot scans + imports + rescan).
- It pollutes the project with `.png.import` files that should be
  in `.gitignore`.
- A rescan can pause the SceneTree briefly, which can shift your
  frame timing.

Always place capture outputs in:

- `screenshots/` (with `screenshots/.gdignore`)
- `test/shots/` (with `test/.gdignore`)
- or any other path that has a `.gdignore` next to it

If you forget the `.gdignore`, the PNGs will import and the rescan
will happen during the next run.

## Pixel-diff budget

A `test/diff.gd` script (provided in this skill) compares two PNGs
and reports the percentage of differing pixels. Use these rough
budgets to decide if a change is real:

| Change | Expected diff (RGB side-by-side, 1920x540) |
|--------|--------------------------------------------|
| 1m forward (with world-fixed reference) | 5-15% |
| 2m forward (with world-fixed reference, sparse markers) | 1-3% (see note) |
| 30° yaw | 20-40% |
| 60° yaw | 35-55% |
| 0% diff | Camera didn't move OR the SubViewport didn't re-render |
| 100% diff | Scene error or different scenes compared |

A 0% diff is the most important failure case. If you see it, check:

1. Is the camera transform actually being written? Print
   `_eye_cams[0].global_transform.origin` and confirm it changes.
2. Is the SubViewport's `render_target_update_mode = UPDATE_ALWAYS`?
3. Are you waiting at least two frames after the transform change
   before reading the texture?
4. Does the SubViewport's `world_3d` match the scene's world?
   (Otherwise the camera renders an empty scenario.)

**The "small diff" trap.** If your test scene has markers every 1m
and you walk 2m, the rendered view at step 2 (camera 2m forward) sees
the same composition as the home view (camera at origin, a marker
1m ahead). The diff is small (1-3%), not the 10-30% you might expect
from 2m of walking. This is **not** a bug — the test scene just
doesn't have a reference object that grows with the walk distance.
To get a monotonic diff-vs-distance, use one reference object placed
far away (e.g. a cube at z=-10) and walk 0..5m. The cube's apparent
size grows monotonically and the diff grows with it.
