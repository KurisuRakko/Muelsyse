// SPDX-License-Identifier: MIT
/*
 * muelsyse-drop-helper
 * ====================
 *
 * Files dropped onto the browser's remote-desktop view arrive on the host as
 * plain paths.  To place them where the user let go, this helper replays a
 * real Wayland drag-and-drop inside the KWin session and lets the drop target
 * (normally the Plasma desktop containment, but any window works) do the
 * copy and placement itself -- the same idea as VMware Tools' dndcp:
 *
 *   1. map a tiny zwlr_layer_shell_v1 overlay surface next to the drop point
 *   2. org_kde_kwin_fake_input: move the pointer onto it and press BTN_LEFT
 *   3. take the serial from our own wl_pointer.button event and call
 *      wl_data_device.start_drag() with a source offering text/uri-list
 *   4. fake_input: move the pointer to the drop point, hold Ctrl and release.
 *      Ctrl makes KIO copy straight away instead of popping up its
 *      Copy/Move/Link menu.
 *
 * Usage: muelsyse-drop-helper [--output NAME] [--verbose] X Y PATH...
 *
 * X/Y are framebuffer pixels of the streamed output (what the browser shows,
 * top-left 0,0, fractions allowed).  They are converted to KWin's global
 * logical coordinates with wl_output (mode, transform, name) and
 * zxdg_output_v1 (logical position and size).
 *
 * Exit status: 0 the target accepted the drop (dnd_finished), 2 the target
 * rejected it (cancelled), 1 anything else (no compositor, not authorised,
 * bad arguments, timeout, SIGTERM/SIGINT/SIGHUP).  One summary line goes to
 * stderr.  Whatever ends the drag, the fake Ctrl and BTN_LEFT are released
 * before exit, waiting at most RELEASE_FLUSH_MS for the compositor.
 *
 * fake_input is a restricted interface: the binary must be named by the Exec=
 * of a .desktop file carrying X-KDE-Wayland-Interfaces=org_kde_kwin_fake_input.
 *
 * Build: see Makefile.  Runtime dependencies: libwayland-client only.
 */

#define _GNU_SOURCE

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
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <linux/input-event-codes.h>

#include <wayland-client.h>

#include "fake-input-client-protocol.h"
#include "kde-output-order-v1-client-protocol.h"
#include "wlr-layer-shell-client-protocol.h"
#include "xdg-output-client-protocol.h"

#define PROGRAM "muelsyse-drop-helper"

#define EXIT_DROPPED 0
#define EXIT_FAILED 1
#define EXIT_REJECTED 2

#define TOTAL_TIMEOUT_MS 10000
#define LOCK_WAIT_MS 5000
#define RELEASE_FLUSH_MS 1000
#define LOCK_NAME "muelsyse-drop-helper.lock"

#define MAX_OUTPUTS 8
#define SURFACE_SIZE 8 /* logical px */
#define SURFACE_GAP 16 /* surface sits this far up-left of the drop point */
#define ENTER_ATTEMPTS 4
#define GLIDE_STEPS 10

/* ------------------------------------------------------------------ utils */

static volatile sig_atomic_t g_stop;
static bool g_verbose;
static uint64_t g_deadline;

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

static int ms_left(void)
{
    uint64_t now = now_ms();
    return now >= g_deadline ? 0 : (int)(g_deadline - now);
}

