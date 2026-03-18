/*
 * fb-vnc-viewer - Framebuffer VNC viewer for embedded Linux
 *
 * Connects to a remote VNC server and renders the display to /dev/fb0.
 * Reads touch events from /dev/input/event0 and forwards them as VNC
 * pointer events. Designed for running KlipperScreen on a remote RPi
 * and displaying it on the printer's touchscreen.
 *
 * SPDX-License-Identifier: GPL-2.0+
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <rfb/rfbclient.h>

static volatile int running = 1;

/* Framebuffer state */
struct fb_state {
    int fd;
    uint8_t *mem;
    uint8_t *backbuf;  /* shadow buffer to avoid tearing */
    struct fb_var_screeninfo vinfo;
    struct fb_fix_screeninfo finfo;
    int width;
    int height;
    int bpp;       /* bytes per pixel */
    int stride;    /* line length in bytes */
    int dirty_min; /* first dirty row (inclusive), -1 = clean */
    int dirty_max; /* last dirty row (inclusive) */
};

/* Touch input state */
struct touch_state {
    int fd;
    int x;
    int y;
    int pressed;
    int slot;          /* current MT slot being tracked */
    /* Raw coordinate range from evdev */
    int abs_min_x;
    int abs_max_x;
    int abs_min_y;
    int abs_max_y;
};

/* Display transformation */
struct transform {
    int rotation;  /* 0, 90, 180, 270 */
    int fb_width;
    int fb_height;
    int vnc_width;
    int vnc_height;
};

/* Per-connection context stored via rfbClientSetClientData */
struct viewer_ctx {
    struct fb_state fb;
    struct touch_state touch;
    struct transform xform;
};

static rfbClient *vnc_client;

static void signal_handler(int sig)
{
    (void)sig;
    running = 0;
}

/* ── Framebuffer ─────────────────────────────────────────────── */

static int fb_open(struct fb_state *fb, const char *device)
{
    fb->fd = open(device, O_RDWR);
    if (fb->fd < 0) {
        perror("open framebuffer");
        return -1;
    }

    if (ioctl(fb->fd, FBIOGET_VSCREENINFO, &fb->vinfo) < 0) {
        perror("FBIOGET_VSCREENINFO");
        close(fb->fd);
        return -1;
    }

    if (ioctl(fb->fd, FBIOGET_FSCREENINFO, &fb->finfo) < 0) {
        perror("FBIOGET_FSCREENINFO");
        close(fb->fd);
        return -1;
    }

    fb->width = fb->vinfo.xres;
    fb->height = fb->vinfo.yres;
    fb->bpp = fb->vinfo.bits_per_pixel / 8;
    fb->stride = fb->finfo.line_length;

    size_t size = fb->stride * fb->height;
    fb->mem = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fb->fd, 0);
    if (fb->mem == MAP_FAILED) {
        perror("mmap framebuffer");
        close(fb->fd);
        return -1;
    }

    /* Allocate back buffer for tear-free rendering */
    fb->backbuf = calloc(1, size);
    if (!fb->backbuf) {
        perror("calloc backbuf");
        munmap(fb->mem, size);
        close(fb->fd);
        return -1;
    }

    fb->dirty_min = -1;
    fb->dirty_max = 0;

    fprintf(stderr, "fb: %dx%d %dbpp stride=%d\n",
            fb->width, fb->height, fb->bpp * 8, fb->stride);
    return 0;
}

static void fb_close(struct fb_state *fb)
{
    free(fb->backbuf);
    if (fb->mem && fb->mem != MAP_FAILED)
        munmap(fb->mem, fb->stride * fb->height);
    if (fb->fd >= 0)
        close(fb->fd);
}

/* Mark rows [y0..y1] dirty. */
static inline void fb_dirty(struct fb_state *fb, int y0, int y1)
{
    if (fb->dirty_min < 0 || y0 < fb->dirty_min)
        fb->dirty_min = y0;
    if (y1 > fb->dirty_max)
        fb->dirty_max = y1;
}

/* ── Touch input ─────────────────────────────────────────────── */

