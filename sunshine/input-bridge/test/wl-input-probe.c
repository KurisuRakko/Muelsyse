// SPDX-License-Identifier: MIT
/*
 * wl-input-probe - a minimal Wayland client that maps a fullscreen surface and
 * prints every input event the compositor delivers through the normal
 * wl_pointer / wl_keyboard path.
 *
 * This is the read-back instrument for testing rakkord-sunshine-input-bridge: it shows
 * what KWin actually did with the injected events, in the compositor's own
 * coordinate space (surface-local == logical screen space, because the surface
 * covers the whole output at the origin).
 *
 * usage: wl-input-probe [max_seconds] [width height]
 */
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>

#include "xdg-shell-client-protocol.h"

static struct wl_compositor *g_compositor;
static struct wl_shm *g_shm;
static struct xdg_wm_base *g_wm_base;
static struct wl_output *g_output;
static int g_output_w = 1744, g_output_h = 3696;
static int g_scale = 1;
static int g_want_w = 1744, g_want_h = 3696;

static struct wl_surface *g_surface;
static struct xdg_surface *g_xdg_surface;
static struct xdg_toplevel *g_toplevel;
static struct wl_buffer *g_buffer;
static struct wl_keyboard *g_keyboard;
static struct wl_pointer *g_pointer;
static bool g_running = true;

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

#define LOG(...) do { printf("[%8llu] ", (unsigned long long)now_ms()); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

/* ---------------------------------------------------------- shm buffer */

static int create_shm_file(size_t size)
{
    char name[64];
    snprintf(name, sizeof(name), "/wl-probe-%d", getpid());
    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0)
        return -1;
    shm_unlink(name);
    if (ftruncate(fd, size) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static struct wl_buffer *make_buffer(int w, int h)
{
    int stride = w * 4;
    size_t size = (size_t)stride * h;
    int fd = create_shm_file(size);
    if (fd < 0)
        return NULL;
    void *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) {
        close(fd);
        return NULL;
    }
    uint32_t *px = data;
    for (size_t i = 0; i < size / 4; i++)
        px[i] = 0xff202020; /* dark grey */
    munmap(data, size);

    struct wl_shm_pool *pool = wl_shm_create_pool(g_shm, fd, size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, w, h, stride,
                                                         WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    return buffer;
}

/* -------------------------------------------------------------- xdg shell */

static void xdg_wm_base_ping(void *data, struct xdg_wm_base *base, uint32_t serial)
{
    (void)data;
    xdg_wm_base_pong(base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = { .ping = xdg_wm_base_ping };

static void xdg_surface_configure(void *data, struct xdg_surface *s, uint32_t serial)
{
    (void)data;
    xdg_surface_ack_configure(s, serial);
    LOG("xdg_surface configure acked");
}

static const struct xdg_surface_listener xdg_surface_listener = { .configure = xdg_surface_configure };

static void toplevel_configure(void *data, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *states)
{
    (void)data; (void)t; (void)states;
    LOG("toplevel configure %dx%d", w, h);
}

static void toplevel_close(void *data, struct xdg_toplevel *t)
{
    (void)data; (void)t;
    LOG("toplevel close requested");
    g_running = false;
}

static void toplevel_configure_bounds(void *data, struct xdg_toplevel *t, int32_t w, int32_t h)
{
    (void)data; (void)t; (void)w; (void)h;
}

static void toplevel_wm_capabilities(void *data, struct xdg_toplevel *t, struct wl_array *caps)
{
    (void)data; (void)t; (void)caps;
}

static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure,
    .close = toplevel_close,
    .configure_bounds = toplevel_configure_bounds,
    .wm_capabilities = toplevel_wm_capabilities,
};

/* ------------------------------------------------------------ wl_output */

static void output_geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph,
                            int32_t subpixel, const char *make, const char *model, int32_t transform)
{
    (void)d; (void)o; (void)x; (void)y; (void)pw; (void)ph; (void)subpixel; (void)make; (void)model; (void)transform;
}

static void output_mode(void *d, struct wl_output *o, uint32_t flags, int32_t w, int32_t h, int32_t refresh)
{
    (void)d; (void)o; (void)refresh;
    if (flags & WL_OUTPUT_MODE_CURRENT) {
        g_output_w = w;
        g_output_h = h;
    }
}

static void output_done(void *d, struct wl_output *o)
{
    (void)d; (void)o;
    LOG("output mode %dx%d scale %d -> logical %dx%d", g_output_w, g_output_h, g_scale,
        g_output_w / g_scale, g_output_h / g_scale);
}

static void output_scale(void *d, struct wl_output *o, int32_t factor)
{
    (void)d; (void)o;
    if (factor > 0)
        g_scale = factor;
}

static void output_name_cb(void *d, struct wl_output *o, const char *name)
{
    (void)d; (void)o; (void)name;
}

static void output_description_cb(void *d, struct wl_output *o, const char *desc)
{
    (void)d; (void)o; (void)desc;
}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry,
    .mode = output_mode,
    .done = output_done,
    .scale = output_scale,
    .name = output_name_cb,
    .description = output_description_cb,
};

