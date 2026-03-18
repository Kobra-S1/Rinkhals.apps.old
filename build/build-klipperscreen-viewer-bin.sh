#!/bin/sh

# Build fb-vnc-viewer as a standalone artifact from Rinkhals.apps only.
# No dependency on a local Rinkhals checkout.

set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_DIR="$ROOT/apps/klipperscreen-viewer"
SRC="$APP_DIR/src/fb-vnc-viewer.c"
OUT_BIN="$APP_DIR/bin/fb-vnc-viewer"

if [ ! -f "$SRC" ]; then
    echo "Missing source: $SRC" >&2
    exit 1
fi

mkdir -p "$APP_DIR/bin"

echo "[1/2] Building ARM static binary in isolated container..."
docker run --rm \
  --platform=linux/arm/v7 \
  -v "$APP_DIR:/work/app" \
  debian:12 \
  /bin/sh -lc '
    set -e
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get install -y --no-install-recommends \
      ca-certificates git build-essential cmake pkg-config zlib1g-dev file

    cd /tmp
    rm -rf libvncserver libvncserver-build
    git clone --depth=1 https://github.com/LibVNC/libvncserver.git

    cmake -S libvncserver -B libvncserver-build \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DWITH_EXAMPLES=OFF \
      -DWITH_SDL=OFF \
      -DWITH_GNUTLS=OFF \
      -DWITH_OPENSSL=OFF \
      -DWITH_WEBSOCKETS=OFF \
      -DWITH_LZO=OFF \
      -DWITH_FFMPEG=OFF \
      -DWITH_JPEG=OFF \
      -DWITH_PNG=OFF \
      -DWITH_SYSTEMD=OFF

    cmake --build libvncserver-build --target vncclient -j"$(nproc)"

    gcc -O2 -pipe -static \
      -I/tmp/libvncserver/include \
      -I/tmp/libvncserver-build/include \
      /work/app/src/fb-vnc-viewer.c \
      -o /work/app/bin/fb-vnc-viewer \
      /tmp/libvncserver-build/libvncclient.a \
      -lz -lpthread

    strip /work/app/bin/fb-vnc-viewer || true
    file /work/app/bin/fb-vnc-viewer
  '

echo "[2/2] Done: $OUT_BIN"
