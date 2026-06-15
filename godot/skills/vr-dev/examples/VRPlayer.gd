extends Node3D
## VRPlayer — keyboard/mouse driver for the XR rig, used in VR_DEBUG mode.
##
## Attach this to an XROrigin3D that has an XRCamera3D and two
## XRController3D children named "LeftHand" and "RightHand"
## (or override the @export node paths).
##
## The script is a no-op when VRDebug.enabled is false, so on a real
## headset machine the runtime drives the rig unchanged.

class_name VRPlayer

const IPD_M: float = 0.064
const MIN_HEAD_Y: float = 0.4
const MAX_HEAD_Y: float = 2.5
const WALK_SPEED: float = 2.0
const SPRINT_SPEED: float = 5.0
const MOUSE_SENSITIVITY: float = 0.0022

@export_node_path("XRCamera3D") var hmd_path: NodePath = ^"XRCamera3D"
@export_node_path("XRController3D") var left_hand_path: NodePath = ^"LeftHand"
@export_node_path("XRController3D") var right_hand_path: NodePath = ^"RightHand"

var hmd: XRCamera3D
var left_hand: XRController3D
var right_hand: XRController3D

var _yaw: float = 0.0
var _pitch: float = 0.0
var _head_y: float = 1.6

var _wasd := {"w": false, "a": false, "s": false, "d": false}
var _vertical := {"up": false, "down": false}
var _hand_pose := {
	"left_pos": Vector3.ZERO, "left_rot": Vector3.ZERO,
	"right_pos": Vector3.ZERO, "right_rot": Vector3.ZERO,
}
var _buttons := {"left_trigger": false, "left_grip": false, "right_trigger": false, "right_grip": false}

var _active: bool = false
var _hud: CanvasLayer


func _ready() -> void:
	# Resolve nodes now; if the rig is set up later the user can re-enable.
	hmd = get_node_or_null(hmd_path) as XRCamera3D
	left_hand = get_node_or_null(left_hand_path) as XRController3D
	right_hand = get_node_or_null(right_hand_path) as XRController3D

	# Look up the optional autoload by name. If the user has not registered
	# VRDebug, this returns null and we stay inactive.
	var debug := Engine.get_singleton("VRDebug") if Engine.has_singleton("VRDebug") else null
	if debug == null or not debug.enabled:
		set_process(false)
		set_process_unhandled_input(false)
		return

	_active = true
	set_process(true)
	set_process_unhandled_input(true)
	_install_hud()
	_print_bindings()
	debug.connect("enabled_changed", _on_debug_toggled)


func _print_bindings() -> void:
	print("[VRPlayer] controls:")
	print("  WASD          move play space on XZ")
	print("  Shift / Ctrl  up / down")
	print("  RMB drag      rotate head (yaw/pitch)")
	print("  IJKL          left  hand translate")
	print("  Arrows        right hand translate")
	print("  U / O         left  hand rotate yaw/pitch")
	print("  , / .         right hand rotate yaw/pitch")
	print("  Space / Z     right trigger / grip")
	print("  Enter / X     left  trigger / grip")
	print("  F1 / F2 / F3  debug toggle / hud / reset play space")


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event as InputEventKey)
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		var m: InputEventMouseMotion = event
		_yaw -= m.relative.x * MOUSE_SENSITIVITY
		_pitch -= m.relative.y * MOUSE_SENSITIVITY
		_pitch = clamp(_pitch, -PI * 0.49, PI * 0.49)


func _handle_key(k: InputEventKey) -> void:
	match k.keycode:
		KEY_W: _wasd["w"] = true
		KEY_A: _wasd["a"] = true
		KEY_S: _wasd["s"] = true
		KEY_D: _wasd["d"] = true
		KEY_SHIFT: _vertical["up"] = true
		KEY_CTRL: _vertical["down"] = true
		KEY_SPACE: _buttons["right_trigger"] = true
		KEY_Z: _buttons["right_grip"] = true
		KEY_ENTER: _buttons["left_trigger"] = true
		KEY_X: _buttons["left_grip"] = true
		KEY_I: _hand_pose["left_pos"].z -= 0.05
		KEY_K: _hand_pose["left_pos"].z += 0.05
		KEY_J: _hand_pose["left_pos"].x -= 0.05
		KEY_L: _hand_pose["left_pos"].x += 0.05
		KEY_U: _hand_pose["left_pos"].y += 0.05
		KEY_O: _hand_pose["left_pos"].y -= 0.05
		KEY_UP: _hand_pose["right_pos"].z -= 0.05
		KEY_DOWN: _hand_pose["right_pos"].z += 0.05
		KEY_LEFT: _hand_pose["right_pos"].x -= 0.05
		KEY_RIGHT: _hand_pose["right_pos"].x += 0.05
		KEY_COMMA: _hand_pose["right_pos"].y -= 0.05
		KEY_PERIOD: _hand_pose["right_pos"].y += 0.05
		KEY_F1: _toggle_debug()
		KEY_F2: _toggle_hud()
		KEY_F3: _reset_play_space()
		KEY_ESCAPE: get_tree().quit()
	if not k.pressed and k.keycode in [KEY_W, KEY_A, KEY_S, KEY_D]:
		_wasd[k.keycode_to_string() if false else _wasd_key(k.keycode)] = false
	if not k.pressed and k.keycode in [KEY_SHIFT, KEY_CTRL]:
		_vertical["up" if k.keycode == KEY_SHIFT else "down"] = false