static int touch_open(struct touch_state *ts, const char *device)
{
    ts->fd = open(device, O_RDONLY | O_NONBLOCK);
    if (ts->fd < 0) {
        perror("open touch device");
        return -1;
    }

    /* Query the absolute axis ranges */
    struct input_absinfo abs;
    if (ioctl(ts->fd, EVIOCGABS(ABS_X), &abs) == 0) {
        ts->abs_min_x = abs.minimum;
        ts->abs_max_x = abs.maximum;
    } else if (ioctl(ts->fd, EVIOCGABS(ABS_MT_POSITION_X), &abs) == 0) {
        ts->abs_min_x = abs.minimum;
        ts->abs_max_x = abs.maximum;
    }

    if (ioctl(ts->fd, EVIOCGABS(ABS_Y), &abs) == 0) {
        ts->abs_min_y = abs.minimum;
        ts->abs_max_y = abs.maximum;
    } else if (ioctl(ts->fd, EVIOCGABS(ABS_MT_POSITION_Y), &abs) == 0) {
        ts->abs_min_y = abs.minimum;
        ts->abs_max_y = abs.maximum;
    }

    /* Grab the device to prevent conflict with LVGL */
    if (ioctl(ts->fd, EVIOCGRAB, 1) < 0)
        fprintf(stderr, "warning: could not grab touch device\n");

    fprintf(stderr, "touch: abs_x=[%d..%d] abs_y=[%d..%d]\n",
            ts->abs_min_x, ts->abs_max_x, ts->abs_min_y, ts->abs_max_y);
    ts->slot = 0;
    return 0;
}

static void touch_close(struct touch_state *ts)
{
    if (ts->fd >= 0) {
        ioctl(ts->fd, EVIOCGRAB, 0);
        close(ts->fd);
    }
}

/* ── Coordinate transforms ───────────────────────────────────── */

/*
 * Map raw evdev coordinates → VNC server coordinates, accounting for
 * display rotation. The VNC server (KlipperScreen) sees an unrotated
 * coordinate space of vnc_width × vnc_height.
 */
static void touch_to_vnc(struct transform *xf, struct touch_state *ts,
                          int raw_x, int raw_y, int *vnc_x, int *vnc_y)
{
    /* Normalize raw touch to 0.0–1.0 range */
    float nx = 0, ny = 0;
    if (ts->abs_max_x != ts->abs_min_x)
        nx = (float)(raw_x - ts->abs_min_x) / (ts->abs_max_x - ts->abs_min_x);
    if (ts->abs_max_y != ts->abs_min_y)
        ny = (float)(raw_y - ts->abs_min_y) / (ts->abs_max_y - ts->abs_min_y);

    /* Clamp */
    if (nx < 0) nx = 0;
    if (nx > 1) nx = 1;
    if (ny < 0) ny = 0;
    if (ny > 1) ny = 1;

    /* Apply rotation — maps touch position to VNC coordinate space */
    float fx, fy;
    switch (xf->rotation) {
    case 90:
        fx = ny;
        fy = 1.0f - nx;
        break;
    case 180:
        fx = 1.0f - nx;
        fy = 1.0f - ny;
        break;
    case 270:
        fx = 1.0f - ny;
        fy = nx;
        break;
    default: /* 0 */
        fx = nx;
        fy = ny;
        break;
    }

    *vnc_x = (int)(fx * xf->vnc_width);
    *vnc_y = (int)(fy * xf->vnc_height);
}

/*
 * Map VNC server pixel (sx, sy) → framebuffer pixel (fx, fy),
 * applying scaling and rotation.
 */
static void vnc_to_fb(struct transform *xf, int sx, int sy,
                       int *fx, int *fy)
{
    /* Scale from VNC resolution to fb "logical" size */
    float nx = (float)sx / xf->vnc_width;
    float ny = (float)sy / xf->vnc_height;

    int fw = xf->fb_width - 1;
    int fh = xf->fb_height - 1;

    switch (xf->rotation) {
    case 90:
        *fx = (int)((1.0f - ny) * fw);
        *fy = (int)(nx * fh);
        break;
    case 180:
        *fx = (int)((1.0f - nx) * fw);
        *fy = (int)((1.0f - ny) * fh);
        break;
    case 270:
        *fx = (int)(ny * fw);
        *fy = (int)((1.0f - nx) * fh);
        break;
    default: /* 0 */
        *fx = (int)(nx * fw);
        *fy = (int)(ny * fh);
        break;
    }
}

/* ── libvncclient callbacks ──────────────────────────────────── */

