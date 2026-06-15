#!/usr/bin/env bash
# vr_debug.sh — VR project runner with optional debug mode and capture.
#
# Subcommands:
#   run       — launch the project. If VR_DEBUG is unset, runs normally
#               (i.e. F5-equivalent). If VR_DEBUG=1, adds --vr-debug and
#               --xr-mode off so the rig is drivable on a non-VR machine.
#   capture   — take a side-by-side stereo screenshot (PNG) of the scene.
#   video     — record a side-by-side video (MP4) of the scene.
#   status    — print whether an XR runtime is detected, the Godot version,
#               and whether the debug path is currently active.
#
# This script is portable. It does not require bash > 4. On macOS it
# uses the system's godot binary; on Linux it wraps godot in xvfb-run
# when no display is present.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

# --- Args ---------------------------------------------------------------------
SUBCMD="${1:-run}"
shift || true

VR_DEBUG="${VR_DEBUG:-}"
if [[ "$VR_DEBUG" == "1" || "$VR_DEBUG" == "true" ]]; then
    VR_DEBUG=1
else
    VR_DEBUG=
fi

OUT_DIR="${VR_OUT_DIR:-screenshots/vr-debug}"
SCENE="${VR_SCENE:-res://main.tscn}"
CAPTURE_SCRIPT="$SKILL_DIR/examples/VRDebugCapture.gd"

# --- Helpers -----------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

detect_runtime() {
    # Look for the OpenXR active runtime file. If present, assume a runtime
    # is installed and reachable. On this dev box the file is absent, so
    # we land in the no-runtime branch and force --xr-mode off.
    if [[ -n "${XR_RUNTIME_JSON:-}" && -f "${XR_RUNTIME_JSON}" ]]; then
        echo "present"
        return
    fi
    if [[ -f "$HOME/.config/openxr/1/active_runtime.json" ]]; then
        echo "present"
        return
    fi
    # SteamVR / Monado common locations.
    for p in /etc/xdg/openxr/1/active_runtime.json \
             /usr/local/share/openxr/1/active_runtime.json \
             /usr/share/openxr/1/active_runtime.json; do
        if [[ -f "$p" ]]; then
            echo "present"
            return
        fi
    done
    echo "absent"
}

godot_version() {
    godot --version 2>/dev/null | head -n1 || echo "godot not on PATH"
}

display_wrap() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        return
    fi
    if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        return
    fi
    if have xvfb-run; then
        echo "xvfb-run -a -s -screen 0 1920x1080x24"
        return
    fi
    # Fallback: bundled minimal Xvfb wrapper. Lives in tools/xvfb-run.
    local fallback="$HERE/xvfb-run"
    if [[ -x "$fallback" ]]; then
        echo "$fallback"
    fi
}

renderer_args() {
    # Prefer the Forward+ renderer when we have a GPU; fall back to
    # the same Mobile path the project is configured for.
    echo "--rendering-method mobile"
}

# --- Status ------------------------------------------------------------------
cmd_status() {
    echo "=== vr-dev status ==="
    echo "Godot:        $(godot_version)"
    echo "XR runtime:   $(detect_runtime)"
    if [[ -n "$VR_DEBUG" ]]; then
        echo "Debug mode:   ON (VR_DEBUG=$VR_DEBUG)"
    else
        echo "Debug mode:   off (set VR_DEBUG=1 to enable)"
    fi
    echo "Project root: $(pwd)"
    echo "Main scene:   $SCENE"
}

# --- Run ---------------------------------------------------------------------
cmd_run() {
    local godot_args=(--path .)

    if [[ -n "$VR_DEBUG" ]]; then
        godot_args+=(--xr-mode off)
    fi

    local wrap
    wrap="$(display_wrap)"
    if [[ -n "$wrap" ]]; then
        # shellcheck disable=SC2086
        $wrap godot "${godot_args[@]}" "$@"
    else
        godot "${godot_args[@]}" "$@"
    fi
}