/* ------------------------------------------------------------- wl_pointer */

static void pointer_enter(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *s,
                          wl_fixed_t sx, wl_fixed_t sy)
{
    (void)d; (void)p; (void)serial; (void)s;
    LOG("POINTER enter  x=%.3f y=%.3f", wl_fixed_to_double(sx), wl_fixed_to_double(sy));
}

static void pointer_leave(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *s)
{
    (void)d; (void)p; (void)serial; (void)s;
    LOG("POINTER leave");
}

static void pointer_motion(void *d, struct wl_pointer *p, uint32_t time, wl_fixed_t sx, wl_fixed_t sy)
{
    (void)d; (void)p; (void)time;
    LOG("POINTER motion x=%.3f y=%.3f", wl_fixed_to_double(sx), wl_fixed_to_double(sy));
}

static void pointer_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t time,
                           uint32_t button, uint32_t state)
{
    (void)d; (void)p; (void)serial; (void)time;
    LOG("POINTER button %u %s", button,
        state == WL_POINTER_BUTTON_STATE_PRESSED ? "pressed" : "released");
}

static void pointer_axis(void *d, struct wl_pointer *p, uint32_t time, uint32_t axis, wl_fixed_t value)
{
    (void)d; (void)p; (void)time;
    LOG("POINTER axis %u (0=vertical,1=horizontal) value=%.4f", axis, wl_fixed_to_double(value));
}

static void pointer_frame(void *d, struct wl_pointer *p)
{
    (void)d; (void)p;
    LOG("POINTER frame");
}

static void pointer_axis_source(void *d, struct wl_pointer *p, uint32_t source)
{
    (void)d; (void)p;
    LOG("POINTER axis_source %u", source);
}

static void pointer_axis_stop(void *d, struct wl_pointer *p, uint32_t time, uint32_t axis)
{
    (void)d; (void)p; (void)time; (void)axis;
}

static void pointer_axis_discrete(void *d, struct wl_pointer *p, uint32_t axis, int32_t discrete)
{
    (void)d; (void)p;
    LOG("POINTER axis_discrete axis=%u discrete=%d", axis, discrete);
}

static void pointer_axis_value120(void *d, struct wl_pointer *p, uint32_t axis, int32_t value120)
{
    (void)d; (void)p;
    LOG("POINTER axis_value120 axis=%u value120=%d", axis, value120);
}

static void pointer_axis_relative_direction(void *d, struct wl_pointer *p, uint32_t axis, uint32_t dir)
{
    (void)d; (void)p; (void)axis; (void)dir;
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
    .axis_value120 = pointer_axis_value120,
    .axis_relative_direction = pointer_axis_relative_direction,
};

/* ------------------------------------------------------------ wl_keyboard */

static void kb_keymap(void *d, struct wl_keyboard *k, uint32_t format, int32_t fd, uint32_t size)
{
    (void)d; (void)k; (void)format; (void)size;
    if (fd >= 0)
        close(fd);
}

static void kb_enter(void *d, struct wl_keyboard *k, uint32_t serial, struct wl_surface *s, struct wl_array *keys)
{
    (void)d; (void)k; (void)serial; (void)s; (void)keys;
    LOG("KEYBOARD enter");
}

static void kb_leave(void *d, struct wl_keyboard *k, uint32_t serial, struct wl_surface *s)
{
    (void)d; (void)k; (void)serial; (void)s;
    LOG("KEYBOARD leave");
}

static void kb_key(void *d, struct wl_keyboard *k, uint32_t serial, uint32_t time, uint32_t key, uint32_t state)
{
    (void)d; (void)k; (void)serial; (void)time;
    LOG("KEYBOARD key evdev=%u (xkb keycode=%u) %s", key, key + 8,
        state == WL_KEYBOARD_KEY_STATE_PRESSED ? "pressed" : "released");
}

static void kb_modifiers(void *d, struct wl_keyboard *k, uint32_t serial, uint32_t depressed,
                         uint32_t latched, uint32_t locked, uint32_t group)
{
    (void)d; (void)k; (void)serial;
    LOG("KEYBOARD modifiers depressed=0x%x latched=0x%x locked=0x%x group=%u",
        depressed, latched, locked, group);
}

static void kb_repeat_info(void *d, struct wl_keyboard *k, int32_t rate, int32_t delay)
{
    (void)d; (void)k;
    LOG("KEYBOARD repeat_info rate=%d delay=%d", rate, delay);
}

static const struct wl_keyboard_listener keyboard_listener = {
    .keymap = kb_keymap,
    .enter = kb_enter,
    .leave = kb_leave,
    .key = kb_key,
    .modifiers = kb_modifiers,
    .repeat_info = kb_repeat_info,
};

/* ------------------------------------------------------------------ seat */

