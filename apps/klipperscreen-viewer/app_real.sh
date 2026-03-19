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
VNC_COLOR_DEPTH="16"
VNC_UPDATE_INTERVAL_MS="66"
VNC_DIRECT_RENDER="1"
UI_KILL_DEBUG="0"
VIEWER_EXIT_HOLD_MS="5000"
VIEWER_EXIT_CORNER_PX="0"
VIEWER_EXIT_MOVE_TOL_PX="0"
. "$CONF_FILE"

case "$UI_KILL_DEBUG" in
    1|true|TRUE|yes|YES|on|ON) UI_KILL_DEBUG="1" ;;
    *) UI_KILL_DEBUG="0" ;;
esac

case "$VIEWER_EXIT_HOLD_MS" in
    ''|*[!0-9]*) VIEWER_EXIT_HOLD_MS="5000" ;;
esac
case "$VIEWER_EXIT_CORNER_PX" in
    ''|*[!0-9]*) VIEWER_EXIT_CORNER_PX="0" ;;
esac
case "$VIEWER_EXIT_MOVE_TOL_PX" in
    ''|*[!0-9]*) VIEWER_EXIT_MOVE_TOL_PX="0" ;;
esac

is_ipv4() {
    echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

resolve_ipv4_host() {
    HOSTNAME="$1"
    RESOLVED=""
    RESOLV_CONF=/etc/resolv.conf

    if is_ipv4 "$HOSTNAME"; then
        echo "$HOSTNAME"
        return 0
    fi

    try_resolve_once() {
        CANDIDATE="$1"

        if command -v getent >/dev/null 2>&1; then
            RESOLVED=$(getent ahostsv4 "$CANDIDATE" 2>/dev/null | awk 'NR==1 { print $1; exit }')
            if [ -n "$RESOLVED" ] && is_ipv4 "$RESOLVED"; then
                echo "$RESOLVED"
                return 0
            fi
        fi

        if command -v nslookup >/dev/null 2>&1; then
            RESOLVED=$(nslookup "$CANDIDATE" 2>/dev/null | awk '/^Address[[:space:]]*[0-9]*:[[:space:]]/ { print $NF; exit }')
            if [ -n "$RESOLVED" ] && is_ipv4 "$RESOLVED"; then
                echo "$RESOLVED"
                return 0
            fi
        fi

        if command -v ping >/dev/null 2>&1; then
            RESOLVED=$(ping -c 1 "$CANDIDATE" 2>/dev/null | sed -n '1s/.*(\([0-9.]*\)).*/\1/p')
            if [ -n "$RESOLVED" ] && is_ipv4 "$RESOLVED"; then
                echo "$RESOLVED"
                return 0
            fi
        fi

        return 1
    }

    if try_resolve_once "$HOSTNAME"; then
        return 0
    fi

    if echo "$HOSTNAME" | grep -q '\.'; then
        return 1
    fi

    if [ -r "$RESOLV_CONF" ]; then
        for SUFFIX in $(awk '
            $1 == "search" || $1 == "domain" {
                for (i = 2; i <= NF; i++) print $i
            }
        ' "$RESOLV_CONF" 2>/dev/null); do
            [ -n "$SUFFIX" ] || continue
            if try_resolve_once "$HOSTNAME.$SUFFIX"; then
                return 0
            fi
        done
    fi

    return 1
}

ui_debug_log() {
    [ "$UI_KILL_DEBUG" = "1" ] || return 0
    mkdir -p "$RINKHALS_LOGS" 2>/dev/null || true
    echo "$(date): $*" >> "$RINKHALS_LOGS/app-fb-vnc-viewer-ui-kill.log"
}

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

ui_pids() {
    ui_targets | awk -F'|' '{ print $1 }'
}

ui_targets() {
    for PROC_DIR in /proc/[0-9]*; do
        [ -r "$PROC_DIR/cmdline" ] || continue
        PID=${PROC_DIR#/proc/}
        COMM=$(cat "$PROC_DIR/comm" 2>/dev/null)
        CMDLINE=$(tr '\000' ' ' < "$PROC_DIR/cmdline" 2>/dev/null)

        case "$COMM" in
            K3SysUi|K3SysUi.patch|rinkhals-ui.py|rinkhals-ui.sh)
                echo "$PID|$COMM|$CMDLINE"
                continue
                ;;
        esac

        case "$CMDLINE" in
            */opt/rinkhals/ui/rinkhals-ui.py*|*/opt/rinkhals/ui/rinkhals-ui.sh*)
                echo "$PID|$COMM|$CMDLINE"
                ;;
        esac
    done | awk -F'|' '!seen[$1]++'
}

kill_ui_once() {
    TARGETS=$(ui_targets)
    PIDS=$(echo "$TARGETS" | awk -F'|' 'NF { print $1 }')
    if [ -n "$PIDS" ]; then
        echo "$TARGETS" | while IFS='|' read -r PID COMM CMDLINE; do
            [ -n "$PID" ] || continue
            ui_debug_log "ui-kill term pid=$PID comm=$COMM cmd=$CMDLINE"
        done

        kill $PIDS >/dev/null 2>&1 || true
        msleep 150

        TARGETS=$(ui_targets)
        PIDS=$(echo "$TARGETS" | awk -F'|' 'NF { print $1 }')
        if [ -n "$PIDS" ]; then
            echo "$TARGETS" | while IFS='|' read -r PID COMM CMDLINE; do
                [ -n "$PID" ] || continue
                ui_debug_log "ui-kill kill9 pid=$PID comm=$COMM cmd=$CMDLINE"
            done
            kill -9 $PIDS >/dev/null 2>&1 || true
        else
            ui_debug_log "ui-kill term-clean"
        fi
    else
        ui_debug_log "ui-kill no-targets"
    fi
}

kill_ui_retry_bg() {
    (
        I=0
        # Keep nuking UI respawns for ~4.5s without blocking app start.
        while [ "$I" -lt 15 ]; do
            kill_ui_once
            msleep 300
            I=$((I + 1))
        done
    ) >/dev/null 2>&1 &
}

start() {
    CONNECT_HOST="$VNC_HOST"

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

    if ! is_ipv4 "$VNC_HOST"; then
        RESOLVED_HOST=$(resolve_ipv4_host "$VNC_HOST" || true)
        if [ -n "$RESOLVED_HOST" ] && is_ipv4 "$RESOLVED_HOST"; then
            CONNECT_HOST="$RESOLVED_HOST"
            echo "Resolved VNC_HOST '$VNC_HOST' to IPv4 $CONNECT_HOST"
        else
            echo "Warning: Could not resolve VNC_HOST '$VNC_HOST' to IPv4, trying hostname directly" >&2
        fi
    fi

    kill_by_name fb-vnc-viewer

    # Fire-and-return start path: do one immediate UI kill pass, then continue in background.
    kill_ui_once

    echo "Connecting to VNC at $CONNECT_HOST:$VNC_PORT (profile=$PROFILE expected=${VNC_WIDTH}x${VNC_HEIGHT} rotation=$ROTATION depth=$VNC_COLOR_DEPTH interval=${VNC_UPDATE_INTERVAL_MS}ms direct=${VNC_DIRECT_RENDER})"

    HOLD_EXIT_CMD="sh $APP_ROOT/app.sh stop >/dev/null 2>&1 &"

    VIEWER_EXIT_HOLD_MS="$VIEWER_EXIT_HOLD_MS" \
    VIEWER_EXIT_CORNER_PX="$VIEWER_EXIT_CORNER_PX" \
    VIEWER_EXIT_MOVE_TOL_PX="$VIEWER_EXIT_MOVE_TOL_PX" \
    VIEWER_HOLD_EXIT_CMD="$HOLD_EXIT_CMD" \
    VNC_PASSWORD="${VNC_PASSWORD:-}" \
    "$BIN" \
        -r "$ROTATION" \
        -p "$VNC_PORT" \
        -b "$VNC_COLOR_DEPTH" \
        -u "$VNC_UPDATE_INTERVAL_MS" \
        -d "$VNC_DIRECT_RENDER" \
        "$CONNECT_HOST" \
        >> "$RINKHALS_LOGS/app-fb-vnc-viewer.log" 2>&1 &

    # Keep handling UI respawns asynchronously; return immediately.
    kill_ui_retry_bg

    return 0
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
