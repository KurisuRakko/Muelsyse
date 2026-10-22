// SPDX-License-Identifier: MIT
/*
 * rakkord-sunshine-input-bridge
 * =============================
 *
 * Sunshine (Moonlight host) on Linux injects input exclusively through
 * libvirtualhid -> /dev/uinput -> kernel input devices -> libinput.
 *
 * This KWin session is started as `kwin_wayland --virtual`, whose output
 * backend provides no input backend: KWin never opens a single /dev/input
 * node, so events from those virtual devices are never delivered.  Sunshine
 * also never uses the xdg-desktop-portal input API (its portal backend only
 * sets up the ScreenCast/RemoteDesktop session and never calls
 * NotifyPointer / NotifyKeyboard), so that path cannot work either.
 *
 * The remaining way into the compositor is the privileged Wayland protocol
 * `org_kde_kwin_fake_input`, which KWin hides from clients unless their
 * executable is named by a .desktop file carrying
 * `X-KDE-Wayland-Interfaces=org_kde_kwin_fake_input` (see
 * src/wayland_server.cpp, KWinDisplay::allowInterface()).
 *
 * This program is that client: it reads the evdev nodes Sunshine creates
 * (name prefix "libvirtualhid ", e.g. "libvirtualhid Mouse"), translates them into fake_input
 * requests and flushes them to KWin.  libinput is not involved anywhere.
 *
 * Build: see Makefile.  Runtime dependencies: libwayland-client only.
 */

#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include <linux/input.h>

#include <wayland-client.h>

#include "fake-input-client-protocol.h"

#define DEVICE_NAME_PREFIX "libvirtualhid "
#define DEVICE_NAME_PREFIX_LEN (sizeof(DEVICE_NAME_PREFIX) - 1)

#define MAX_DEVICES 16
#define MAX_POLLFDS (MAX_DEVICES + 2)
#define MAX_OUTPUTS 4
#define MAX_REJECTED 32

/* evdev code ranges (linux/input-event-codes.h):
 *   KEY_*                       : 0x000 .. 0x0ff
 *   BTN_MISC / BTN_MOUSE..TASK  : 0x100 / 0x110 .. 0x117  (pointer buttons)
 *   BTN_JOYSTICK .. BTN_WHEEL   : 0x120 .. 0x15f  (gamepads etc., not ours)
 *   KEY_OK ..                   : 0x160 ..        (media/ACPI keys, keyboard) */
#define BTN_MOUSE_FIRST BTN_LEFT /* 0x110 */
#define BTN_MOUSE_LAST BTN_TASK  /* 0x117 */

#define RECONNECT_DELAY_MS 1000

/* ------------------------------------------------------------------ utils */

static volatile sig_atomic_t g_stop;
static bool g_trace;

