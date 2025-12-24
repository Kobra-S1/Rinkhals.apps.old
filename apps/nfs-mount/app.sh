#!/bin/sh

source /useremain/rinkhals/.current/tools.sh

APP_ROOT=$(dirname $(realpath $0))
APP_NAME=$(basename $APP_ROOT)

status() {
    # Check if both mount points are mounted
    if mountpoint -q "/userdata/app/gk/printer_data/gcodes" 2>/dev/null && mountpoint -q "/useremain/app/gk/gcodes" 2>/dev/null; then
        report_status $APP_STATUS_STARTED "NFS mounted"
    else
        report_status $APP_STATUS_STOPPED
    fi
}

start() {
    stop
    
    SERVER=$(get_app_property $APP_NAME server)
    PORT=$(get_app_property $APP_NAME port)
    SHARE=$(get_app_property $APP_NAME share)
    
    # Skip if using placeholder defaults
    if [ "$SERVER" = "192.168.1.100" ] && [ "$SHARE" = "/mnt/share" ]; then
        log "NFS mount skipped: using placeholder defaults"
        exit 0
    fi
    
    log "Starting NFS mount: $SERVER:$SHARE -> /userdata/app/gk/printer_data/gcodes and /useremain/app/gk/gcodes"
    
    # Create mount points if they don't exist
    mkdir -p "/userdata/app/gk/printer_data/gcodes"
    mkdir -p "/useremain/app/gk/gcodes"
    
    # Force unmount existing mounts
    umount -f "/userdata/app/gk/printer_data/gcodes" 2>/dev/null
    umount -f "/useremain/app/gk/gcodes" 2>/dev/null
    
    # Mount the NFS share to first location
    mount -o port=$PORT,nolock,proto=tcp -t nfs "$SERVER:$SHARE" "/userdata/app/gk/printer_data/gcodes" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        # Bind mount to second location
        mount --bind "/userdata/app/gk/printer_data/gcodes" "/useremain/app/gk/gcodes" 2>/dev/null
        
        if [ $? -eq 0 ]; then
            log "NFS mount successful: $SERVER:$SHARE -> both locations"
        else
            log "Bind mount failed, unmounting NFS"
            umount -f "/userdata/app/gk/printer_data/gcodes" 2>/dev/null
            # Remount original ext4 mount on failure (only userdata location)
            mount -t ext4 -o rw,relatime /dev/block/by-name/useremain "/userdata/app/gk/printer_data/gcodes" 2>/dev/null
            exit 1
        fi
    else
        log "NFS mount failed: $SERVER:$SHARE -> /userdata/app/gk/printer_data/gcodes"
        # Remount original ext4 mount on failure (only userdata location)
        mount -t ext4 -o rw,relatime /dev/block/by-name/useremain "/userdata/app/gk/printer_data/gcodes" 2>/dev/null
        exit 1
    fi
}

stop() {
    log "Stopping NFS mount: both locations"
    
    # Force unmount both locations (in reverse order due to bind mount)
    umount -f "/useremain/app/gk/gcodes" 2>/dev/null
    umount -f "/userdata/app/gk/printer_data/gcodes" 2>/dev/null
    
    # Remount original ext4 mount (only userdata location)
    mount -t ext4 -o rw,relatime /dev/block/by-name/useremain "/userdata/app/gk/printer_data/gcodes" 2>/dev/null
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
    *)
        echo "Usage: $0 {status|start|stop}" >&2
        exit 1
        ;;
esac
