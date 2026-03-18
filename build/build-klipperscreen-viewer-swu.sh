#!/bin/sh

set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_PATH="$ROOT/apps/klipperscreen-viewer"

MODEL_INPUT=${1:-KS1}
MODEL_CODE=$(printf '%s' "$MODEL_INPUT" | tr '[:lower:]' '[:upper:]')

case "$MODEL_CODE" in
    K2P|K3|K3V2)
        PACKAGE_MODEL=K3
        DEFAULT_OUTPUT="$ROOT/build/dist/update-k2p-k3.swu"
        ;;
    KS1|KS1M)
        PACKAGE_MODEL=KS1
        DEFAULT_OUTPUT="$ROOT/build/dist/update-ks1.swu"
        ;;
    K3M)
        PACKAGE_MODEL=K3M
        DEFAULT_OUTPUT="$ROOT/build/dist/update-k3m.swu"
        ;;
    *)
        echo "Unsupported model: $MODEL_INPUT" >&2
        echo "Supported values: K2P, K3, K3V2, KS1, KS1M, K3M" >&2
        exit 1
        ;;
esac

OUTPUT_PATH=${2:-$DEFAULT_OUTPUT}
SRC="$APP_PATH/src/fb-vnc-viewer.c"
BIN="$APP_PATH/bin/fb-vnc-viewer"
BUILD_BIN_SCRIPT="$ROOT/build/build-klipperscreen-viewer-bin.sh"
CONTAINER_OUTPUT="/build/dist/$(basename -- "$OUTPUT_PATH")"

if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ] || [ "$BUILD_BIN_SCRIPT" -nt "$BIN" ]; then
    "$BUILD_BIN_SCRIPT"
fi

mkdir -p "$(dirname -- "$OUTPUT_PATH")"

docker run --rm \
  -e KOBRA_MODEL_CODE="$PACKAGE_MODEL" \
  -v "$ROOT/build:/build" \
  -v "$ROOT/apps:/apps" \
  ghcr.io/jbatonnet/rinkhals/build \
    /bin/bash -c "chmod +x /build/build-swu.sh && /build/build-swu.sh /apps/klipperscreen-viewer $CONTAINER_OUTPUT"

if [ "$OUTPUT_PATH" != "$ROOT/build/dist/$(basename -- "$OUTPUT_PATH")" ]; then
        cp "$ROOT/build/dist/$(basename -- "$OUTPUT_PATH")" "$OUTPUT_PATH"
fi