static void on_signal(int sig)
{
    (void)sig;
    g_stop = 1;
}

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static void logmsg(const char *fmt, ...)
{
    va_list ap;
    fprintf(stderr, "[%8llu] ", (unsigned long long)now_ms());
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

/* --------------------------------------------------------------- wayland */

static struct wl_display *g_display;
static struct wl_registry *g_registry;
static struct org_kde_kwin_fake_input *g_fake_input;
static bool g_wl_need_flush;
static bool g_wl_eagain;

struct output {
    struct wl_output *wl;
    int mode_w, mode_h;
    bool have_mode;
    int scale;
};

static struct output g_outputs[MAX_OUTPUTS];
static int g_num_outputs;

static int g_forced_w; /* --width, --height: override auto detection */
static int g_forced_h;
static int g_last_w, g_last_h;

static void output_size(int *w, int *h)
{
    int best_w = 0, best_h = 0;

    if (g_forced_w > 0 && g_forced_h > 0) {
        *w = g_forced_w;
        *h = g_forced_h;
        return;
    }
    /* KWin's global coordinate space is in *logical* pixels, so
     * pointer_motion_absolute() wants logical coordinates: divide the
     * physical mode size by wl_output.scale. */
    for (int i = 0; i < g_num_outputs; i++) {
        if (g_outputs[i].have_mode) {
            int scale = g_outputs[i].scale > 0 ? g_outputs[i].scale : 1;
            best_w = g_outputs[i].mode_w / scale;
            best_h = g_outputs[i].mode_h / scale;
            break;
        }
    }
    if (best_w <= 0 || best_h <= 0) {
        best_w = 3840;
        best_h = 2160;
    }
    *w = best_w;
    *h = best_h;
}

static void maybe_log_output_size(void)
{
    int w, h;
    output_size(&w, &h);
    if (w == g_last_w && h == g_last_h)
        return;
    if (g_last_w != 0)
        logmsg("output (logical) size changed: %dx%d -> %dx%d", g_last_w, g_last_h, w, h);
    else
        logmsg("current output (logical) size: %dx%d", w, h);
    g_last_w = w;
    g_last_h = h;
}

static void output_geometry(void *data, struct wl_output *wl, int32_t x, int32_t y,
                            int32_t physical_width, int32_t physical_height, int32_t subpixel,
                            const char *make, const char *model, int32_t transform)
{
    (void)data; (void)wl; (void)x; (void)y; (void)physical_width; (void)physical_height;
    (void)subpixel; (void)make; (void)model; (void)transform;
}

static void output_mode(void *data, struct wl_output *wl, uint32_t flags,
                        int32_t width, int32_t height, int32_t refresh)
{
    struct output *out = data;
    (void)wl; (void)refresh;
    if (flags & WL_OUTPUT_MODE_CURRENT) {
        out->mode_w = width;
        out->mode_h = height;
        out->have_mode = true;
    }
}

static void output_done(void *data, struct wl_output *wl)
{
    (void)data; (void)wl;
    maybe_log_output_size();
}

static void output_scale(void *data, struct wl_output *wl, int32_t factor)
{
    struct output *out = data;
    (void)wl;
    if (factor > 0)
        out->scale = factor;
}

static void output_name(void *data, struct wl_output *wl, const char *name)
{
    (void)data; (void)wl; (void)name;
}

static void output_description(void *data, struct wl_output *wl, const char *description)
{
    (void)data; (void)wl; (void)description;
}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry,
    .mode = output_mode,
    .done = output_done,
    .scale = output_scale,
    .name = output_name,
    .description = output_description,
};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *interface, uint32_t version)
{
    (void)data;

    if (strcmp(interface, org_kde_kwin_fake_input_interface.name) == 0) {
        if (!g_fake_input) {
            uint32_t v = version < 5 ? version : 5;
            g_fake_input = wl_registry_bind(registry, name, &org_kde_kwin_fake_input_interface, v);
            logmsg("bound %s v%u (global name %u)", interface, v, name);
        }
    } else if (strcmp(interface, wl_output_interface.name) == 0 && g_num_outputs < MAX_OUTPUTS) {
        uint32_t v = version < 4 ? version : 4;
        struct output *out = &g_outputs[g_num_outputs++];
        memset(out, 0, sizeof(*out));
        out->scale = 1;
        out->wl = wl_registry_bind(registry, name, &wl_output_interface, v);
        wl_output_add_listener(out->wl, &output_listener, out);
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
    (void)data; (void)registry; (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static void wl_disconnect(void)
{
    if (g_fake_input) {
        org_kde_kwin_fake_input_destroy(g_fake_input);
        g_fake_input = NULL;
    }
    for (int i = 0; i < g_num_outputs; i++) {
        if (g_outputs[i].wl) {
            wl_output_destroy(g_outputs[i].wl);
            g_outputs[i].wl = NULL;
        }
    }
    g_num_outputs = 0;
    if (g_registry) {
        wl_registry_destroy(g_registry);
        g_registry = NULL;
    }
    if (g_display) {
        wl_display_flush(g_display);
        wl_display_disconnect(g_display);
        g_display = NULL;
    }
    g_wl_need_flush = false;
    g_wl_eagain = false;
}

/* Returns true when the privileged interface is bound and authenticated. */
static bool wl_connect(void)
{
    g_display = wl_display_connect(NULL);
    if (!g_display) {
        const char *d = getenv("WAYLAND_DISPLAY");
        logmsg("cannot connect to Wayland display '%s': %s", d ? d : "(default)", strerror(errno));
        return false;
    }
    g_registry = wl_display_get_registry(g_display);
    wl_registry_add_listener(g_registry, &registry_listener, NULL);
    if (wl_display_roundtrip(g_display) < 0) {
        logmsg("wayland roundtrip failed");
        wl_disconnect();
        return false;
    }
    /* Second roundtrip: pick up comments/mode events for objects created
     * during the first one. */
    wl_display_roundtrip(g_display);
    maybe_log_output_size();

    if (!g_fake_input) {
        logmsg("org_kde_kwin_fake_input is not exposed to this client "
               "(desktop file not indexed yet?) - retrying");
        wl_disconnect();
        return false;
    }

    org_kde_kwin_fake_input_authenticate(g_fake_input, "Sunshine Input Bridge",
                                         "Forward Sunshine/Moonlight virtual input devices");
    if (wl_display_flush(g_display) < 0 && errno != EAGAIN) {
        logmsg("failed to flush authentication request: %s", strerror(errno));
        wl_disconnect();
        return false;
    }
    logmsg("authenticated on org_kde_kwin_fake_input");
    return true;
}

/* ----------------------------------------------------------- evdev input */

struct dev {
    int fd;
    char path[64];
    bool is_pointer;
    bool is_keyboard;
    bool has_abs;
    bool has_hires_wheel;
    int abs_x_min, abs_x_max, abs_y_min, abs_y_max;
    /* pending state, flushed on SYN_REPORT */
    bool have_rel;
    double rel_dx, rel_dy;
    bool have_abs;
    double abs_raw_x, abs_raw_y;
    bool have_wheel;
    double wheel_v, wheel_h;
};

static struct dev g_devs[MAX_DEVICES];
static int g_num_devs;

static char g_rejected[MAX_REJECTED][64];
static int g_num_rejected;

static bool is_rejected(const char *path)
{
    for (int i = 0; i < g_num_rejected; i++)
        if (g_rejected[i][0] && strcmp(g_rejected[i], path) == 0)
            return true;
    return false;
}

static void add_rejected(const char *path)
{
    if (is_rejected(path) || g_num_rejected >= MAX_REJECTED)
        return;
    snprintf(g_rejected[g_num_rejected], sizeof(g_rejected[0]), "%s", path);
    g_num_rejected++;
}

static void forget_rejected(const char *path)
{
    for (int i = 0; i < g_num_rejected; i++)
        if (strcmp(g_rejected[i], path) == 0)
            g_rejected[i][0] = '\0';
}

static bool evdev_has(int fd, unsigned long ev, int code)
{
    unsigned long bits[(KEY_MAX / (8 * sizeof(unsigned long))) + 2];
    memset(bits, 0, sizeof(bits));
    if (ioctl(fd, EVIOCGBIT(ev, sizeof(bits) - 1), bits) < 0)
        return false;
    if (code < 0)
        return false;
    return (bits[code / (8 * (int)sizeof(unsigned long))] >>
            (code % (8 * (int)sizeof(unsigned long)))) & 1UL;
}

static void dev_close(struct dev *d)
{
    if (d->fd >= 0)
        close(d->fd);
    d->fd = -1;
}

/* Remove every device whose entry in @dead is set. */
static void dev_compact(const bool *dead)
{
    int w = 0;
    for (int i = 0; i < g_num_devs; i++) {
        if (dead[i]) {
            logmsg("detached %s", g_devs[i].path);
            dev_close(&g_devs[i]);
            continue;
        }
        if (w != i)
            g_devs[w] = g_devs[i];
        w++;
    }
    g_num_devs = w;
}

static void dev_open_all(void)
{
    DIR *dir = opendir("/dev/input");
    if (!dir)
        return;
    struct dirent *de;
    while ((de = readdir(dir))) {
        if (strncmp(de->d_name, "event", 5) != 0)
            continue;
        char path[64];
        if (snprintf(path, sizeof(path), "/dev/input/%s", de->d_name) >= (int)sizeof(path))
            continue;

        bool known = false;
        for (int i = 0; i < g_num_devs; i++)
            if (strcmp(g_devs[i].path, path) == 0)
                known = true;
        if (known || is_rejected(path))
            continue;

        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0)
            continue; /* looks like another (non Sunshine) device, or udev
                       * has not applied our ACL yet - retried on IN_ATTRIB */

        char name[256] = {0};
        if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) < 0) {
            close(fd);
            add_rejected(path);
            continue;
        }
        if (strncmp(name, DEVICE_NAME_PREFIX, DEVICE_NAME_PREFIX_LEN) != 0) {
            logmsg("ignoring %s ('%s')", path, name);
            close(fd);
            add_rejected(path);
            continue;
        }
        if (g_num_devs >= MAX_DEVICES) {
            logmsg("too many Sunshine devices, ignoring %s", path);
            close(fd);
            continue;
        }

        struct dev *d = &g_devs[g_num_devs++];
        memset(d, 0, sizeof(*d));
        d->fd = fd;
        snprintf(d->path, sizeof(d->path), "%s", path);
        d->is_pointer = evdev_has(fd, EV_KEY, BTN_LEFT);
        d->has_abs = evdev_has(fd, EV_ABS, ABS_X) && evdev_has(fd, EV_ABS, ABS_Y);
        d->has_hires_wheel = evdev_has(fd, EV_REL, REL_WHEEL_HI_RES);
        d->is_keyboard = evdev_has(fd, EV_KEY, KEY_A) || evdev_has(fd, EV_KEY, KEY_SPACE);

        d->abs_x_min = 0; d->abs_x_max = 32767;
        d->abs_y_min = 0; d->abs_y_max = 32767;
        if (d->has_abs) {
            /* EVIOCGABS also reports the axis' *current* value; use it as the
             * starting point.  The kernel drops EV_ABS events that do not
             * change the value, so the initial value matters: assuming
             * anything else (e.g. mid-range) would make the first motion
             * after the first one-axis update jump to a wrong coordinate. */
            struct input_absinfo ai;
            if (ioctl(fd, EVIOCGABS(ABS_X), &ai) == 0) {
                d->abs_x_min = ai.minimum;
                d->abs_x_max = ai.maximum;
                d->abs_raw_x = ai.value;
            }
            if (ioctl(fd, EVIOCGABS(ABS_Y), &ai) == 0) {
                d->abs_y_min = ai.minimum;
                d->abs_y_max = ai.maximum;
                d->abs_raw_y = ai.value;
            }
        }

        logmsg("attached %s '%s' [pointer=%d keyboard=%d abs=%d x:%d..%d y:%d..%d hires_wheel=%d]",
               path, name, d->is_pointer, d->is_keyboard, d->has_abs,
               d->abs_x_min, d->abs_x_max, d->abs_y_min, d->abs_y_max, d->has_hires_wheel);
    }
    closedir(dir);
}