static void seat_capabilities(void *d, struct wl_seat *seat, uint32_t caps)
{
    (void)d;
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !g_pointer) {
        g_pointer = wl_seat_get_pointer(seat);
        wl_pointer_add_listener(g_pointer, &pointer_listener, NULL);
    }
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !g_keyboard) {
        g_keyboard = wl_seat_get_keyboard(seat);
        wl_keyboard_add_listener(g_keyboard, &keyboard_listener, NULL);
    }
}

static void seat_name(void *d, struct wl_seat *seat, const char *name)
{
    (void)d; (void)seat;
    LOG("seat name '%s'", name);
}

static const struct wl_seat_listener seat_listener = { .capabilities = seat_capabilities, .name = seat_name };

/* -------------------------------------------------------------- registry */

static void registry_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t version)
{
    (void)d;
    if (strcmp(iface, wl_compositor_interface.name) == 0)
        g_compositor = wl_registry_bind(r, name, &wl_compositor_interface, 4);
    else if (strcmp(iface, wl_shm_interface.name) == 0)
        g_shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (strcmp(iface, xdg_wm_base_interface.name) == 0)
        g_wm_base = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
    else if (strcmp(iface, wl_seat_interface.name) == 0)
        wl_seat_add_listener(wl_registry_bind(r, name, &wl_seat_interface, 5), &seat_listener, NULL);
    else if (strcmp(iface, wl_output_interface.name) == 0 && !g_output) {
        g_output = wl_registry_bind(r, name, &wl_output_interface, 4);
        wl_output_add_listener(g_output, &output_listener, NULL);
    }
}

static void registry_global_remove(void *d, struct wl_registry *r, uint32_t name)
{
    (void)d; (void)r; (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

int main(int argc, char **argv)
{
    int max_seconds = (argc > 1) ? atoi(argv[1]) : 20;
    if (argc > 3) {
        g_want_w = atoi(argv[2]);
        g_want_h = atoi(argv[3]);
    }

    struct wl_display *display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "cannot connect to wayland display\n");
        return 1;
    }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (!g_compositor || !g_shm || !g_wm_base) {
        fprintf(stderr, "missing required globals\n");
        return 1;
    }
    xdg_wm_base_add_listener(g_wm_base, &wm_base_listener, NULL);
    wl_display_roundtrip(display);

    g_surface = wl_compositor_create_surface(g_compositor);
    g_xdg_surface = xdg_wm_base_get_xdg_surface(g_wm_base, g_surface);
    xdg_surface_add_listener(g_xdg_surface, &xdg_surface_listener, NULL);
    g_toplevel = xdg_surface_get_toplevel(g_xdg_surface);
    xdg_toplevel_add_listener(g_toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_title(g_toplevel, "wl-input-probe");
    xdg_toplevel_set_app_id(g_toplevel, "wl-input-probe");
    if (argc > 3) {
        xdg_toplevel_set_fullscreen(g_toplevel, g_output);
        LOG("asking for fullscreen %dx%d", g_want_w, g_want_h);
    }
    wl_surface_commit(g_surface);
    wl_display_roundtrip(display);

    int bw = g_want_w > 0 ? g_want_w : g_output_w;
    int bh = g_want_h > 0 ? g_want_h : g_output_h;
    /* A fullscreen window on a scaled output must be given the same scale,
     * otherwise the surface is scale*logical in size. */
    wl_surface_set_buffer_scale(g_surface, g_scale);
    g_buffer = make_buffer(bw, bh);
    if (!g_buffer) {
        fprintf(stderr, "cannot create shm buffer\n");
        return 1;
    }
    wl_surface_attach(g_surface, g_buffer, 0, 0);
    wl_surface_commit(g_surface);
    wl_display_roundtrip(display);
    LOG("probe ready (buffer %dx%d scale %d -> surface %dx%d)", bw, bh, g_scale, bw / g_scale, bh / g_scale);

    uint64_t deadline = now_ms() + (uint64_t)max_seconds * 1000u;
    while (g_running && now_ms() < deadline) {
        struct pollfd pfd = { .fd = wl_display_get_fd(display), .events = POLLIN };
        int timeout = (int)(deadline - now_ms());
        if (timeout < 0)
            timeout = 0;
        int ret = poll(&pfd, 1, timeout);
        if (ret < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (ret == 0)
            continue;
        if (wl_display_dispatch(display) < 0) {
            LOG("display dispatch failed");
            break;
        }
    }

    LOG("probe exiting");
    if (g_pointer)
        wl_pointer_destroy(g_pointer);
    if (g_keyboard)
        wl_keyboard_destroy(g_keyboard);
    if (g_buffer)
        wl_buffer_destroy(g_buffer);
    if (g_toplevel)
        xdg_toplevel_destroy(g_toplevel);
    if (g_xdg_surface)
        xdg_surface_destroy(g_xdg_surface);
    if (g_surface)
        wl_surface_destroy(g_surface);
    wl_display_flush(display);
    wl_display_disconnect(display);
    return 0;
}
