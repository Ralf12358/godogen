extends SceneTree
## VRMotionTest — drives the XRCamera3D through a fixed sequence of
## poses and writes one labelled side-by-side PNG per pose. Used to
## verify that head motion (yaw + walk) propagates from the HMD node
## to the SubViewport eye cameras correctly.
##
## Run with:
##   godot --path . --rendering-method mobile --xr-mode off \
##         --script .agents/skills/vr-dev/test/VRMotionTest.gd -- \
##         --vr-out .agents/skills/vr-dev/test/shots \
##         --vr-scene .agents/skills/vr-dev/test/world_test.tscn
##
## The sequence is (relative to the previous pose):
##   0. home       — HMD at (0, 1.6, 0), yaw 0
##   1. +1m forward
##   2. +1m forward (so 2m total)
##   3. yaw -30 deg right
##   4. yaw -30 deg right (so 60 deg total)
##   5. yaw -30 deg right (so 90 deg total)
##
## The script writes shots/{step}_{label}.png with the side-by-side
## stereo pair so we can verify the rig moved and rotated as expected.
## Use diff.gd to confirm successive shots actually differ (5-30% per
## step is the working range for a 1m walk; 30-50% for a 60° yaw).

const IPD_M: float = 0.064
const EYE_W: int = 960
const EYE_H: int = 540
const FOV_FALLBACK_DEG: float = 75.0

var _out_dir: String = ".agents/skills/vr-dev/test/shots"
var _scene_path: String = "res://.agents/skills/vr-dev/test/world_test.tscn"
var _step: int = 0
var _frame_in_step: int = 0
var _frames_per_step: int = 30
var _origin: XROrigin3D
var _hmd: XRCamera3D
var _eye_views: Array[SubViewport] = []
var _eye_cams: Array[Camera3D] = []
var _log_lines: Array[String] = []
var _pending_capture: int = -1
var _pending_capture_frames: int = 0


func _init() -> void:
	_parse_args()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	_log("out_dir=%s scene=%s" % [_out_dir, _scene_path])
	var packed: PackedScene = load(_scene_path)
	assert(packed != null, "could not load %s" % _scene_path)
	var inst: Node = packed.instantiate()
	root.add_child(inst)
	# Give the scene a frame to settle, then find the rig.
	process_frame.connect(_on_first_frame, CONNECT_ONE_SHOT)


func _on_first_frame() -> void:
	# Force the main XROrigin3D to be a known starting pose. We do NOT touch
	# the XRCamera3D in this scene because the capture script will follow it.
	for n in root.find_children("*", "XROrigin3D", true, false):
		_origin = n as XROrigin3D
		break
	assert(_origin != null, "no XROrigin3D in scene")
	for n in root.find_children("*", "XRCamera3D", true, false):
		_hmd = n as XRCamera3D
		break
	assert(_hmd != null, "no XRCamera3D in scene")
	_log("rig resolved: origin=%s hmd=%s" % [_origin.name, _hmd.name])
	_build_eye_viewports(_hmd)
	# Step 0 = home. Reset to a known baseline.
	_origin.transform = Transform3D(Basis(), Vector3.ZERO)
	# The XRCamera3D is parented to the origin, so origin transform = play space.
	# Make sure the XRCamera is at head height (the scene already sets it).
	process_frame.connect(_on_frame)


func _build_eye_viewports(cam: Camera3D) -> void:
	var h_fov_deg: float = cam.fov if cam.fov > 0.0 else FOV_FALLBACK_DEG
	var v_fov_rad: float = deg_to_rad(h_fov_deg)
	var aspect: float = float(EYE_W) / float(EYE_H)
	var h_fov_rad: float = 2.0 * atan(tan(v_fov_rad * 0.5) * aspect)
	var near: float = cam.near if cam.near > 0.0 else 0.05
	var far: float = cam.far if cam.far > 0.0 else 4000.0
	var scene_world: World3D = cam.get_world_3d() if cam.get_world_3d() != null else root.get_world_3d()
	_eye_views = []
	_eye_cams = []
	for side in ["left", "right"]:
		var vp := SubViewport.new()
		vp.size = Vector2i(EYE_W, EYE_H)
		vp.transparent_bg = false
		vp.own_world_3d = false
		vp.world_3d = scene_world
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vp.handle_input_locally = false
		root.add_child(vp)
		var ec := Camera3D.new()
		ec.fov = rad_to_deg(h_fov_rad)
		ec.near = near
		ec.far = far
		ec.current = true
		vp.add_child(ec)
		_eye_views.append(vp)
		_eye_cams.append(ec)