static rfbBool vnc_resize(rfbClient *cl)
{
    struct viewer_ctx *ctx = rfbClientGetClientData(cl, vnc_client);
    int w = cl->width;
    int h = cl->height;

    ctx->xform.vnc_width = w;
    ctx->xform.vnc_height = h;

    fprintf(stderr, "vnc: resize %dx%d\n", w, h);

    /* Allocate the client framebuffer — 32bpp RGBA */
    cl->format.bitsPerPixel = 32;
    cl->format.depth = 24;
    cl->format.redShift = 0;
    cl->format.greenShift = 8;
    cl->format.blueShift = 16;
    cl->format.redMax = 255;
    cl->format.greenMax = 255;
    cl->format.blueMax = 255;
    cl->format.bigEndian = FALSE;
    SetFormatAndEncodings(cl);

    if (cl->frameBuffer)
        free(cl->frameBuffer);
    cl->frameBuffer = malloc(w * h * 4);
    if (!cl->frameBuffer) {
        fprintf(stderr, "out of memory for VNC framebuffer\n");
        return FALSE;
    }
    memset(cl->frameBuffer, 0, w * h * 4);

    return TRUE;
}

static void vnc_update(rfbClient *cl, int x, int y, int w, int h)
{
    struct viewer_ctx *ctx = rfbClientGetClientData(cl, vnc_client);
    struct fb_state *fb = &ctx->fb;
    struct transform *xf = &ctx->xform;
    int vnc_w = cl->width;
    int fb_w = fb->width;
    int fb_h = fb->height;
    int bpp = fb->bpp;
    int stride = fb->stride;

    if (xf->rotation == 180 && xf->vnc_width == fb_w && xf->vnc_height == fb_h && bpp == 4) {
        /* Fast path: rotation=180, matching resolution, 32bpp.
         * VNC row sy maps to fb row (fb_h-1-sy), pixels reversed.
         * VNC format is RGB (src[0]=R, src[1]=G, src[2]=B).
         * FB format is BGRA: construct uint32 manually. */
        for (int sy = y; sy < y + h; sy++) {
            int fy = fb_h - 1 - sy;
            uint8_t *src_row = (uint8_t *)cl->frameBuffer + (sy * vnc_w + x) * 4;
            uint32_t *dst = (uint32_t *)(fb->backbuf + fy * stride);
            int fx_start = fb_w - 1 - x;
            for (int i = 0; i < w; i++) {
                uint8_t *s = src_row + i * 4;
                /* R=s[0], G=s[1], B=s[2] → BGRA = B,G,R,0xFF */
                dst[fx_start - i] = (uint32_t)s[2] | ((uint32_t)s[1] << 8)
                                  | ((uint32_t)s[0] << 16) | 0xFF000000u;
            }
            fb_dirty(fb, fy, fy);
        }
    } else {
        /* Generic path for all rotations / resolutions.
         * Inline vnc_to_fb + fb_put_pixel to avoid per-pixel function calls. */
        float inv_vw = 1.0f / xf->vnc_width;
        float inv_vh = 1.0f / xf->vnc_height;
        int fw = fb_w - 1;
        int fh = fb_h - 1;

        for (int sy = y; sy < y + h; sy++) {
            float ny = (float)sy * inv_vh;
            for (int sx = x; sx < x + w; sx++) {
                float nx = (float)sx * inv_vw;
                int fx, fy;

                switch (xf->rotation) {
                case 90:  fx = (int)((1.0f - ny) * fw); fy = (int)(nx * fh); break;
                case 180: fx = (int)((1.0f - nx) * fw); fy = (int)((1.0f - ny) * fh); break;
                case 270: fx = (int)(ny * fw); fy = (int)((1.0f - nx) * fh); break;
                default:  fx = (int)(nx * fw); fy = (int)(ny * fh); break;
                }

                if (fx >= 0 && fx < fb_w && fy >= 0 && fy < fb_h) {
                    uint8_t *src = (uint8_t *)cl->frameBuffer + (sy * vnc_w + sx) * 4;
                    uint8_t r = src[0], g = src[1], b = src[2];
                    uint8_t *p = fb->backbuf + fy * stride + fx * bpp;
                    if (bpp == 4) {
                        p[0] = b;
                        p[1] = g;
                        p[2] = r;
                        p[3] = 0xFF;
                    } else if (bpp == 2) {
                        uint16_t c = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
                        p[0] = c & 0xFF;
                        p[1] = c >> 8;
                    }
                    fb_dirty(fb, fy, fy);
                }
            }
        }
    }
}

/* Flush only dirty rows from back buffer to display */
static void fb_flip(struct fb_state *fb)
{
    if (fb->dirty_min < 0)
        return;  /* nothing changed */

    int y0 = fb->dirty_min;
    int y1 = fb->dirty_max;
    if (y1 >= fb->height)
        y1 = fb->height - 1;

    size_t off = y0 * fb->stride;
    size_t len = (y1 - y0 + 1) * fb->stride;
    memcpy(fb->mem + off, fb->backbuf + off, len);

    fb->dirty_min = -1;
    fb->dirty_max = 0;
}

