#!/bin/sh

set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_BIN_SCRIPT="$ROOT/build/build-klipperscreen-viewer-bin.sh"

TARGET_IP=${KOBRA_IP:-$1}
TARGET_USER=${KOBRA_USER:-root}
TARGET_PASSWORD=${KOBRA_PASSWORD:-rockchip}
REMOTE_APP_ROOT=/useremain/home/rinkhals/apps/klipperscreen-viewer
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o ConnectionAttempts=1"

if [ -z "$TARGET_IP" ]; then
    echo "Usage: KOBRA_IP=<host> ./build/deploy-klipperscreen-viewer.sh" >&2
    echo "   or: ./build/deploy-klipperscreen-viewer.sh <host>" >&2
    exit 1
fi

"$BUILD_BIN_SCRIPT"

docker run --rm -it \
  -e KOBRA_IP="$TARGET_IP" \
  -v "$ROOT/build:/build:Z" \
  -v "$ROOT/apps:/apps:Z" \
  --entrypoint=/bin/sh \
  docker.io/rclone/rclone:1.69.1 \
  /build/deploy-app.sh klipperscreen-viewer

fix_remote_exec_bits() {
    REMOTE_CMD="
        find '$REMOTE_APP_ROOT' -maxdepth 1 -type f -name '*.sh' -exec chmod 755 {} \;
        find '$REMOTE_APP_ROOT/bin' -maxdepth 1 -type f -exec chmod 755 {} \; 2>/dev/null || true
    "

    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$TARGET_PASSWORD" ssh $SSH_OPTS "$TARGET_USER@$TARGET_IP" "$REMOTE_CMD"
        return 0
    fi

    if command -v ssh >/dev/null 2>&1; then
        echo "Warning: sshpass not found, trying plain ssh for remote chmod..."
        ssh $SSH_OPTS "$TARGET_USER@$TARGET_IP" "$REMOTE_CMD"
        return 0
    fi

    echo "Warning: neither sshpass nor ssh found; remote exec bits were not fixed." >&2
    return 1
}

fix_remote_exec_bits