/* ------------------------------------------------- conversion to wayland */

static void send_abs_motion(struct dev *d)
{
    int w, h;
    output_size(&w, &h);
    /* Same mapping as libinput's *_transformed(): the device range maps onto
     * [0, size).  wl_fixed carries enough precision for this. */
    double x = 0, y = 0;
    if (d->abs_x_max > d->abs_x_min) {
        x = (d->abs_raw_x - d->abs_x_min) / (double)(d->abs_x_max - d->abs_x_min) * w;
        x = x < 0 ? 0 : (x > w ? w : x);
    }
    if (d->abs_y_max > d->abs_y_min) {
        y = (d->abs_raw_y - d->abs_y_min) / (double)(d->abs_y_max - d->abs_y_min) * h;
        y = y < 0 ? 0 : (y > h ? h : y);
    }
    if (g_trace)
        logmsg("  -> pointer_motion_absolute(%.3f, %.3f)  [raw %.1f/%.1f, output %dx%d]",
               x, y, d->abs_raw_x, d->abs_raw_y, w, h);
    org_kde_kwin_fake_input_pointer_motion_absolute(g_fake_input,
                                                   wl_fixed_from_double(x),
                                                   wl_fixed_from_double(y));
    g_wl_need_flush = true;
}

static void flush_pending(struct dev *d)
{
    if (!g_fake_input) {
        d->have_rel = d->have_abs = d->have_wheel = false;
        return;
    }
    if (d->have_rel) {
        if (g_trace)
            logmsg("  -> pointer_motion(%g, %g)", d->rel_dx, d->rel_dy);
        org_kde_kwin_fake_input_pointer_motion(g_fake_input,
                                              wl_fixed_from_double(d->rel_dx),
                                              wl_fixed_from_double(d->rel_dy));
        d->have_rel = false;
        d->rel_dx = d->rel_dy = 0;
        g_wl_need_flush = true;
    }
    if (d->have_abs) {
        send_abs_motion(d);
        d->have_abs = false;
    }
    if (d->have_wheel) {
        if (d->wheel_v != 0) {
            if (g_trace)
                logmsg("  -> axis(vertical, %g)", d->wheel_v);
            org_kde_kwin_fake_input_axis(g_fake_input, WL_POINTER_AXIS_VERTICAL_SCROLL,
                                         wl_fixed_from_double(d->wheel_v));
        }
        if (d->wheel_h != 0) {
            if (g_trace)
                logmsg("  -> axis(horizontal, %g)", d->wheel_h);
            org_kde_kwin_fake_input_axis(g_fake_input, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
                                         wl_fixed_from_double(d->wheel_h));
        }
        d->wheel_v = d->wheel_h = 0;
        d->have_wheel = false;
        g_wl_need_flush = true;
    }
}

