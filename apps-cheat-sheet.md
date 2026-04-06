# Rinkhals.apps Build Cheat Sheet

Local helper notes.

---

## Repo Structure

```
apps/
  Dockerfile              ← builds the ghcr.io/jbatonnet/rinkhals/build image
  <app-name>/
    app.json              ← required: metadata + UI-exposed properties
    app.sh                ← required: status | start | stop lifecycle
    ...                   ← any supporting files copied verbatim into the SWU
build/
  build-swu.sh            ← build ONE app for ONE model → single .swu
  build-all-swus.sh       ← build ALL apps for all models → app-*.swu set
  deploy-app.sh           ← dev rsync ONE app to printer via rclone
  deploy-apps.sh          ← dev rsync ALL apps to printer via rclone
  tools.sh                ← build_swu() helper (tar + model-keyed zip)
  update.sh               ← on-printer installer (runs at SWU install time)
```

---

## Prerequisites: ARM Emulation

If you attempt to build apps containing C code (like `klipperscreen-viewer`) and get an **exec format error** during the ARMv7 cross-compilation docker phase, your system is missing ARM emulation. 

Enable it once on the host with the following command:

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm
```

Alternatively (on Debian/Ubuntu systems), install the distribution packages:

```bash
sudo apt-get install -y qemu-user-static binfmt-support
```

Verify it works by running a simple ARM container test:

```bash
docker run --rm --platform=linux/arm/v7 debian:12 /bin/sh -lc 'uname -m'
```

---

## Build Docker Image

The build image only needs rebuilding when `apps/Dockerfile` changes:

```bash
cd /path/to/Rinkhals.apps
docker build -t ghcr.io/jbatonnet/rinkhals/build -f apps/Dockerfile build
# docker push ghcr.io/jbatonnet/rinkhals/build   # only if publishing
```

The published image is already available at `ghcr.io/jbatonnet/rinkhals/build`.
Normal local builds just pull and use it.

---

## Build a Single App → SWU

Run from repo root. Mount `build/` and `apps/` into the container.
Pass the model via `KOBRA_MODEL_CODE`. Output goes to `build/dist/`.

For `klipperscreen-viewer`, do not use the raw packaging command after editing
`src/fb-vnc-viewer.c`. That command only packages the existing files under `apps/`
and will not rebuild the ARM binary. Use the wrapper below instead.

### `klipperscreen-viewer` examples

```bash
cd /path/to/Rinkhals.apps

# Rebuilds fb-vnc-viewer if src/fb-vnc-viewer.c changed, then packages KS1 SWU
./build/build-klipperscreen-viewer-swu.sh KS1

# Direct network deploy after rebuilding the binary if needed
./build/deploy-klipperscreen-viewer.sh AnycubicS1
```

```bash
# K2P and K3 share the same SWU
docker run --rm \
  -e KOBRA_MODEL_CODE=K3 \
  -v "$(pwd)/build:/build" \
  -v "$(pwd)/apps:/apps" \
  ghcr.io/jbatonnet/rinkhals/build \
  /bin/bash -c "chmod +x /build/build-swu.sh && /build/build-swu.sh /apps/<app-name> /build/dist/update-k2p-k3.swu"

# KS1
docker run --rm \
  -e KOBRA_MODEL_CODE=KS1 \
  -v "$(pwd)/build:/build" \
  -v "$(pwd)/apps:/apps" \
  ghcr.io/jbatonnet/rinkhals/build \
  /bin/bash -c "chmod +x /build/build-swu.sh && /build/build-swu.sh /apps/<app-name> /build/dist/update-ks1.swu"

# K3M
docker run --rm \
  -e KOBRA_MODEL_CODE=K3M \
  -v "$(pwd)/build:/build" \
  -v "$(pwd)/apps:/apps" \
  ghcr.io/jbatonnet/rinkhals/build \
  /bin/bash -c "chmod +x /build/build-swu.sh && /build/build-swu.sh /apps/<app-name> /build/dist/update-k3m.swu"
```

Valid `KOBRA_MODEL_CODE` values: `K2P`, `K3`, `KS1`, `K3M`.

---

## Build All Apps → SWU Set

Produces `build/dist/app-<name>-k2p-k3.swu`, `app-<name>-ks1.swu`, `app-<name>-k3m.swu`
for every app directory that contains an `app.sh`.

```bash
docker run --rm \
  -v "$(pwd)/build:/build" \
  -v "$(pwd)/apps:/apps" \
  ghcr.io/jbatonnet/rinkhals/build \
  /bin/bash -c "chmod +x /build/build-all-swus.sh && /build/build-all-swus.sh"
```

Output: `build/dist/app-*.swu`

---

## Dev Deploy (rsync via rclone, no SWU)

Syncs app files directly to the printer over SSH. No reboot needed — files land at
`/useremain/home/rinkhals/apps/<app-name>/` immediately.

### All apps

```bash
docker run --rm -it \
  -e KOBRA_IP=AnycubicS1 \
  -v "$(pwd)/build:/build:Z" \
  -v "$(pwd)/apps:/apps:Z" \
  --entrypoint=/bin/sh \
  docker.io/rclone/rclone:1.69.1 \
  /build/deploy-apps.sh
