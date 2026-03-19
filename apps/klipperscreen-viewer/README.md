# KlipperScreen Viewer

Standalone Rinkhals app that displays a remote KlipperScreen VNC session on the
printer touchscreen and forwards touch input back to the VNC server.

This app ships its own `fb-vnc-viewer` binary and can be installed on an
existing Rinkhals system without rebuilding the main Rinkhals firmware.

## Build

Build the ARM binary from this repo only:

```bash
cd /path/to/Rinkhals.apps
./build/build-klipperscreen-viewer-bin.sh
```

Build SWUs:

```bash
cd /path/to/Rinkhals.apps
./build/build-klipperscreen-viewer-swu.sh KS1
./build/build-klipperscreen-viewer-swu.sh K3
./build/build-klipperscreen-viewer-swu.sh K3M
```

The wrapper above rebuilds `bin/fb-vnc-viewer` automatically if
`src/fb-vnc-viewer.c` changed.

Raw packaging commands, if the binary is already up to date:

```bash
docker run --rm -e KOBRA_MODEL_CODE="K3" -v "$(pwd)/build:/build" -v "$(pwd)/apps:/apps" ghcr.io/jbatonnet/rinkhals/build /bin/bash -c "chmod +x /build/build-swu.sh && /build/build-swu.sh /apps/klipperscreen-viewer /build/dist/update-k2p-k3.swu"
docker run --rm -e KOBRA_MODEL_CODE="KS1" -v "$(pwd)/build:/build" -v "$(pwd)/apps:/apps" ghcr.io/jbatonnet/rinkhals/build /bin/bash -c "chmod +x /build/build-swu.sh && /build/build-swu.sh /apps/klipperscreen-viewer /build/dist/update-ks1.swu"
docker run --rm -e KOBRA_MODEL_CODE="K3M" -v "$(pwd)/build:/build" -v "$(pwd)/apps:/apps" ghcr.io/jbatonnet/rinkhals/build /bin/bash -c "chmod +x /build/build-swu.sh && /build/build-swu.sh /apps/klipperscreen-viewer /build/dist/update-k3m.swu"
```

Package mapping:
- `update-k2p-k3.swu`: K2P, K3, K3V2
- `update-ks1.swu`: KS1, KS1M
- `update-k3m.swu`: K3M

## Printer-side model mapping

The app automatically selects viewer rotation from `KOBRA_MODEL_CODE`:

| Model | Expected VNC size | Rotation |
|---|---:|---:|
| KS1 | 800x480 | 180 |
| KS1M | 800x480 | 180 |
| K3M | 480x272 | 90 |
| K2P | 480x272 | 270 |
| K3 | 480x272 | 270 |
| K3V2 | 480x272 | 270 |

Optional override in `/useremain/rinkhals/klipperscreen-viewer.conf`:

```bash
VNC_HOST=<rpi-ip-or-hostname>
VNC_PORT=5900
VNC_PASSWORD=
VIEWER_ROTATION=
VNC_COLOR_DEPTH=16
VNC_UPDATE_INTERVAL_MS=66
VNC_DIRECT_RENDER=1
UI_KILL_DEBUG=0
VIEWER_BOOT_DELAY_SEC=15
VIEWER_EXIT_HOLD_MS=5000
VIEWER_EXIT_CORNER_PX=0
VIEWER_EXIT_MOVE_TOL_PX=0
```

`VNC_HOST` accepts either an IPv4 address or a hostname. If a hostname is set,
the app attempts to resolve it to IPv4 at startup before connecting.

Set `VIEWER_ROTATION` to `0`, `90`, `180`, or `270` only if the automatic model
mapping is wrong for your setup.

Performance tuning:
- `VNC_COLOR_DEPTH=16` lowers CPU and bandwidth on the printer.
- `VNC_UPDATE_INTERVAL_MS=50..100` trades smoothness for lower load.
- `VNC_DIRECT_RENDER=1` (default) removes backbuffer flip memcpy for lower CPU.
- Set `VNC_DIRECT_RENDER=0` if you prefer the older tear-reduction path.
- `UI_KILL_DEBUG=1` logs UI takeover kills to `/tmp/rinkhals/app-fb-vnc-viewer-ui-kill.log`.
- `VIEWER_BOOT_DELAY_SEC=15` delays startup during Rinkhals boot only (non-blocking wrapper).
- Hold the physical top-left corner for `VIEWER_EXIT_HOLD_MS` (default `5000`) to stop the viewer locally.
- `VIEWER_EXIT_CORNER_PX=0` auto-sizes the trigger zone from the screen size.
- `VIEWER_EXIT_MOVE_TOL_PX=0` auto-sizes allowed finger drift while holding.
- If the VNC server is temporarily unavailable, the viewer now stays running and
  retries connection every 5 seconds until stopped.

Startup architecture:
- `app.sh` is a non-blocking launcher wrapper and should return immediately.
- Real start/stop logic runs in `app_real.sh`.

## Raspberry Pi setup

Use `rpi-setup.sh` to configure a headless TigerVNC/X display for KlipperScreen.

Examples:

```bash
sudo bash rpi-setup.sh --profile ks1
sudo bash rpi-setup.sh --profile ks1m
sudo bash rpi-setup.sh --profile k3
sudo bash rpi-setup.sh --profile k3v2
sudo bash rpi-setup.sh --profile k2p
sudo bash rpi-setup.sh --profile k3m
```

Supported arguments:
- `--profile <name>` or `--printer-model <name>`
- `--width <pixels>`
- `--height <pixels>`
- `--port <port>`
- `--rotation <deg>`
- `--depth <16|24>`
- `--quality <0-9>`
- `--compress <0-9>`

Note: `--quality` / `--compress` are applied only if your `Xtigervnc` build
supports those options; otherwise they are skipped automatically.

Recommended low-CPU Pi-side settings:

```bash
sudo bash rpi-setup.sh --profile k3 --depth 16 --quality 5 --compress 7
```

Pi-side profile mapping:

| Profile | VNC geometry | Recommended printer rotation |
|---|---:|---:|
| `ks1` | 800x480 | 180 |
| `ks1m` | 800x480 | 180 |
| `k3m` | 480x272 | 90 |
| `k3` | 480x272 | 270 |
| `k3v2` | 480x272 | 270 |
| `k2p` | 480x272 | 270 |

If needed, you can bypass profiles completely:

```bash
sudo bash rpi-setup.sh --width 480 --height 272 --rotation 270
```

## Install

Install the generated SWU from USB as `update.swu`, or copy the app directory to
`/useremain/home/rinkhals/apps/klipperscreen-viewer/`.

Direct network deploy from this repo:

```bash
cd /path/to/Rinkhals.apps
./build/deploy-klipperscreen-viewer.sh AnycubicS1
```

That wrapper rebuilds `bin/fb-vnc-viewer` first, then syncs the app directory to
the printer over SSH with rclone.

Set the printer-side config at:

```bash
/useremain/rinkhals/klipperscreen-viewer.conf
```

Then enable the app and start it from the Rinkhals UI or run:

```bash
/useremain/home/rinkhals/apps/klipperscreen-viewer/app.sh start
```