static void handle_event(struct dev *d, const struct input_event *ev)
{
    switch (ev->type) {
    case EV_REL:
        switch (ev->code) {
        case REL_X:
            d->rel_dx += ev->value;
            d->have_rel = true;
            break;
        case REL_Y:
            d->rel_dy += ev->value;
            d->have_rel = true;
            break;
        case REL_WHEEL:
            if (!d->has_hires_wheel) {
                d->wheel_v += ev->value;
                d->have_wheel = true;
            }
            break;
        case REL_HWHEEL:
            if (!d->has_hires_wheel) {
                d->wheel_h += ev->value;
                d->have_wheel = true;
            }
            break;
        case REL_WHEEL_HI_RES:
            d->wheel_v += ev->value / 120.0;
            d->have_wheel = true;
            break;
        case REL_HWHEEL_HI_RES:
            d->wheel_h += ev->value / 120.0;
            d->have_wheel = true;
            break;
        default:
            break;
        }
        break;
    case EV_ABS:
        if (ev->code == ABS_X) {
            d->abs_raw_x = ev->value;
            d->have_abs = true;
        } else if (ev->code == ABS_Y) {
            d->abs_raw_y = ev->value;
            d->have_abs = true;
        }
        break;
    case EV_KEY:
        if (ev->value == 2)
            break; /* autorepeat: KWin repeats on its own */
        if (!g_fake_input)
            break;
        if (ev->code >= BTN_MOUSE_FIRST && ev->code <= BTN_MOUSE_LAST) {
            if (g_trace)
                logmsg("  -> button(0x%x, %s)", ev->code, ev->value ? "pressed" : "released");
            org_kde_kwin_fake_input_button(g_fake_input, ev->code,
                                           ev->value ? WL_POINTER_BUTTON_STATE_PRESSED
                                                     : WL_POINTER_BUTTON_STATE_RELEASED);
            g_wl_need_flush = true;
        } else if (ev->code < BTN_MISC || ev->code >= KEY_OK) {
            /* Keyboard keys live below BTN_MISC (0x100) and at KEY_OK
             * (0x160) and above.  KWin wants the raw evdev code; it adds
             * the XKB evdev offset of 8 internally. */
            if (g_trace)
                logmsg("  -> keyboard_key(%d, %s)", ev->code, ev->value ? "pressed" : "released");
            org_kde_kwin_fake_input_keyboard_key(g_fake_input, ev->code,
                                                 ev->value ? WL_KEYBOARD_KEY_STATE_PRESSED
                                                           : WL_KEYBOARD_KEY_STATE_RELEASED);
            g_wl_need_flush = true;
        }
        /* 0x120..0x15f: gamepad buttons - unsupported by fake_input. */
        break;
    case EV_SYN:
        if (ev->code == SYN_REPORT)
            flush_pending(d);
        break;
    default:
        break;
    }
}

