extends SceneTree
## VRDebugCapture — stereo screenshot / video capture for VR scenes.
##
## Run with:
##   godot --headless --path . --script VRDebugCapture.gd -- \
##           --vr-screenshot --vr-out screenshots/vr-debug --vr-scene res://main.tscn
##   godot --path . --write-movie out/frame.png --fixed-fps 30 --quit-after 300 \
##         --script VRDebugCapture.gd -- --vr-video --vr-out screenshots/vr-debug
##
## Output:
##   <out>/left.png
##   <out>/right.png
##   <out>/sidebyside.png
##   <out>/frames/frame000XXX.png    (--vr-video)
##
## When --vr-screenshot is given, the script renders one frame per eye and
## quits. When --vr-video is given, the host shell captures the side-by-side
## preview from the main viewport via --write-movie; this script also writes
## per-eye PNGs to <out>/left.png and <out>/right.png at the end.

const IPD_M: float = 0.064
const FOV_FALLBACK_DEG: float = 70.0
const EYE_W: int = 960
const EYE_H: int = 540

var _out_dir: String = "screenshots/vr-debug"
var _scene_path: String = "res://main.tscn"
var _mode: String = ""  # "screenshot" or "video"
var _ipd: float = IPD_M
var _eye_views: Array[SubViewport] = []
var _eye_cams: Array[Camera3D] = []
var _preview_root: CanvasLayer
var _preview_left: TextureRect
var _preview_right: TextureRect
var _frames_written: int = 0


func _init() -> void:
	_parse_args()
	root.set_meta("_vr_capture", self)
	_load_scene()


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var a: String = args[i]
		match a:
			"--vr-screenshot": _mode = "screenshot"
			"--vr-video":      _mode = "video"
			"--vr-out":
				if i + 1 < args.size():
					_out_dir = args[i + 1]
					i += 1
			"--vr-scene":
				if i + 1 < args.size():
					_scene_path = args[i + 1]
					i += 1
			"--vr-ipd":
				if i + 1 < args.size():
					_ipd = float(args[i + 1])
					i += 1
			_: pass
		i += 1
	if _mode == "":
		_mode = "screenshot"  # default


func _load_scene() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	var packed: PackedScene = load(_scene_path)
	if packed == null:
		push_error("[VRDebugCapture] failed to load scene: %s" % _scene_path)
		quit(1)
		return
	var inst: Node = packed.instantiate()
	root.add_child(inst)
	# Let the scene settle for a frame.
	process_frame.connect(_on_first_frame, CONNECT_ONE_SHOT)


func _on_first_frame() -> void:
	# Read the HMD pose from the loaded scene.
	var cam: Camera3D = _find_hmd_camera()
	if cam == null:
		push_error("[VRDebugCapture] no XRCamera3D / Camera3D found in scene; aborting")
		quit(1)
		return
	_build_eye_viewports(cam)
	_build_preview()
	process_frame.connect(_on_frame)


func _find_hmd_camera() -> Camera3D:
	# Prefer an XRCamera3D. Fall back to the first Camera3D in the scene.
	for n in root.find_children("*", "XRCamera3D", true, false):
		return n as Camera3D
	for n in root.find_children("*", "Camera3D", true, false):
		if n is Camera3D:
			return n
	return null


func _build_eye_viewports(cam: Camera3D) -> void:
	# XRCamera3D has no usable fov without a runtime; fall back to a sane default.
	var h_fov_deg: float = cam.fov if cam.fov > 0.0 else FOV_FALLBACK_DEG
	var v_fov_rad: float = deg_to_rad(h_fov_deg)
	var aspect: float = float(EYE_W) / float(EYE_H)
	var h_fov_rad: float = 2.0 * atan(tan(v_fov_rad * 0.5) * aspect)
	var near: float = cam.near if cam.near > 0.0 else 0.05
	var far: float = cam.far if cam.far > 0.0 else 4000.0
	var basis: Basis = cam.global_transform.basis
	var origin: Vector3 = cam.global_transform.origin
	# World-space eye positions: offset along cam.x by ±IPD/2.
	var left_pos: Vector3 = origin + basis.x * (-_ipd * 0.5)
	var right_pos: Vector3 = origin + basis.x * (_ipd * 0.5)
	# Share the scene's world with both SubViewports so they see the scene nodes.
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
		ec.global_transform = Transform3D(basis, left_pos if side == "left" else right_pos)
		vp.add_child(ec)
		_eye_views.append(vp)
		_eye_cams.append(ec)
	# The main cam stays current in the root viewport; the SubViewport cameras
	# are isolated by being parents of SubViewports.


func _build_preview() -> void:
	_preview_root = CanvasLayer.new()
	_preview_root.layer = 1
	root.add_child(_preview_root)
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.05, 1)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	_preview_root.add_child(bg)
	var half_w: float = float(EYE_W)
	_preview_left = _add_preview(_eye_views[0], 0.0, half_w)
	_preview_right = _add_preview(_eye_views[1], half_w, half_w)


func _add_preview(vp: SubViewport, x: float, w: float) -> TextureRect:
	var t := TextureRect.new()
	t.position = Vector2(x, 0)
	t.size = Vector2(w, float(EYE_H))
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.texture = vp.get_texture()
	_preview_root.add_child(t)
	return t


func _on_frame() -> void:
	# Update eye transforms to follow the HMD camera in the loaded scene.
	var cam: Camera3D = _find_hmd_camera_in_loaded_scene()
	if cam != null:
		var basis: Basis = cam.global_transform.basis
		var origin: Vector3 = cam.global_transform.origin
		_eye_cams[0].global_transform = Transform3D(basis, origin + basis.x * (-_ipd * 0.5))
		_eye_cams[1].global_transform = Transform3D(basis, origin + basis.x * (_ipd * 0.5))
	_frames_written += 1

	if _mode == "screenshot" and _frames_written >= 2:
		_save_outputs()
		quit(0)


func _find_hmd_camera_in_loaded_scene() -> Camera3D:
	for n in root.find_children("*", "XRCamera3D", true, false):
		return n as Camera3D
	for n in root.find_children("*", "Camera3D", true, false):
		if n is Camera3D and not n in _eye_cams:
			return n
	return null


func _save_outputs() -> void:
	var out_abs: String = ProjectSettings.globalize_path(_out_dir)
	DirAccess.make_dir_recursive_absolute(out_abs)
	var left_img: Image = _eye_views[0].get_texture().get_image()
	var right_img: Image = _eye_views[1].get_texture().get_image()
	left_img.save_png(out_abs.path_join("left.png"))
	right_img.save_png(out_abs.path_join("right.png"))
	# Side-by-side. Match the source format exactly so blit_rect doesn't fail.
	var fmt: int = left_img.get_format()
	var sbs := Image.create(EYE_W * 2, EYE_H, false, fmt)
	sbs.blit_rect(left_img, Rect2i(0, 0, EYE_W, EYE_H), Vector2i(0, 0))
	sbs.blit_rect(right_img, Rect2i(0, 0, EYE_W, EYE_H), Vector2i(EYE_W, 0))
	sbs.save_png(out_abs.path_join("sidebyside.png"))
	print("[VRDebugCapture] wrote %s/{left,right,sidebyside}.png" % out_abs)
