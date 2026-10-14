/*
 * 轻量 Wayland 动画源，只用于媒体 POC 的文本帧率测量。
 *
 * 它每次收到 wl_surface.frame 回调就提交一个颜色变化的 shm buffer，
 * 不读取截图，也不参与 Selkies 的捕获、编码或鉴权。窗口很小，避免
 * 把测试内容本身变成 1440p 像素填充瓶颈；KWin 仍会为每次损坏生成完整
 * 的 screencast 帧。
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>

#include "xdg-shell-client-protocol.h"

enum {
    BUFFER_COUNT = 3,
    WIDTH = 640,
    HEIGHT = 360,
};

struct frame_buffer {
    struct wl_buffer *buffer;
    uint32_t *pixels;
    int busy;
};

struct client {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct xdg_wm_base *wm_base;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    struct frame_buffer buffers[BUFFER_COUNT];
    struct wl_callback *frame_callback;
    void *pool_data;
    size_t pool_size;
    int configured;
    int closed;
    uint64_t frame_number;
    uint64_t started_ms;
};

static void die(const char *message)
{
    fprintf(stderr, "FRAME_PACER_FAIL %s: %s\n", message, strerror(errno));
    exit(EXIT_FAILURE);
}

static uint64_t monotonic_ms(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000u + (uint64_t)now.tv_nsec / 1000000u;
}

static int create_memfd(const char *name)
{
    int fd = (int)syscall(SYS_memfd_create, name, MFD_CLOEXEC);
    if (fd < 0) {
        die("memfd_create");
    }
    return fd;
}

static void buffer_release(void *data, struct wl_buffer *buffer)
{
    struct frame_buffer *frame = data;
    (void)buffer;
    frame->busy = 0;
}

static const struct wl_buffer_listener buffer_listener = {
    .release = buffer_release,
};

static void wm_ping(void *data, struct xdg_wm_base *wm_base, uint32_t serial)
{
    (void)data;
    xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_listener = {
    .ping = wm_ping,
};

static void toplevel_configure(void *data, struct xdg_toplevel *toplevel,
                               int32_t width, int32_t height,
                               struct wl_array *states)
{
    (void)data;
    (void)toplevel;
    (void)width;
    (void)height;
    (void)states;
}

static void toplevel_close(void *data, struct xdg_toplevel *toplevel)
{
    struct client *client = data;
    (void)toplevel;
    client->closed = 1;
}

static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure,
    .close = toplevel_close,
};

static void surface_configure(void *data, struct xdg_surface *surface,
                              uint32_t serial)
{
    struct client *client = data;
    xdg_surface_ack_configure(surface, serial);
    if (!client->configured) {
        client->configured = 1;
    }
}

static const struct xdg_surface_listener surface_listener = {
    .configure = surface_configure,
};

static void register_global(void *data, struct wl_registry *registry,
                            uint32_t name, const char *interface,
                            uint32_t version)
{
    struct client *client = data;
    if (strcmp(interface, "wl_compositor") == 0) {
        client->compositor = wl_registry_bind(registry, name,
                                              &wl_compositor_interface,
                                              version < 4 ? version : 4);
    } else if (strcmp(interface, "wl_shm") == 0) {
        client->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, "xdg_wm_base") == 0) {
        client->wm_base = wl_registry_bind(registry, name,
                                           &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(client->wm_base, &wm_listener, client);
    }
}

static void unregister_global(void *data, struct wl_registry *registry,
                              uint32_t name)
{
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = register_global,
    .global_remove = unregister_global,
};

static void create_buffers(struct client *client)
{
    const size_t stride = WIDTH * sizeof(uint32_t);
    const size_t frame_size = stride * HEIGHT;
    client->pool_size = frame_size * BUFFER_COUNT;
    int fd = create_memfd("selkies-wayland-frame-pacer");
    if (ftruncate(fd, (off_t)client->pool_size) != 0) {
        die("ftruncate");
    }
    client->pool_data = mmap(NULL, client->pool_size, PROT_READ | PROT_WRITE,
                             MAP_SHARED, fd, 0);
    if (client->pool_data == MAP_FAILED) {
        die("mmap");
    }

    struct wl_shm_pool *pool = wl_shm_create_pool(client->shm, fd,
                                                   (int)client->pool_size);
    if (!pool) {
        die("wl_shm_create_pool");
    }
    for (int i = 0; i < BUFFER_COUNT; ++i) {
        client->buffers[i].pixels = (uint32_t *)((char *)client->pool_data
                                                  + frame_size * (size_t)i);
        client->buffers[i].buffer = wl_shm_pool_create_buffer(
            pool, (int)(frame_size * (size_t)i), WIDTH, HEIGHT, (int)stride,
            WL_SHM_FORMAT_XRGB8888);
        if (!client->buffers[i].buffer) {
            die("wl_shm_pool_create_buffer");
        }
        wl_buffer_add_listener(client->buffers[i].buffer, &buffer_listener,
                               &client->buffers[i]);
    }
    wl_shm_pool_destroy(pool);
    close(fd);
}

static struct frame_buffer *next_buffer(struct client *client)
{
    for (int i = 0; i < BUFFER_COUNT; ++i) {
        if (!client->buffers[i].busy) {
            return &client->buffers[i];
        }
    }
    return NULL;
}

static const struct wl_callback_listener frame_listener;

static void draw_and_commit(struct client *client)
{
    if (!client->configured || client->closed || client->frame_callback) {
        return;
    }
    struct frame_buffer *frame = next_buffer(client);
    if (!frame) {
        return;
    }
    const uint32_t tick = (uint32_t)client->frame_number++;
    const uint32_t red = (tick * 5u) & 0xffu;
    const uint32_t green = (tick * 3u) & 0xffu;
    const uint32_t blue = (tick * 7u) & 0xffu;
    const uint32_t color = (red << 16) | (green << 8) | blue;
    for (int y = 0; y < HEIGHT; ++y) {
        for (int x = 0; x < WIDTH; ++x) {
            frame->pixels[y * WIDTH + x] = color ^ (uint32_t)(x + y);
        }
    }
    if (client->frame_number % 300u == 0u) {
        const uint64_t elapsed = monotonic_ms() - client->started_ms;
        const double fps = elapsed > 0
            ? (double)client->frame_number * 1000.0 / (double)elapsed
            : 0.0;
        printf("FRAME_PACER_STATS frames=%llu elapsed_ms=%llu fps=%.2f\n",
               (unsigned long long)client->frame_number,
               (unsigned long long)elapsed,
               fps);
        fflush(stdout);
    }
    frame->busy = 1;
    wl_surface_attach(client->surface, frame->buffer, 0, 0);
    wl_surface_damage_buffer(client->surface, 0, 0, WIDTH, HEIGHT);
    client->frame_callback = wl_surface_frame(client->surface);
    wl_callback_add_listener(client->frame_callback, &frame_listener, client);
    wl_surface_commit(client->surface);
    wl_display_flush(client->display);
}

static void frame_done(void *data, struct wl_callback *callback, uint32_t time)
{
    struct client *client = data;
    (void)time;
    wl_callback_destroy(callback);
    client->frame_callback = NULL;
    draw_and_commit(client);
}

static const struct wl_callback_listener frame_listener = {
    .done = frame_done,
};

int main(void)
{
    struct client client = {0};
    client.started_ms = monotonic_ms();
    client.display = wl_display_connect(NULL);
    if (!client.display) {
        die("wl_display_connect");
    }
    client.registry = wl_display_get_registry(client.display);
    wl_registry_add_listener(client.registry, &registry_listener, &client);
    if (wl_display_roundtrip(client.display) < 0 || !client.compositor
        || !client.shm || !client.wm_base) {
        die("Wayland globals");
    }

    client.surface = wl_compositor_create_surface(client.compositor);
    client.xdg_surface = xdg_wm_base_get_xdg_surface(client.wm_base,
                                                      client.surface);
    client.toplevel = xdg_surface_get_toplevel(client.xdg_surface);
    xdg_surface_add_listener(client.xdg_surface, &surface_listener, &client);
    xdg_toplevel_add_listener(client.toplevel, &toplevel_listener, &client);
    xdg_toplevel_set_title(client.toplevel, "Selkies KWin frame pacer");
    wl_surface_commit(client.surface);
    if (wl_display_roundtrip(client.display) < 0) {
        die("initial configure");
    }
    create_buffers(&client);
    draw_and_commit(&client);
    printf("FRAME_PACER_READY width=%d height=%d\n", WIDTH, HEIGHT);
    fflush(stdout);
    while (!client.closed && wl_display_dispatch(client.display) >= 0) {
        /* 帧回调按 KWin 的输出时钟推进，不使用 sleep 伪造 60 FPS。 */
        if (!client.frame_callback) {
            draw_and_commit(&client);
        }
    }
    return EXIT_SUCCESS;
}
