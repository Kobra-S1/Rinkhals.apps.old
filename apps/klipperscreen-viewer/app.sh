#!/bin/sh

. /useremain/rinkhals/.current/tools.sh

APP_ROOT=$(dirname $(realpath $0))
BIN="$APP_ROOT/bin/fb-vnc-viewer"

# Config is stored outside app folder so updates don't overwrite user settings.
CONF_FILE="/useremain/rinkhals/klipperscreen-viewer.conf"
if [ ! -f "$CONF_FILE" ]; then
    cp "$APP_ROOT/klipperscreen-viewer.conf" "$CONF_FILE"
fi

VNC_HOST=""
VNC_PORT="5900"
VNC_PASSWORD=""
VIEWER_ROTATION=""
. "$CONF_FILE"

case "$KOBRA_MODEL_CODE" in
    KS1)
        PROFILE="ks1"
        VNC_WIDTH=800
        VNC_HEIGHT=480
        DEFAULT_ROTATION=180
        ;;
    KS1M)
        PROFILE="ks1m"
        VNC_WIDTH=800
        VNC_HEIGHT=480
        DEFAULT_ROTATION=180
        ;;
    K3M)
        PROFILE="k3m"
        VNC_WIDTH=480
        VNC_HEIGHT=272
        DEFAULT_ROTATION=90
        ;;
    K2P)
        PROFILE="k2p"
        VNC_WIDTH=480
        VNC_HEIGHT=272
        DEFAULT_ROTATION=270
        ;;
    K3)
        PROFILE="k3"
        VNC_WIDTH=480
        VNC_HEIGHT=272
        DEFAULT_ROTATION=270
        ;;
    K3V2)
        PROFILE="k3v2"
        VNC_WIDTH=480
        VNC_HEIGHT=272
        DEFAULT_ROTATION=270
        ;;
    *)
        PROFILE="k3"
        VNC_WIDTH=480
        VNC_HEIGHT=272
        DEFAULT_ROTATION=270
        ;;
esac

ROTATION="${VIEWER_ROTATION:-$DEFAULT_ROTATION}"

status() {
    PIDS=$(get_by_name fb-vnc-viewer)
    if [ "$PIDS" = "" ]; then
        report_status $APP_STATUS_STOPPED
    else
        report_status $APP_STATUS_STARTED "$PIDS"
    fi
}

_restart_k3sysui() {
    SYSUI=/userdata/app/gk/K3SysUi.patch
    if [ -f "$SYSUI" ]; then
        cd /userdata/app/gk
        ./${SYSUI##*/} >> "$RINKHALS_LOGS/K3SysUi.log" 2>&1 &
        cd - > /dev/null
    fi
}

start() {
    if [ ! -x "$BIN" ]; then
        chmod +x "$BIN" 2>/dev/null
    fi

    if [ ! -x "$BIN" ]; then
        echo "Error: $BIN is missing or not executable" >&2
        echo "Build it with: /build/build-klipperscreen-viewer-bin.sh" >&2
        report_status $APP_STATUS_STOPPED
        return 1
    fi

    if [ -z "$VNC_HOST" ]; then
        echo "Error: VNC_HOST not configured in $CONF_FILE" >&2
        report_status $APP_STATUS_STOPPED
        return 1
    fi

    kill_by_name fb-vnc-viewer

    # Ensure nothing races us for /dev/input/event0 and framebuffer ownership.
    kill_by_name K3SysUi
    sleep 1
    kill_by_name rinkhals-ui.py

    echo "Connecting to VNC at $VNC_HOST:$VNC_PORT (profile=$PROFILE expected=${VNC_WIDTH}x${VNC_HEIGHT} rotation=$ROTATION)"

    VNC_PASSWORD="${VNC_PASSWORD:-}" \
    "$BIN" \
        -r "$ROTATION" \
        -p "$VNC_PORT" \
        "$VNC_HOST" \
        >> "$RINKHALS_LOGS/app-fb-vnc-viewer.log" 2>&1 &

    sleep 2
    PIDS=$(get_by_name fb-vnc-viewer)
    if [ -z "$PIDS" ]; then
        echo "Failed to start fb-vnc-viewer - see $RINKHALS_LOGS/app-fb-vnc-viewer.log" >&2
        _restart_k3sysui
        report_status $APP_STATUS_STOPPED
        return 1
    fi
}

stop() {
    kill_by_name fb-vnc-viewer
    _restart_k3sysui
}

version() {
    echo "1.0.0"
}

case "$1" in
    status)
        status
        ;;
    start)
        start
        ;;
    stop)
        stop
        ;;
    version)
        version
        ;;
    *)
        echo "Usage: $0 {status|start|stop|version}" >&2
        exit 1
        ;;
esac