/* Called once per frame after all rectangles are decoded. */
static void vnc_finished(rfbClient *cl)
{
    struct viewer_ctx *ctx = rfbClientGetClientData(cl, vnc_client);
    fb_flip(&ctx->fb);
}

/* ── Main ────────────────────────────────────────────────────── */

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [options] host[:port]\n"
        "\n"
        "Options:\n"
        "  -f <device>   Framebuffer device (default: /dev/fb0)\n"
        "  -t <device>   Touch input device (default: /dev/input/event0)\n"
        "  -r <degrees>  Display rotation: 0, 90, 180, 270 (default: 0)\n"
        "  -p <port>     VNC port (default: 5900)\n"
        "  -h            Show this help\n"
        "\n"
        "Environment:\n"
        "  VNC_HOST      VNC server hostname (alternative to positional arg)\n"
        "  VNC_PORT      VNC server port\n"
        "  VNC_PASSWORD  VNC password (if server requires authentication)\n"
        "  ROTATION      Display rotation in degrees\n",
        prog);
}

static char *vnc_get_password(rfbClient *cl)
{
    (void)cl;
    char *pw = getenv("VNC_PASSWORD");
    if (pw)
        return strdup(pw);
    return strdup("");
}

int main(int argc, char **argv)
{
    const char *fb_device = "/dev/fb0";
    const char *touch_device = "/dev/input/event0";
    const char *vnc_host = NULL;
    int vnc_port = 5900;
    int rotation = 0;
    int opt;

    /* Environment defaults */
    char *env;
    if ((env = getenv("VNC_HOST")) != NULL)
        vnc_host = env;
    if ((env = getenv("VNC_PORT")) != NULL)
        vnc_port = atoi(env);
    if ((env = getenv("ROTATION")) != NULL)
        rotation = atoi(env);

    while ((opt = getopt(argc, argv, "f:t:r:p:h")) != -1) {
        switch (opt) {
        case 'f': fb_device = optarg; break;
        case 't': touch_device = optarg; break;
        case 'r': rotation = atoi(optarg); break;
        case 'p': vnc_port = atoi(optarg); break;
        case 'h': usage(argv[0]); return 0;
        default: usage(argv[0]); return 1;
        }
    }

    if (optind < argc) {
        vnc_host = argv[optind];
        /* Parse host:port */
        char *colon = strrchr((char *)vnc_host, ':');
        if (colon) {
            *colon = '\0';
            vnc_port = atoi(colon + 1);
        }
    }

    if (!vnc_host) {
        fprintf(stderr, "Error: VNC host not specified\n");
        usage(argv[0]);
        return 1;
    }

    if (vnc_port < 1 || vnc_port > 65535) {
        fprintf(stderr, "Error: invalid port %d\n", vnc_port);
        return 1;
    }

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    /* Initialize viewer context */
    struct viewer_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.fb.fd = -1;
    ctx.touch.fd = -1;
    ctx.xform.rotation = rotation;

    /* Open framebuffer */
    if (fb_open(&ctx.fb, fb_device) < 0)
        return 1;

    ctx.xform.fb_width = ctx.fb.width;
    ctx.xform.fb_height = ctx.fb.height;

    /* Clear screen and back buffer */
    memset(ctx.fb.mem, 0, ctx.fb.stride * ctx.fb.height);
    memset(ctx.fb.backbuf, 0, ctx.fb.stride * ctx.fb.height);

    /* Open touch */
    int have_touch = (touch_open(&ctx.touch, touch_device) == 0);

    /* If ABS ranges are zero (driver quirk or grab failure), fall back to
     * framebuffer dimensions — fts_ts is a direct-touch device so its
     * coordinate space matches the screen resolution exactly. */
    if (have_touch && ctx.touch.abs_max_x == ctx.touch.abs_min_x) {
        ctx.touch.abs_min_x = 0;
        ctx.touch.abs_max_x = ctx.fb.width - 1;
        fprintf(stderr, "touch: ABS_X range was zero, using fb width %d\n",
                ctx.fb.width);
    }
    if (have_touch && ctx.touch.abs_max_y == ctx.touch.abs_min_y) {
        ctx.touch.abs_min_y = 0;
        ctx.touch.abs_max_y = ctx.fb.height - 1;
        fprintf(stderr, "touch: ABS_Y range was zero, using fb height %d\n",
                ctx.fb.height);
    }

    /* Create VNC client — 32bpp, request Raw + ZRLE encodings */
    vnc_client = rfbGetClient(8, 3, 4);
    if (!vnc_client) {
        fprintf(stderr, "rfbGetClient failed\n");
        fb_close(&ctx.fb);
        return 1;
    }

    vnc_client->MallocFrameBuffer = vnc_resize;
    vnc_client->GotFrameBufferUpdate = vnc_update;
    vnc_client->FinishedFrameBufferUpdate = vnc_finished;
    vnc_client->GetPassword = vnc_get_password;
    vnc_client->canHandleNewFBSize = TRUE;

    rfbClientSetClientData(vnc_client, vnc_client, &ctx);

    /* Connect */
    vnc_client->serverHost = strdup(vnc_host);
    vnc_client->serverPort = vnc_port;

    if (!rfbInitClient(vnc_client, NULL, NULL)) {
        fprintf(stderr, "Failed to connect to %s:%d\n", vnc_host, vnc_port);
        fb_close(&ctx.fb);
        if (have_touch)
            touch_close(&ctx.touch);
        return 1;
    }

    fprintf(stderr, "Connected to %s:%d (%dx%d), rotation=%d\n",
            vnc_host, vnc_port,
            vnc_client->width, vnc_client->height, rotation);

    /* Main loop */
    while (running) {
        fd_set fds;
        struct timeval tv;
        int maxfd = vnc_client->sock;

        FD_ZERO(&fds);
        FD_SET(vnc_client->sock, &fds);

        if (have_touch && ctx.touch.fd >= 0) {
            FD_SET(ctx.touch.fd, &fds);
            if (ctx.touch.fd > maxfd)
                maxfd = ctx.touch.fd;
        }

        tv.tv_sec = 0;
        tv.tv_usec = 50000; /* 50ms = ~20 polls/sec */

        int ret = select(maxfd + 1, &fds, NULL, NULL, &tv);
        if (ret < 0) {
            if (errno == EINTR)
                continue;
            perror("select");
            break;
        }

        /* Handle VNC data */
        if (FD_ISSET(vnc_client->sock, &fds)) {
            if (!HandleRFBServerMessage(vnc_client)) {
                fprintf(stderr, "VNC connection lost\n");
                break;
            }
        }

        /* Handle touch events */
        if (have_touch && ctx.touch.fd >= 0 && FD_ISSET(ctx.touch.fd, &fds)) {
            struct input_event ev;
            while (read(ctx.touch.fd, &ev, sizeof(ev)) == sizeof(ev)) {
                if (ev.type == EV_ABS) {
                    if (ev.code == ABS_MT_SLOT) {
                        /* Protocol B: subsequent MT events belong to this slot.
                         * We only track slot 0 (first finger). */
                        ctx.touch.slot = ev.value;
                    } else if (ctx.touch.slot == 0) {
                        /* Only process events for slot 0 */
                        if (ev.code == ABS_X || ev.code == ABS_MT_POSITION_X)
                            ctx.touch.x = ev.value;
                        else if (ev.code == ABS_Y || ev.code == ABS_MT_POSITION_Y)
                            ctx.touch.y = ev.value;
                        else if (ev.code == ABS_MT_TRACKING_ID) {
                            /* Protocol B: tracking_id >= 0 means finger down,
                             * -1 means finger lifted. */
                            ctx.touch.pressed = (ev.value != -1) ? 1 : 0;
                        }
                    }
                } else if (ev.type == EV_KEY && ev.code == BTN_TOUCH) {
                    /* Protocol A fallback: some drivers still use BTN_TOUCH */
                    ctx.touch.pressed = ev.value;
                } else if (ev.type == EV_SYN && ev.code == SYN_REPORT) {
                    /* Send pointer event to VNC server */
                    int vx, vy;
                    touch_to_vnc(&ctx.xform, &ctx.touch,
                                 ctx.touch.x, ctx.touch.y, &vx, &vy);
                    SendPointerEvent(vnc_client, vx, vy,
                                     ctx.touch.pressed ? rfbButton1Mask : 0);
                }
            }
        }

        /* Request incremental update */
        SendFramebufferUpdateRequest(vnc_client, 0, 0,
                                     vnc_client->width, vnc_client->height,
                                     TRUE);
    }

    fprintf(stderr, "Shutting down\n");
    rfbClientCleanup(vnc_client);
    if (have_touch)
        touch_close(&ctx.touch);
    fb_close(&ctx.fb);

    return 0;
}
