extends Node
## VRDebugAutoload — opt-in flag for the VR debug path.
##
## Register this as an autoload named "VRDebug" to enable
## VRDebug.enabled in the running project. The autoload does
## nothing on its own — feature code (VRPlayer.gd, HUD, capture)
## checks VRDebug.enabled and acts accordingly.
##
## Opt-in surface (any one is enough):
##   - Env var: VR_DEBUG=1
##   - CLI arg: --vr-debug
##   - Project setting: vr_test/debug_enabled (read by _detect())

signal enabled_changed(enabled: bool)

const PROJECT_SETTING := "vr_test/debug_enabled"

var enabled: bool = false


func _ready() -> void:
	# Always alive, even when the scene tree is paused (e.g. during a
	# pause menu in a real headset session). The autoload itself does
	# not render or input — feature code does.
	process_mode = Node.PROCESS_MODE_ALWAYS
	enabled = _detect()
	if enabled:
		print("[VRDebug] debug path enabled (VR_DEBUG / --vr-debug / project setting)")
		enabled_changed.emit(true)


func _detect() -> bool:
	if OS.get_environment("VR_DEBUG") in ["1", "true", "yes", "on"]:
		return true
	for arg in OS.get_cmdline_user_args():
		if arg == "--vr-debug":
			return true
	if ProjectSettings.has_setting(PROJECT_SETTING):
		return bool(ProjectSettings.get_setting(PROJECT_SETTING))
	return false


func toggle() -> void:
	enabled = not enabled
	enabled_changed.emit(enabled)