```

### Single app

```bash
docker run --rm -it \
  -e KOBRA_IP=AnycubicS1 \
  -v "$(pwd)/build:/build:Z" \
  -v "$(pwd)/apps:/apps:Z" \
  --entrypoint=/bin/sh \
  docker.io/rclone/rclone:1.69.1 \
  /build/deploy-app.sh <app-name>
```

The rclone sync skips `*.log`, `*.pyc`, `.enable`, `.disable`, `.enabled`, `.disabled`.

After syncing, restart/test the app on the printer:

```bash
ssh root@AnycubicS1
/useremain/home/rinkhals/apps/<app-name>/app.sh stop
/useremain/home/rinkhals/apps/<app-name>/app.sh start
/useremain/home/rinkhals/apps/<app-name>/app.sh status
```

---

## SWU Package Internals

`build_swu()` in `build/tools.sh`:
1. `tar -cf setup.tar.gz <app-dir>/` inside the work directory (also includes `update.sh`)
2. `zip -0 -P <model-password> update.swu update_swu/`

Passwords by model:
| Model | ZIP password |
|---|---|
| K2P / K3 | `U2FsdGVkX19deTfqpXHZnB5GeyQ/dtlbHjkUnwgCi+w=` |
| KS1 | `U2FsdGVkX1+lG6cHmshPLI/LaQr9cZCjA8HZt6Y8qmbB7riY` |
| K3M | `4DKXtEGStWHpPgZm8Xna9qluzAI8VJzpOsEIgd8brTLiXs8fLSu3vRx8o7fMf4h6` |

On-printer installer (`build/update.sh`, baked into each SWU):
- Finds the app directory inside `/useremain/update_swu/`
- `chmod +x app.sh`, calls `app.sh version`
- Copies everything to `/useremain/home/rinkhals/apps/<app-name>/`
- Beeps on completion

---

## app.json — Full Schema

```json
{
    "$version": "1",

    "name": "My App",
    "description": "What it does.",
    "version": "1.2.3",
    "url": "https://github.com/...",   // optional: shown in UI

    "requirements": {
        "cpu": 5,        // % estimated CPU usage
        "memory": 16     // MB estimated RAM usage
    },

    // Optional: surfaces editable settings in the Rinkhals UI
    "properties": {
        "my_text": {
            "display": "Label in UI",
            "type": "text",
            "validation": "^[0-9.]+$",   // optional regex
            "default": "0.0.0.0"
        },
        "my_number": {
            "display": "Port",
            "type": "number",
            "range": [1024, 65535],
            "default": 5678
        },
        "my_enum": {
            "display": "Mode",
            "type": "enum",
            "options": ["off", "on", "auto"]
        },
        "my_status": {
            "display": "Status",
            "type": "report"   // read-only display, not editable
        },
        "my_link": {
            "display": "Web UI",
            "type": "qr"       // shown as QR code + link
        }
    }
}
```

Property types: `text`, `number`, `enum`, `report` (read-only), `qr` (QR code).
Omit `display` to hide a property from the UI while keeping it in config.

---

## app.sh — Skeleton

```bash
source /useremain/rinkhals/.current/tools.sh

APP_ROOT=$(dirname $(realpath $0))

status() {
    PIDS=$(get_by_name my-process)
    if [ -z "$PIDS" ]; then
        report_status $APP_STATUS_STOPPED
    else
        report_status $APP_STATUS_STARTED "$PIDS"
    fi
}

start() {
    stop
    my-process --args >> "$RINKHALS_LOGS/app-my-process.log" 2>&1 &
    sleep 1
    PIDS=$(get_by_name my-process)
    [ -z "$PIDS" ] && { report_status $APP_STATUS_STOPPED; return 1; }
}

stop() {
    kill_by_name my-process
}

case "$1" in
    status) status ;;
    start)  start  ;;
    stop)   stop   ;;
    *) echo "Usage: $0 {status|start|stop}" >&2; exit 1 ;;
esac
```

---

## Existing Apps Reference

| App | Description |
|---|---|
| `example` | Minimal skeleton showing every `app.json` property type |
| `cloud2lan-bridge` | Routes cloud MQTT traffic to local LAN |
| `cloudflare-tunnel` | Cloudflare Tunnel (`cloudflared` binary included) |
| `discovery-helper` | Joins multicast groups for local discovery |
| `nfs-mount` | Mounts an NFS share |
| `octoapp` | OctoApp notification/monitoring companion |
| `octoeverywhere` | OctoEverywhere remote access plugin |
| `remote-debugging` | ngrok tunnel for remote SSH (disabled by default) |
| `stunnel` | TLS wrapper via stunnel |
| `tailscale` | Tailscale VPN (`tailscale` + `tailscaled` binaries included) |
| `vanilla-klipper` | Replaces stock Klipper with upstream; includes printer configs and klippy patch |

---

## CI / GitHub Actions

| Workflow | Trigger | What it does |
|---|---|---|
| `build-apps.yml` | Manual (`workflow_dispatch`) | Builds SWUs for each app on all models; uploads as Actions artifacts |
| `auto-release.yml` | Push a tag | Builds all apps (`build-all-swus.sh`), creates a GitHub draft release with all `app-*.swu` files attached |

To cut a release: push a git tag → GH Actions builds everything and creates a draft release automatically.