/* Returns false when the device disappeared. */
static bool dev_readable(struct dev *d)
{
    struct input_event evs[64];
    for (;;) {
        ssize_t n = read(d->fd, evs, sizeof(evs));
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
                return true;
            return false;
        }
        if (n == 0)
            return false;
        ssize_t count = n / (ssize_t)sizeof(struct input_event);
        for (ssize_t i = 0; i < count; i++)
            handle_event(d, &evs[i]);
    }
}

/* --------------------------------------------------------------- hotplug */

static int g_inotify_fd = -1;

static void hotplug_scan(void)
{
    bool dead[MAX_DEVICES];
    bool any = false;
    for (int i = 0; i < g_num_devs; i++) {
        dead[i] = access(g_devs[i].path, F_OK) != 0;
        any = any || dead[i];
    }
    if (any)
        dev_compact(dead);
    dev_open_all();
}

static void hotplug_events(void)
{
    char buf[8192] __attribute__((aligned(__alignof__(struct inotify_event))));
    for (;;) {
        ssize_t len = read(g_inotify_fd, buf, sizeof(buf));
        if (len <= 0)
            break;
        for (char *p = buf; p < buf + len;) {
            struct inotify_event *ie = (struct inotify_event *)p;
            if (ie->len > 0 && strncmp(ie->name, "event", 5) == 0 &&
                (ie->mask & (IN_DELETE | IN_MOVED_FROM))) {
                char path[64];
                snprintf(path, sizeof(path), "/dev/input/%s", ie->name);
                forget_rejected(path);
            }
            p += sizeof(struct inotify_event) + ie->len;
        }
    }
    hotplug_scan();
}

