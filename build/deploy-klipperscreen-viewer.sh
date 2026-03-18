#!/bin/sh

set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_BIN_SCRIPT="$ROOT/build/build-klipperscreen-viewer-bin.sh"

TARGET_IP=${KOBRA_IP:-$1}

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