func _wasd_key(kc: int) -> String:
	match kc:
		KEY_W: return "w"
		KEY_A: return "a"
		KEY_S: return "s"
		KEY_D: return "d"
	return ""


func _process(_delta: float) -> void:
	if not _active:
		return
	_drive_origin(_delta)
	_drive_head()
	_drive_hands()
	_update_hud()


func _drive_origin(delta: float) -> void:
	var speed := WALK_SPEED
	if Input.is_key_pressed(KEY_SHIFT):
		speed = SPRINT_SPEED
	var dir := Vector3.ZERO
	if _wasd["w"]: dir.z -= 1
	if _wasd["s"]: dir.z += 1
	if _wasd["a"]: dir.x -= 1
	if _wasd["d"]: dir.x += 1
	if dir.length_squared() > 0.0:
		dir = dir.normalized() * speed * delta
		# Rotate by yaw so 'W' is always forward.
		dir = dir.rotated(Vector3.UP, _yaw)
		global_transform.origin += dir
	if _vertical["up"]:
		global_transform.origin.y += speed * delta
	if _vertical["down"]:
		global_transform.origin.y -= speed * delta


func _drive_head() -> void:
	if hmd == null:
		return
	var b := Basis()
	b = b.rotated(Vector3.UP, _yaw)
	b = b.rotated(b.x, _pitch)
	hmd.transform.basis = b
	hmd.transform.origin = Vector3(0, _head_y - global_transform.origin.y, 0)


func _drive_hands() -> void:
	if left_hand:
		left_hand.transform = _hand_xform(_hand_pose["left_pos"], _hand_pose["left_rot"])
	if right_hand:
		right_hand.transform = _hand_xform(_hand_pose["right_pos"], _hand_pose["right_rot"])


func _hand_xform(pos: Vector3, rot: Vector3) -> Transform3D:
	var b := Basis()
	b = b.rotated(Vector3.UP, rot.y)
	b = b.rotated(b.x, rot.x)
	return Transform3D(b, pos)


func _reset_play_space() -> void:
	global_transform.origin = Vector3.ZERO
	_yaw = 0
	_pitch = 0


func _toggle_debug() -> void:
	var debug := Engine.get_singleton("VRDebug") if Engine.has_singleton("VRDebug") else null
	if debug:
		debug.toggle()


func _on_debug_toggled(enabled: bool) -> void:
	if enabled:
		_active = true
		set_process(true)
		set_process_unhandled_input(true)
		_install_hud()
	else:
		_active = false
		set_process(false)
		set_process_unhandled_input(false)
		if _hud:
			_hud.queue_free()
			_hud = null


# --- HUD ---------------------------------------------------------------------

func _install_hud() -> void:
	if _hud:
		return
	_hud = CanvasLayer.new()
	_hud.layer = 100
	var label := Label.new()
	label.name = "Stats"
	label.position = Vector2(16, 16)
	label.add_theme_color_override("font_color", Color.WHITE)
	_hud.add_child(label)
	add_child(_hud)


func _toggle_hud() -> void:
	if _hud:
		_hud.visible = not _hud.visible


func _update_hud() -> void:
	if _hud == null or not _hud.visible:
		return
	var label: Label = _hud.get_node("Stats")
	if label == null:
		return
	var fps := Engine.get_frames_per_second()
	var origin_str := "(%.2f, %.2f, %.2f)" % [global_transform.origin.x, global_transform.origin.y, global_transform.origin.z]
	var head_str := "yaw=%.1f° pitch=%.1f°" % [rad_to_deg(_yaw), rad_to_deg(_pitch)]
	var lh := "L: (%.2f, %.2f, %.2f)" % [_hand_pose["left_pos"].x, _hand_pose["left_pos"].y, _hand_pose["left_pos"].z]
	var rh := "R: (%.2f, %.2f, %.2f)" % [_hand_pose["right_pos"].x, _hand_pose["right_pos"].y, _hand_pose["right_pos"].z]
	label.text = "VR_DEBUG=1\nfps: %.0f\norigin: %s\nhead: %s\n%s\n%s" % [fps, origin_str, head_str, lh, rh]