/* -------------------------------------------------------------- main loop */

static int parse_int_arg(const char *s)
{
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (end == s || v <= 0 || v > 100000)
        return -1;
    return (int)v;
}

int main(int argc, char **argv)
{
    setvbuf(stderr, NULL, _IOLBF, 0);

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--width") == 0 && i + 1 < argc) {
            g_forced_w = parse_int_arg(argv[++i]);
        } else if (strcmp(argv[i], "--height") == 0 && i + 1 < argc) {
            g_forced_h = parse_int_arg(argv[++i]);
        } else if (strcmp(argv[i], "--trace") == 0 || strcmp(argv[i], "-v") == 0) {
            g_trace = true;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("usage: %s [--width N] [--height N] [--trace]\n"
                   "  WAYLAND_DISPLAY selects the compositor socket.\n"
                   "  Without --width/--height the output size is taken from wl_output/xdg_output\n"
                   "  (logical pixels, i.e. what KWin's global coordinate space uses).\n",
                   argv[0]);
            return 0;
        } else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            return 2;
        }
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    g_inotify_fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (g_inotify_fd < 0) {
        logmsg("inotify_init1 failed: %s", strerror(errno));
        return 1;
    }
    inotify_add_watch(g_inotify_fd, "/dev/input",
                      IN_CREATE | IN_MOVED_TO | IN_ATTRIB | IN_DELETE | IN_DELETE_SELF);

    hotplug_scan();

    logmsg("started: display=%s prefix='%s'",
           getenv("WAYLAND_DISPLAY") ? getenv("WAYLAND_DISPLAY") : "(default)", DEVICE_NAME_PREFIX);

    bool connected = wl_connect();
    uint64_t next_reconnect = now_ms() + RECONNECT_DELAY_MS;

    while (!g_stop) {
        struct pollfd pfds[MAX_POLLFDS];
        int nfds = 0;

        pfds[nfds++] = (struct pollfd){ .fd = g_inotify_fd, .events = POLLIN };

        int display_fd = -1;
        int display_idx = -1;
        if (connected && g_display) {
            if (g_wl_need_flush) {
                int ret = wl_display_flush(g_display);
                if (ret < 0 && errno != EAGAIN) {
                    logmsg("wayland flush failed (%s), reconnecting", strerror(errno));
                    wl_disconnect();
                    connected = false;
                    next_reconnect = now_ms() + RECONNECT_DELAY_MS;
                } else {
                    g_wl_eagain = (ret < 0 && errno == EAGAIN);
                    g_wl_need_flush = false;
                }
            }
            if (connected && g_display) {
                display_fd = wl_display_get_fd(g_display);
                display_idx = nfds;
                pfds[nfds++] = (struct pollfd){
                    .fd = display_fd,
                    .events = POLLIN | (g_wl_eagain ? POLLOUT : 0),
                };
            }
        }

        int dev_base = nfds;
        int dev_of[MAX_DEVICES];
        int ndev_polled = 0;
        for (int i = 0; i < g_num_devs; i++) {
            if (g_devs[i].fd < 0)
                continue;
            dev_of[ndev_polled++] = i;
            pfds[nfds++] = (struct pollfd){ .fd = g_devs[i].fd, .events = POLLIN };
        }

        int timeout_ms = 1000;
        if (!connected) {
            uint64_t now = now_ms();
            timeout_ms = next_reconnect > now ? (int)(next_reconnect - now) : 0;
        }

        int n = poll(pfds, nfds, timeout_ms);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            logmsg("poll failed: %s", strerror(errno));
            break;
        }

        if (pfds[0].revents & POLLIN)
            hotplug_events();

        if (display_idx >= 0 && connected) {
            struct pollfd *p = &pfds[display_idx];
            if (p->revents & (POLLERR | POLLHUP | POLLNVAL)) {
                logmsg("compositor connection lost, reconnecting");
                wl_disconnect();
                connected = false;
                next_reconnect = now_ms() + RECONNECT_DELAY_MS;
            } else if (p->revents & (POLLIN | POLLOUT)) {
                if (p->revents & POLLOUT)
                    g_wl_need_flush = true;
                if (wl_display_dispatch(g_display) < 0) {
                    logmsg("wayland dispatch failed, reconnecting");
                    wl_disconnect();
                    connected = false;
                    next_reconnect = now_ms() + RECONNECT_DELAY_MS;
                }
            }
        }

        {
            bool dead[MAX_DEVICES] = { false };
            bool any = false;
            for (int k = 0; k < ndev_polled; k++) {
                int i = dev_of[k];
                struct pollfd *p = &pfds[dev_base + k];
                if (p->revents & (POLLERR | POLLHUP | POLLNVAL))
                    dead[i] = any = true;
                else if ((p->revents & POLLIN) && !dev_readable(&g_devs[i]))
                    dead[i] = any = true;
            }
            if (any)
                dev_compact(dead);
        }

        if (!connected && now_ms() >= next_reconnect) {
            connected = wl_connect();
            next_reconnect = now_ms() + RECONNECT_DELAY_MS;
        }
    }

    logmsg("shutting down");
    for (int i = 0; i < g_num_devs; i++)
        dev_close(&g_devs[i]);
    if (g_inotify_fd >= 0)
        close(g_inotify_fd);
    wl_disconnect();
    return 0;
}