func _on_frame() -> void:
	_frame_in_step += 1
	# If we have a pending capture from a previous step, do it now.
	# We wait TWO frames after the camera transform changes before reading
	# the SubViewport texture: one for the SceneTree to register the new
	# transform, one for the GPU to actually render it.
	if _pending_capture >= 0:
		_pending_capture_frames += 1
		if _pending_capture_frames >= 2:
			_capture_for_step(_pending_capture)
			_pending_capture = -1
			_pending_capture_frames = 0
			# If we just captured the final step, quit now.
			if _step >= _SEQUENCE.size():
				print("\n".join(_log_lines))
				quit(0)
		return
	if _frame_in_step < _frames_per_step:
		return
	_frame_in_step = 0
	# Apply the next step's transform, then wait for the next frame so the
	# SubViewports actually render the new pose before we read the texture.
	_apply_step(_step)
	_log("step %d hmd_local=(%.3f, %.3f, %.3f) yaw=%.1f deg" % [
		_step, _hmd.position.x, _hmd.position.y,
		_hmd.position.z, rad_to_deg(_yaw_of(_hmd.transform))])
	# Move eye cameras to the new HMD pose now, so the upcoming render uses them.
	var hmd_basis: Basis = _hmd.global_transform.basis
	var hmd_origin: Vector3 = _hmd.global_transform.origin
	_eye_cams[0].global_transform = Transform3D(hmd_basis, hmd_origin + hmd_basis.x * (-IPD_M * 0.5))
	_eye_cams[1].global_transform = Transform3D(hmd_basis, hmd_origin + hmd_basis.x * (IPD_M * 0.5))
	# Defer the actual capture by two frames.
	_pending_capture = _step
	_pending_capture_frames = 0
	_step += 1


const _SEQUENCE: Array = [
	{"label": "0_home",       "delta": Vector3(0, 0, 0),   "yaw_deg": 0.0},
	{"label": "1_fwd_1m",     "delta": Vector3(0, 0, -1),  "yaw_deg": 0.0},
	{"label": "2_fwd_2m",     "delta": Vector3(0, 0, -1),  "yaw_deg": 0.0},
	{"label": "3_yaw_30",     "delta": Vector3(0, 0, 0),   "yaw_deg": 30.0},
	{"label": "4_yaw_60",     "delta": Vector3(0, 0, 0),   "yaw_deg": 30.0},
	{"label": "5_yaw_90",     "delta": Vector3(0, 0, 0),   "yaw_deg": 30.0},
]


func _apply_step(idx: int) -> void:
	var s: Dictionary = _SEQUENCE[idx]
	# Real VR semantics: the XROrigin3D is the room-anchored play space and
	# stays still while the user moves their head. The XRCamera3D reflects
	# the head pose INSIDE the play space. This test exercises that path.
	#
	# The XRCamera3D is parented to the XROrigin3D, with its local transform
	# at (0, 1.6, 0). We move the XRCamera3D in the play-space's local frame.
	var delta: Vector3 = s["delta"]
	# "Forward" in play space is -Z, "right" is +X.
	_hmd.position += delta
	# Yaw: rotate the HMD in place. Positive yaw_deg = turn right.
	var cur_yaw: float = _yaw_of(_hmd.transform)
	var new_yaw: float = cur_yaw - deg_to_rad(s["yaw_deg"])
	_hmd.transform.basis = Basis(Vector3.UP, new_yaw)


func _yaw_of(t: Transform3D) -> float:
	# Extract the rotation around Y from a basis, assuming the rig is yaw-only.
	# For Basis(Vector3.UP, theta) in Godot's right-handed Y-up:
	#   basis.z = (sin theta, 0, cos theta)
	# so theta = atan2(basis.z.x, basis.z.z).
	return atan2(t.basis.z.x, t.basis.z.z)


func _capture_for_step(idx: int) -> void:
	var label: String = _SEQUENCE[idx]["label"]
	var out_abs: String = ProjectSettings.globalize_path(_out_dir)
	DirAccess.make_dir_recursive_absolute(out_abs)
	# Save a side-by-side PNG from the textures we just rendered.
	var left_img: Image = _eye_views[0].get_texture().get_image()
	var right_img: Image = _eye_views[1].get_texture().get_image()
	var sbs := Image.create(EYE_W * 2, EYE_H, false, left_img.get_format())
	sbs.blit_rect(left_img, Rect2i(0, 0, EYE_W, EYE_H), Vector2i(0, 0))
	sbs.blit_rect(right_img, Rect2i(0, 0, EYE_W, EYE_H), Vector2i(EYE_W, 0))
	var path: String = out_abs.path_join("step_%s.png" % label)
	sbs.save_png(path)
	# Measure the apparent size of the closest purple marker (Marker1m at z=-1).
	# A 0.4m cube seen from a known distance should have a known on-screen size
	# (perspective: h_pixels = 0.4 * EYE_H / (2 * d * tan(fov_v / 2))).
	_log("  %s: eye_cam0.global=(%.3f,%.3f,%.3f) hmd.global=(%.3f,%.3f,%.3f)" % [
		label,
		_eye_cams[0].global_transform.origin.x, _eye_cams[0].global_transform.origin.y, _eye_cams[0].global_transform.origin.z,
		_hmd.global_transform.origin.x, _hmd.global_transform.origin.y, _hmd.global_transform.origin.z])
	_log("wrote %s" % path)


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var a: String = args[i]
		match a:
			"--vr-out":
				if i + 1 < args.size():
					_out_dir = args[i + 1]
					i += 1
			"--vr-scene":
				if i + 1 < args.size():
					_scene_path = args[i + 1]
					i += 1
			_: pass
		i += 1


func _log(msg: String) -> void:
	_log_lines.append(msg)