/* Protocol trace, only with --verbose. */
static void trace(const char *fmt, ...)
{
    va_list ap;
    if (!g_verbose)
        return;
    fprintf(stderr, "[%8llu] ", (unsigned long long)now_ms());
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

/* The one-line result summary; every exit path prints exactly one. */
static int finish(int status, const char *fmt, ...)
{
    va_list ap;
    fprintf(stderr, PROGRAM ": ");
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    return status;
}

/* --------------------------------------------------------------- wayland */

static struct wl_display *g_display;
static struct wl_registry *g_registry;
static struct wl_compositor *g_compositor;
static struct wl_shm *g_shm;
static struct wl_seat *g_seat;
static struct wl_pointer *g_pointer;
static struct wl_data_device_manager *g_ddm;
static uint32_t g_ddm_version;
static struct zwlr_layer_shell_v1 *g_layer_shell;
static struct zxdg_output_manager_v1 *g_xdg_output_manager;
static struct kde_output_order_v1 *g_output_order;
static struct org_kde_kwin_fake_input *g_fake_input;
static uint32_t g_fake_input_version;

struct output {
    struct wl_output *wl;
    struct zxdg_output_v1 *xdg;
    char name[64];
    int mode_w, mode_h;
    bool have_mode;
    int32_t transform;
    int geo_x, geo_y;
    int scale;
    int log_x, log_y, log_w, log_h;
    bool have_logical;
};

static struct output g_outputs[MAX_OUTPUTS];
static int g_num_outputs;
static char g_primary_name[64]; /* first entry of kde_output_order_v1 */
static bool g_order_started;

/* Pixel size of the output's framebuffer, i.e. the mode after rotation. */
static void output_physical_size(const struct output *out, double *w, double *h)
{
    bool rotated = out->transform & 1; /* 90, 270 and their flipped variants */
    *w = rotated ? out->mode_h : out->mode_w;
    *h = rotated ? out->mode_w : out->mode_h;
}

/* Logical geometry; falls back to wl_output data if xdg_output said nothing. */
static void output_logical_rect(const struct output *out, double *x, double *y, double *w, double *h)
{
    if (out->have_logical) {
        *x = out->log_x;
        *y = out->log_y;
        *w = out->log_w;
        *h = out->log_h;
        return;
    }
    double pw, ph;
    output_physical_size(out, &pw, &ph);
    *x = out->geo_x;
    *y = out->geo_y;
    *w = pw / (out->scale > 0 ? out->scale : 1);
    *h = ph / (out->scale > 0 ? out->scale : 1);
}

static void output_geometry(void *data, struct wl_output *wl, int32_t x, int32_t y,
                            int32_t physical_width, int32_t physical_height, int32_t subpixel,
                            const char *make, const char *model, int32_t transform)
{
    struct output *out = data;
    (void)wl; (void)physical_width; (void)physical_height; (void)subpixel; (void)make; (void)model;
    out->geo_x = x;
    out->geo_y = y;
    out->transform = transform;
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
    struct output *out = data;
    (void)wl;
    snprintf(out->name, sizeof(out->name), "%s", name);
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

static void xdg_output_logical_position(void *data, struct zxdg_output_v1 *xdg, int32_t x, int32_t y)
{
    struct output *out = data;
    (void)xdg;
    out->log_x = x;
    out->log_y = y;
}

static void xdg_output_logical_size(void *data, struct zxdg_output_v1 *xdg, int32_t width, int32_t height)
{
    struct output *out = data;
    (void)xdg;
    out->log_w = width;
    out->log_h = height;
    out->have_logical = width > 0 && height > 0;
}

static void xdg_output_done(void *data, struct zxdg_output_v1 *xdg)
{
    (void)data; (void)xdg;
}

static void xdg_output_name(void *data, struct zxdg_output_v1 *xdg, const char *name)
{
    struct output *out = data;
    (void)xdg;
    if (!out->name[0])
        snprintf(out->name, sizeof(out->name), "%s", name);
}

static void xdg_output_description(void *data, struct zxdg_output_v1 *xdg, const char *description)
{
    (void)data; (void)xdg; (void)description;
}

static const struct zxdg_output_v1_listener xdg_output_listener = {
    .logical_position = xdg_output_logical_position,
    .logical_size = xdg_output_logical_size,
    .done = xdg_output_done,
    .name = xdg_output_name,
    .description = xdg_output_description,
};

/* KWin lists outputs in its configured order; the first one is the primary. */
static void output_order_output(void *data, struct kde_output_order_v1 *order, const char *name)
{
    (void)data; (void)order;
    if (!g_order_started) {
        snprintf(g_primary_name, sizeof(g_primary_name), "%s", name);
        g_order_started = true;
    }
}

static void output_order_done(void *data, struct kde_output_order_v1 *order)
{
    (void)data; (void)order;
    g_order_started = false;
}

static const struct kde_output_order_v1_listener output_order_listener = {
    .output = output_order_output,
    .done = output_order_done,
};

/* ------------------------------------------------------------ input state */

static struct wl_surface *g_surface;
static struct zwlr_layer_surface_v1 *g_layer_surface;
static bool g_configured;
static bool g_layer_closed;

static bool g_pointer_in_surface;
static uint32_t g_press_serial;
static bool g_have_press_serial;
static bool g_button_down; /* a fake BTN_LEFT press is not released yet */
static bool g_ctrl_down;   /* a fake KEY_LEFTCTRL press is not released yet */

static void pointer_enter(void *data, struct wl_pointer *pointer, uint32_t serial,
                          struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y)
{
    (void)data; (void)pointer;
    if (surface == g_surface)
        g_pointer_in_surface = true;
    trace("wl_pointer.enter serial=%u ours=%d at %.1f,%.1f", serial, surface == g_surface,
          wl_fixed_to_double(x), wl_fixed_to_double(y));
}

static void pointer_leave(void *data, struct wl_pointer *pointer, uint32_t serial,
                          struct wl_surface *surface)
{
    (void)data; (void)pointer;
    if (surface == g_surface)
        g_pointer_in_surface = false;
    trace("wl_pointer.leave serial=%u", serial);
}

static void pointer_motion(void *data, struct wl_pointer *pointer, uint32_t time,
                           wl_fixed_t x, wl_fixed_t y)
{
    (void)data; (void)pointer; (void)time; (void)x; (void)y;
}

static void pointer_button(void *data, struct wl_pointer *pointer, uint32_t serial,
                           uint32_t time, uint32_t button, uint32_t state)
{
    (void)data; (void)pointer; (void)time;
    trace("wl_pointer.button serial=%u button=0x%x state=%u", serial, button, state);
    if (button == BTN_LEFT && state == WL_POINTER_BUTTON_STATE_PRESSED && g_pointer_in_surface) {
        g_press_serial = serial;
        g_have_press_serial = true;
    }
}

static void pointer_axis(void *data, struct wl_pointer *pointer, uint32_t time,
                         uint32_t axis, wl_fixed_t value)
{
    (void)data; (void)pointer; (void)time; (void)axis; (void)value;
}

static void pointer_frame(void *data, struct wl_pointer *pointer)
{
    (void)data; (void)pointer;
}

static void pointer_axis_source(void *data, struct wl_pointer *pointer, uint32_t source)
{
    (void)data; (void)pointer; (void)source;
}

static void pointer_axis_stop(void *data, struct wl_pointer *pointer, uint32_t time, uint32_t axis)
{
    (void)data; (void)pointer; (void)time; (void)axis;
}

static void pointer_axis_discrete(void *data, struct wl_pointer *pointer, uint32_t axis, int32_t discrete)
{
    (void)data; (void)pointer; (void)axis; (void)discrete;
}

static const struct wl_pointer_listener pointer_listener = {
    .enter = pointer_enter,
    .leave = pointer_leave,
    .motion = pointer_motion,
    .button = pointer_button,
    .axis = pointer_axis,
    .frame = pointer_frame,
    .axis_source = pointer_axis_source,
    .axis_stop = pointer_axis_stop,
    .axis_discrete = pointer_axis_discrete,
};

static void seat_capabilities(void *data, struct wl_seat *seat, uint32_t caps)
{
    (void)data;
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !g_pointer) {
        g_pointer = wl_seat_get_pointer(seat);
        wl_pointer_add_listener(g_pointer, &pointer_listener, NULL);
    }
}

static void seat_name(void *data, struct wl_seat *seat, const char *name)
{
    (void)data; (void)seat; (void)name;
}

static const struct wl_seat_listener seat_listener = {
    .capabilities = seat_capabilities,
    .name = seat_name,
};

/* --------------------------------------------------------------- registry */

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *interface, uint32_t version)
{
    (void)data;

    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        g_compositor = wl_registry_bind(registry, name, &wl_compositor_interface, version < 4 ? version : 4);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        g_shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, wl_seat_interface.name) == 0 && !g_seat) {
        g_seat = wl_registry_bind(registry, name, &wl_seat_interface, version < 5 ? version : 5);
        wl_seat_add_listener(g_seat, &seat_listener, NULL);
    } else if (strcmp(interface, wl_data_device_manager_interface.name) == 0) {
        g_ddm_version = version < 3 ? version : 3;
        g_ddm = wl_registry_bind(registry, name, &wl_data_device_manager_interface, g_ddm_version);
    } else if (strcmp(interface, zwlr_layer_shell_v1_interface.name) == 0) {
        g_layer_shell = wl_registry_bind(registry, name, &zwlr_layer_shell_v1_interface, version < 4 ? version : 4);
    } else if (strcmp(interface, zxdg_output_manager_v1_interface.name) == 0) {
        g_xdg_output_manager = wl_registry_bind(registry, name, &zxdg_output_manager_v1_interface,
                                                version < 3 ? version : 3);
    } else if (strcmp(interface, kde_output_order_v1_interface.name) == 0) {
        g_output_order = wl_registry_bind(registry, name, &kde_output_order_v1_interface, 1);
        kde_output_order_v1_add_listener(g_output_order, &output_order_listener, NULL);
    } else if (strcmp(interface, org_kde_kwin_fake_input_interface.name) == 0 && !g_fake_input) {
        g_fake_input_version = version < 4 ? version : 4;
        g_fake_input = wl_registry_bind(registry, name, &org_kde_kwin_fake_input_interface, g_fake_input_version);
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

/* Dispatch events until `end` (a now_ms() stamp) or until *flag becomes true,
 * flushing queued requests as the socket accepts them.  With `stoppable`, a
 * signal ends the wait early.  Returns -1 on a protocol/socket error or a
 * stop, else 0. */
static int dispatch_until(uint64_t end, const bool *flag, bool stoppable)
{
    for (;;) {
        if (flag && *flag)
            return 0;
        if (stoppable && g_stop)
            return -1;
        while (wl_display_prepare_read(g_display) != 0) {
            if (wl_display_dispatch_pending(g_display) < 0)
                return -1;
        }
        short events = POLLIN;
        if (wl_display_flush(g_display) < 0) {
            if (errno != EAGAIN) {
                wl_display_cancel_read(g_display);
                return -1;
            }
            events |= POLLOUT;
        }
        uint64_t now = now_ms();
        if (now >= end) {
            wl_display_cancel_read(g_display);
            return 0;
        }
        struct pollfd pfd = { .fd = wl_display_get_fd(g_display), .events = events };
        if (poll(&pfd, 1, (int)(end - now)) > 0 && (pfd.revents & (POLLIN | POLLERR | POLLHUP))) {
            if (wl_display_read_events(g_display) < 0)
                return -1;
        } else {
            wl_display_cancel_read(g_display);
        }
        if (wl_display_dispatch_pending(g_display) < 0)
            return -1;
    }
}

/* Dispatch events for up to `ms` milliseconds (capped by the global deadline),
 * returning early once *flag becomes true.  Returns -1 on a protocol/socket
 * error or when a signal asked us to stop. */
static int pump(int ms, const bool *flag)
{
    uint64_t end = now_ms() + (uint64_t)(ms > 0 ? ms : 0);
    if (end > g_deadline)
        end = g_deadline;
    return dispatch_until(end, flag, true);
}

static void sync_done(void *data, struct wl_callback *callback, uint32_t serial)
{
    (void)serial;
    if (data)
        *(bool *)data = true;
    wl_callback_destroy(callback);
}

static const struct wl_callback_listener sync_listener = {
    .done = sync_done,
};

/* wl_display_roundtrip() that gives up after `ms`: libwayland's own retries
 * poll() on EINTR and would wait out a stalled compositor past any signal.
 * Returns 0 once the compositor has processed every request sent so far. */
static int roundtrip_within(int ms, bool stoppable)
{
    bool done = false;
    struct wl_callback *callback = wl_display_sync(g_display);
    wl_callback_add_listener(callback, &sync_listener, &done);
    dispatch_until(now_ms() + (uint64_t)(ms > 0 ? ms : 0), &done, stoppable);
    if (!done)
        wl_callback_set_user_data(callback, NULL); /* `done` dies with this frame */
    return done ? 0 : -1;
}

/* ------------------------------------------------------------- fake input */

static void fake_move(double x, double y)
{
    org_kde_kwin_fake_input_pointer_motion_absolute(g_fake_input, wl_fixed_from_double(x),
                                                    wl_fixed_from_double(y));
    wl_display_flush(g_display);
}

static void fake_button(bool down)
{
    org_kde_kwin_fake_input_button(g_fake_input, BTN_LEFT,
                                   down ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    g_button_down = down;
    wl_display_flush(g_display);
    trace("fake_input BTN_LEFT %s", down ? "press" : "release");
}

static void fake_ctrl(bool down)
{
    org_kde_kwin_fake_input_keyboard_key(g_fake_input, KEY_LEFTCTRL,
                                         down ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
    g_ctrl_down = down;
    wl_display_flush(g_display);
    trace("fake_input KEY_LEFTCTRL %s", down ? "press" : "release");
}

/* Every exit path after the press goes through here, so the session never
 * keeps a stuck button or modifier.  It runs after a signal too, and waits at
 * most RELEASE_FLUSH_MS for the compositor to take the releases. */
static void release_held_input(void)
{
    if (!g_display || !g_fake_input)
        return;
    if (g_ctrl_down)
        fake_ctrl(false);
    if (g_button_down)
        fake_button(false);
    roundtrip_within(RELEASE_FLUSH_MS, false);
}

/* ------------------------------------------------------------ data source */

static char *g_uri_list;
static bool g_drag_done;
static bool g_drag_finished; /* dnd_finished (accepted) as opposed to cancelled */
static uint32_t g_drag_action;

static void source_target(void *data, struct wl_data_source *source, const char *mime_type)
{
    (void)data; (void)source;
    trace("data_source.target %s", mime_type ? mime_type : "(none)");
}

/* The payload is a few hundred bytes, but never block past the deadline on a
 * target that stops reading. */
static void source_send(void *data, struct wl_data_source *source, const char *mime_type, int32_t fd)
{
    (void)data; (void)source;
    trace("data_source.send %s", mime_type);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    size_t len = strlen(g_uri_list), off = 0;
    while (off < len) {
        ssize_t n = write(fd, g_uri_list + off, len - off);
        if (n >= 0) {
            off += (size_t)n;
            continue;
        }
        if (errno == EINTR)
            continue;
        if (errno != EAGAIN) {
            trace("data_source.send write: %s", strerror(errno));
            break;
        }
        struct pollfd pfd = { .fd = fd, .events = POLLOUT };
        if (poll(&pfd, 1, ms_left()) <= 0)
            break;
    }
    close(fd);
}

static void source_cancelled(void *data, struct wl_data_source *source)
{
    (void)data; (void)source;
    trace("data_source.cancelled");
    g_drag_done = true;
}

static void source_dnd_drop_performed(void *data, struct wl_data_source *source)
{
    (void)data; (void)source;
    trace("data_source.dnd_drop_performed");
}

static void source_dnd_finished(void *data, struct wl_data_source *source)
{
    (void)data; (void)source;
    trace("data_source.dnd_finished");
    g_drag_finished = true;
    g_drag_done = true;
}

static void source_action(void *data, struct wl_data_source *source, uint32_t dnd_action)
{
    (void)data; (void)source;
    trace("data_source.action %u", dnd_action);
    g_drag_action = dnd_action;
}

static const struct wl_data_source_listener source_listener = {
    .target = source_target,
    .send = source_send,
    .cancelled = source_cancelled,
    .dnd_drop_performed = source_dnd_drop_performed,
    .dnd_finished = source_dnd_finished,
    .action = source_action,
};

/* As the drag source we still get wl_data_device events for our own surface;
 * none of them matter. */
static void data_device_data_offer(void *data, struct wl_data_device *device, struct wl_data_offer *offer)
{
    (void)data; (void)device;
    wl_data_offer_destroy(offer);
}

static void data_device_enter(void *data, struct wl_data_device *device, uint32_t serial,
                              struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y,
                              struct wl_data_offer *offer)
{
    (void)data; (void)device; (void)serial; (void)surface; (void)x; (void)y; (void)offer;
}

static void data_device_leave(void *data, struct wl_data_device *device)
{
    (void)data; (void)device;
}

static void data_device_motion(void *data, struct wl_data_device *device, uint32_t time,
                               wl_fixed_t x, wl_fixed_t y)
{
    (void)data; (void)device; (void)time; (void)x; (void)y;
}

static void data_device_drop(void *data, struct wl_data_device *device)
{
    (void)data; (void)device;
}

static void data_device_selection(void *data, struct wl_data_device *device, struct wl_data_offer *offer)
{
    (void)data; (void)device; (void)offer;
}

static const struct wl_data_device_listener data_device_listener = {
    .data_offer = data_device_data_offer,
    .enter = data_device_enter,
    .leave = data_device_leave,
    .motion = data_device_motion,
    .drop = data_device_drop,
    .selection = data_device_selection,
};

/* ---------------------------------------------------------- layer surface */

static void layer_surface_configure(void *data, struct zwlr_layer_surface_v1 *layer_surface,
                                    uint32_t serial, uint32_t width, uint32_t height)
{
    (void)data;
    trace("layer_surface.configure %ux%u", width, height);
    zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
    g_configured = true;
}

static void layer_surface_closed(void *data, struct zwlr_layer_surface_v1 *layer_surface)
{
    (void)data; (void)layer_surface;
    trace("layer_surface.closed");
    g_layer_closed = true;
}

static const struct zwlr_layer_surface_v1_listener layer_surface_listener = {
    .configure = layer_surface_configure,
    .closed = layer_surface_closed,
};

/* A nearly transparent buffer; the alpha is non-zero so KWin treats the
 * surface as a real input target. */
static struct wl_buffer *create_buffer(int w, int h)
{
    int stride = w * 4, size = stride * h;
    int fd = memfd_create(PROGRAM, MFD_CLOEXEC);
    if (fd < 0)
        return NULL;
    if (ftruncate(fd, size) < 0) {
        close(fd);
        return NULL;
    }
    uint32_t *px = mmap(NULL, (size_t)size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) {
        close(fd);
        return NULL;
    }
    for (int i = 0; i < w * h; i++)
        px[i] = 0x10000000;
    munmap(px, (size_t)size);
    struct wl_shm_pool *pool = wl_shm_create_pool(g_shm, fd, size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    return buffer;
}

/* Origin of the surface relative to the output: SURFACE_GAP up-left of the
 * drop point, flipped to the other side on an axis where that would leave the
 * output, then clamped into the output. */
static int surface_origin(double drop, double extent)
{
    double pos = floor(drop) - SURFACE_GAP;
    if (pos < 0)
        pos = floor(drop) + SURFACE_GAP;
    if (pos > extent - SURFACE_SIZE)
        pos = extent - SURFACE_SIZE;
    if (pos < 0)
        pos = 0;
    return (int)pos;
}

/* ----------------------------------------------------------------- setup */

/* text/uri-list body: one percent-encoded file:// URI per path, CRLF ended. */
static char *build_uri_list(int count, char **paths, const char **error_path)
{
    static const char hex[] = "0123456789ABCDEF";
    size_t cap = 1, len = 0;

    for (int i = 0; i < count; i++)
        cap += strlen("file://") + strlen(paths[i]) * 3 + 2;
    char *out = malloc(cap);
    if (!out)
        return NULL;

    for (int i = 0; i < count; i++) {
        struct stat st;
        if (paths[i][0] != '/' || lstat(paths[i], &st) < 0) {
            *error_path = paths[i];
            free(out);
            return NULL;
        }
        len += (size_t)sprintf(out + len, "file://");
        for (const unsigned char *c = (const unsigned char *)paths[i]; *c; c++) {
            if ((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') ||
                strchr("/-._~", *c)) {
                out[len++] = (char)*c;
            } else {
                out[len++] = '%';
                out[len++] = hex[*c >> 4];
                out[len++] = hex[*c & 15];
            }
        }
        out[len++] = '\r';
        out[len++] = '\n';
    }
    out[len] = '\0';
    return out;
}

/* Only one drag at a time: a second helper would fight over the pointer. */
static int acquire_lock(void)
{
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (!runtime || !*runtime)
        return -1;
    char path[4096];
    snprintf(path, sizeof(path), "%s/%s", runtime, LOCK_NAME);
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0)
        return -1;

    uint64_t until = now_ms() + LOCK_WAIT_MS;
    if (until > g_deadline)
        until = g_deadline;
    while (flock(fd, LOCK_EX | LOCK_NB) < 0) {
        if ((errno != EWOULDBLOCK && errno != EINTR) || now_ms() >= until || g_stop) {
            close(fd);
            return -2;
        }
        usleep(50 * 1000);
    }
    return fd;
}

/* Returns NULL (after printing the summary into *status) when no usable
 * output matches. */
static struct output *select_output(const char *wanted, int *status)
{
    struct output *chosen = NULL;

    if (g_num_outputs == 0) {
        *status = finish(EXIT_FAILED, "error: compositor announced no wl_output");
        return NULL;
    }
    if (wanted) {
        for (int i = 0; i < g_num_outputs; i++) {
            if (strcmp(g_outputs[i].name, wanted) == 0)
                chosen = &g_outputs[i];
        }
        if (!chosen) {
            char names[256] = "";
            for (int i = 0; i < g_num_outputs; i++) {
                size_t used = strlen(names);
                snprintf(names + used, sizeof(names) - used, "%s%s", i ? ", " : "", g_outputs[i].name);
            }
            *status = finish(EXIT_FAILED, "error: no output named '%s' (have: %s)", wanted, names);
            return NULL;
        }
    } else if (g_num_outputs == 1) {
        chosen = &g_outputs[0];
    } else {
        const char *why = "first announced";
        chosen = &g_outputs[0];
        for (int i = 0; g_primary_name[0] && i < g_num_outputs; i++) {
            if (strcmp(g_outputs[i].name, g_primary_name) == 0) {
                chosen = &g_outputs[i];
                why = "KWin primary";
            }
        }
        fprintf(stderr, PROGRAM ": %d outputs, using %s (%s); pass --output to choose\n",
                g_num_outputs, chosen->name, why);
    }
    if (!chosen->have_mode) {
        *status = finish(EXIT_FAILED, "error: output %s has no current mode", chosen->name);
        return NULL;
    }
    return chosen;
}

static bool parse_coord(const char *s, double *value)
{
    char *end = NULL;
    errno = 0;
    *value = strtod(s, &end);
    return end != s && *end == '\0' && errno == 0 && isfinite(*value);
}

static void usage(FILE *f)
{
    fprintf(f,
            "usage: " PROGRAM " [--output NAME] [--verbose] X Y PATH...\n"
            "  Replays a Ctrl+drag-and-drop of PATH... (absolute paths, files or directories)\n"
            "  onto X,Y, given in framebuffer pixels of the streamed output.\n"
            "  --output NAME  output the coordinates refer to (default: the only output,\n"
            "                 else KWin's primary)\n"
            "  --verbose      trace the protocol exchange on stderr\n"
            "  Exit status: 0 dropped, 2 rejected by the target, 1 any other error.\n");
}

int main(int argc, char **argv)
{
    setvbuf(stderr, NULL, _IOLBF, 0);
    g_deadline = now_ms() + TOTAL_TIMEOUT_MS;

    const char *wanted_output = NULL;
    int ai = 1;
    for (; ai < argc && argv[ai][0] == '-' && argv[ai][1] == '-'; ai++) {
        if (strcmp(argv[ai], "--") == 0) {
            ai++;
            break;
        } else if (strcmp(argv[ai], "--output") == 0 && ai + 1 < argc) {
            wanted_output = argv[++ai];
        } else if (strcmp(argv[ai], "--verbose") == 0) {
            g_verbose = true;
        } else if (strcmp(argv[ai], "--help") == 0) {
            usage(stdout);
            return 0;
        } else {
            usage(stderr);
            return finish(EXIT_FAILED, "error: unknown argument %s", argv[ai]);
        }
    }
    double fb_x, fb_y;
    if (argc - ai < 3 || !parse_coord(argv[ai], &fb_x) || !parse_coord(argv[ai + 1], &fb_y)) {
        usage(stderr);
        return finish(EXIT_FAILED, "error: expected X Y PATH...");
    }
    int path_count = argc - ai - 2;
    const char *bad_path = NULL;
    g_uri_list = build_uri_list(path_count, argv + ai + 2, &bad_path);
    if (!g_uri_list) {
        if (bad_path)
            return finish(EXIT_FAILED, "error: not an existing absolute path: %s", bad_path);
        return finish(EXIT_FAILED, "error: out of memory");
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    /* A drop target closing its pipe early must not kill us mid-drag. */
    signal(SIGPIPE, SIG_IGN);

    int lock_fd = acquire_lock();
    if (lock_fd == -1)
        return finish(EXIT_FAILED, "error: cannot open lock in $XDG_RUNTIME_DIR");
    if (lock_fd == -2)
        return finish(EXIT_FAILED, "error: another drop is still in progress");

    g_display = wl_display_connect(NULL);
    if (!g_display) {
        const char *d = getenv("WAYLAND_DISPLAY");
        return finish(EXIT_FAILED, "error: cannot connect to Wayland display '%s': %s",
                      d ? d : "(default)", strerror(errno));
    }
    g_registry = wl_display_get_registry(g_display);
    wl_registry_add_listener(g_registry, &registry_listener, NULL);
    if (wl_display_roundtrip(g_display) < 0)
        return finish(EXIT_FAILED, "error: Wayland roundtrip failed");
    if (g_xdg_output_manager) {
        for (int i = 0; i < g_num_outputs; i++) {
            g_outputs[i].xdg = zxdg_output_manager_v1_get_xdg_output(g_xdg_output_manager, g_outputs[i].wl);
            zxdg_output_v1_add_listener(g_outputs[i].xdg, &xdg_output_listener, &g_outputs[i]);
        }
    }
    /* Second roundtrip: output, xdg_output, seat and output order events for
     * the objects bound during the first one. */
    wl_display_roundtrip(g_display);

    if (!g_fake_input)
        return finish(EXIT_FAILED, "error: org_kde_kwin_fake_input not offered "
                                   "(.desktop for this binary missing or ksycoca not rebuilt?)");
    if (g_fake_input_version < 4)
        return finish(EXIT_FAILED, "error: fake_input v%u has no keyboard_key, cannot hold Ctrl",
                      g_fake_input_version);
    if (!g_compositor || !g_shm || !g_seat || !g_pointer || !g_ddm || g_ddm_version < 3 || !g_layer_shell)
        return finish(EXIT_FAILED, "error: compositor lacks a required global "
                                   "(compositor=%d shm=%d seat=%d pointer=%d data_device_manager=v%u layer_shell=%d)",
                      !!g_compositor, !!g_shm, !!g_seat, !!g_pointer, g_ddm_version, !!g_layer_shell);
    org_kde_kwin_fake_input_authenticate(g_fake_input, "Muelsyse Drop Helper",
                                         "Drop files from the remote desktop client");

    int status = EXIT_FAILED;
    struct output *out = select_output(wanted_output, &status);
    if (!out)
        return status;

    /* Framebuffer pixels -> output-relative logical -> global logical. */
    double phys_w, phys_h, log_x, log_y, log_w, log_h;
    output_physical_size(out, &phys_w, &phys_h);
    output_logical_rect(out, &log_x, &log_y, &log_w, &log_h);
    if (fb_x < 0 || fb_y < 0 || fb_x > phys_w || fb_y > phys_h)
        return finish(EXIT_FAILED, "error: %.1f,%.1f is outside output %s (%.0fx%.0f)",
                      fb_x, fb_y, out->name, phys_w, phys_h);
    double rel_x = fb_x * log_w / phys_w, rel_y = fb_y * log_h / phys_h;
    /* The right/bottom edge itself belongs to the next output. */
    if (rel_x > log_w - 0.01)
        rel_x = log_w - 0.01;
    if (rel_y > log_h - 0.01)
        rel_y = log_h - 0.01;
    double drop_x = log_x + rel_x, drop_y = log_y + rel_y;
    trace("output %s: fb %.0fx%.0f logical %.0f,%.0f %.0fx%.0f; drop fb %.2f,%.2f -> global %.2f,%.2f",
          out->name, phys_w, phys_h, log_x, log_y, log_w, log_h, fb_x, fb_y, drop_x, drop_y);

    struct wl_data_device *data_device = wl_data_device_manager_get_data_device(g_ddm, g_seat);
    wl_data_device_add_listener(data_device, &data_device_listener, NULL);

    /* 1. tiny overlay surface next to the drop point, never covering it.
     * exclusive_zone -1 keeps panels from shifting it, so the margins are
     * plain output-relative logical coordinates. */
    int surf_x = surface_origin(rel_x, log_w), surf_y = surface_origin(rel_y, log_h);
    g_surface = wl_compositor_create_surface(g_compositor);
    g_layer_surface = zwlr_layer_shell_v1_get_layer_surface(g_layer_shell, g_surface, out->wl,
                                                            ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "muelsyse-drop");
    zwlr_layer_surface_v1_add_listener(g_layer_surface, &layer_surface_listener, NULL);
    zwlr_layer_surface_v1_set_size(g_layer_surface, SURFACE_SIZE, SURFACE_SIZE);
    zwlr_layer_surface_v1_set_anchor(g_layer_surface,
                                     ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
    zwlr_layer_surface_v1_set_margin(g_layer_surface, surf_y, 0, 0, surf_x);
    zwlr_layer_surface_v1_set_exclusive_zone(g_layer_surface, -1);
    /* 0 = none; KWin's copy of the XML predates the named enum. */
    zwlr_layer_surface_v1_set_keyboard_interactivity(g_layer_surface, 0);
    wl_surface_commit(g_surface);
    struct wl_buffer *buffer = NULL;
    struct wl_data_source *source = NULL;

    if (pump(2000, &g_configured) < 0 || !g_configured || g_layer_closed) {
        status = finish(EXIT_FAILED, "error: layer surface was not configured");
        goto out;
    }
    buffer = create_buffer(SURFACE_SIZE, SURFACE_SIZE);
    if (!buffer) {
        status = finish(EXIT_FAILED, "error: cannot allocate shm buffer: %s", strerror(errno));
        goto out;
    }
    wl_surface_attach(g_surface, buffer, 0, 0);
    wl_surface_damage(g_surface, 0, 0, SURFACE_SIZE, SURFACE_SIZE);
    wl_surface_commit(g_surface);
    roundtrip_within(ms_left(), true);
    pump(100, NULL);

    /* 2. pointer onto our surface, press, collect the serial.  KWin sometimes
     * does not re-pick the surface under a pointer that lands exactly where it
     * already was, so nudge by a pixel between attempts. */
    double centre_x = log_x + surf_x + SURFACE_SIZE / 2.0, centre_y = log_y + surf_y + SURFACE_SIZE / 2.0;
    for (int attempt = 0; attempt < ENTER_ATTEMPTS && !g_pointer_in_surface; attempt++) {
        fake_move(centre_x + (attempt & 1), centre_y);
        if (pump(300, &g_pointer_in_surface) < 0)
            break;
    }
    if (!g_pointer_in_surface) {
        status = finish(EXIT_FAILED, "error: pointer never entered the drag source surface");
        goto out;
    }
    fake_button(true);
    if (pump(1000, &g_have_press_serial) < 0 || !g_have_press_serial) {
        status = finish(EXIT_FAILED, "error: no button press reached the drag source surface");
        goto out;
    }

    /* 3. start the drag.  Copy is the only action offered: dropped files must
     * never be moved out of the upload directory behind the caller's back. */
    source = wl_data_device_manager_create_data_source(g_ddm);
    wl_data_source_add_listener(source, &source_listener, NULL);
    wl_data_source_offer(source, "text/uri-list");
    wl_data_source_offer(source, "text/plain;charset=utf-8");
    wl_data_source_set_actions(source, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
    wl_data_device_start_drag(data_device, source, g_surface, NULL, g_press_serial);
    trace("start_drag serial=%u", g_press_serial);
    roundtrip_within(ms_left(), true);
    pump(50, NULL);

    /* 4. glide to the drop point so the target sees enter/motion, hold Ctrl,
     * release. */
    for (int i = 1; i <= GLIDE_STEPS && !g_drag_done; i++) {
        fake_move(centre_x + (drop_x - centre_x) * i / GLIDE_STEPS,
                  centre_y + (drop_y - centre_y) * i / GLIDE_STEPS);
        if (pump(30, &g_drag_done) < 0)
            break;
    }
    if (!g_drag_done && !g_stop) {
        fake_move(drop_x, drop_y);
        pump(150, &g_drag_done);
        fake_ctrl(true);
        pump(100, &g_drag_done);
        fake_button(false);
        pump(ms_left(), &g_drag_done);
    }

    if (g_drag_finished) {
        status = finish(EXIT_DROPPED, "dropped %d item(s) at %.0f,%.0f on %s (%s)", path_count, fb_x, fb_y,
                        out->name, g_drag_action == WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY ? "copy" : "accepted");
    } else if (g_drag_done) {
        status = finish(EXIT_REJECTED, "drop at %.0f,%.0f on %s rejected by the target", fb_x, fb_y, out->name);
    } else if (g_stop) {
        status = finish(EXIT_FAILED, "error: interrupted by a signal");
    } else if (ms_left() == 0) {
        status = finish(EXIT_FAILED, "error: timed out after %d ms waiting for the drop", TOTAL_TIMEOUT_MS);
    } else {
        status = finish(EXIT_FAILED, "error: lost the Wayland connection");
    }

out:
    /* An aborted drag is cancelled before the button comes up, so the release
     * cannot drop the files wherever the glide had got to. */
    if (source && g_button_down) {
        wl_data_source_destroy(source);
        source = NULL;
    }
    release_held_input();
    if (source)
        wl_data_source_destroy(source);
    zwlr_layer_surface_v1_destroy(g_layer_surface);
    wl_surface_destroy(g_surface);
    if (buffer)
        wl_buffer_destroy(buffer);
    roundtrip_within(RELEASE_FLUSH_MS, false);
    wl_display_disconnect(g_display);
    close(lock_fd);
    return status;
}