# --- Capture -----------------------------------------------------------------
cmd_capture() {
    mkdir -p "$OUT_DIR"
    touch screenshots/.gdignore 2>/dev/null || true
    touch "$OUT_DIR/.gdignore" 2>/dev/null || true

    local wrap
    wrap="$(display_wrap)"

    # We need a real rasteriser; the dummy backend cannot produce PNGs.
    # Pick the project's configured renderer (mobile). xvfb provides the
    # X server when none is attached.
    local godot_args=(--path . --rendering-method mobile)
    if [[ -n "$VR_DEBUG" ]]; then
        godot_args+=(--xr-mode off)
    fi

    echo "=== Capturing stereo screenshot to $OUT_DIR ==="
    if [[ -n "$wrap" ]]; then
        # shellcheck disable=SC2086
        $wrap godot "${godot_args[@]}" \
            --script "$CAPTURE_SCRIPT" \
            -- \
            --vr-screenshot \
            --vr-out "$OUT_DIR" \
            --vr-scene "$SCENE" \
            "$@"
    else
        godot "${godot_args[@]}" \
            --script "$CAPTURE_SCRIPT" \
            -- \
            --vr-screenshot \
            --vr-out "$OUT_DIR" \
            --vr-scene "$SCENE" \
            "$@"
    fi
}

# --- Video -------------------------------------------------------------------
cmd_video() {
    mkdir -p "$OUT_DIR/frames"
    touch screenshots/.gdignore 2>/dev/null || true
    touch "$OUT_DIR/.gdignore" 2>/dev/null || true

    local wrap
    wrap="$(display_wrap)"

    local godot_args=(--path .)
    if [[ -n "$VR_DEBUG" ]]; then
        godot_args+=(--xr-mode off)
    fi

    # Wrap in xvfb if we have no display.
    local runner
    if [[ -n "$wrap" ]]; then
        runner="$wrap"
    else
        runner=""
    fi

    echo "=== Recording stereo video to $OUT_DIR ==="
    # shellcheck disable=SC2086
    $runner godot "${godot_args[@]}" \
        --write-movie "$OUT_DIR/frames/frame.png" \
        --fixed-fps 30 \
        --quit-after 300 \
        --script "$CAPTURE_SCRIPT" \
        -- \
        --vr-video \
        --vr-out "$OUT_DIR" \
        --vr-scene "$SCENE" \
        "$@"

    if have ffmpeg; then
        echo "=== Encoding video.mp4 ==="
        ffmpeg -y -framerate 30 -pattern_type glob \
            -i "$OUT_DIR/frames/frame*.png" \
            -c:v libx264 -pix_fmt yuv420p -preset medium -crf 22 \
            -movflags +faststart \
            "$OUT_DIR/video.mp4"
    else
        echo "ffmpeg not found — frames written to $OUT_DIR/frames/"
    fi
}

# --- Dispatch ----------------------------------------------------------------
case "$SUBCMD" in
    run)     cmd_run "$@" ;;
    capture) cmd_capture "$@" ;;
    video)   cmd_video "$@" ;;
    status)  cmd_status "$@" ;;
    -h|--help|help)
        cat <<EOF
vr_debug.sh — VR project runner with optional debug mode and capture.

Usage:
  VR_DEBUG=1 bash .agents/skills/vr-dev/tools/vr_debug.sh run
  bash .agents/skills/vr-dev/tools/vr_debug.sh capture
  bash .agents/skills/vr-dev/tools/vr_debug.sh video
  bash .agents/skills/vr-dev/tools/vr_debug.sh status

Env:
  VR_DEBUG=1   enable the VR debug path (drives rig from keyboard/mouse)
  VR_OUT_DIR   override the output directory (default: screenshots/vr-debug)
  VR_SCENE     override the main scene (default: res://main.tscn)
EOF
        ;;
    *) echo "unknown subcommand: $SUBCMD (try run, capture, video, status)" >&2; exit 2 ;;
esac
