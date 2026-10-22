// SPDX-License-Identifier: MIT
/*
 * uinput-dev - create throw-away virtual input devices that look exactly
 * like the ones Sunshine's libvirtualhid creates, and push a scripted
 * sequence of events through them.
 *
 * Used to test muelsyse-sunshine-input-bridge without a Moonlight client.
 *
 * usage: uinput-dev <abs|rel|wheel|kbd|highkey> [abs_range]
 */
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int g_fd = -1;

static void die(const char *what)
{
    fprintf(stderr, "uinput-dev: %s: %s\n", what, strerror(errno));
    exit(1);
}

static void emit(int type, int code, int value)
{
    struct input_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = type;
    ev.code = code;
    ev.value = value;
    if (write(g_fd, &ev, sizeof(ev)) != (ssize_t)sizeof(ev))
        die("write");
}

static void syn(void)
{
    emit(EV_SYN, SYN_REPORT, 0);
}

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

#define LOG(...) do { \
        printf("[%8llu] ", (unsigned long long)now_ms()); \
        printf(__VA_ARGS__); \
        fflush(stdout); \
    } while (0)

static void sleep_ms(int ms)
{
    struct timespec ts = { .tv_sec = ms / 1000, .tv_nsec = (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

static void create(const char *name, const char *phys)
{
    g_fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (g_fd < 0)
        die("open /dev/uinput");

    struct uinput_setup setup;
    memset(&setup, 0, sizeof(setup));
    snprintf(setup.name, sizeof(setup.name), "%s", name);
    setup.id.bustype = BUS_VIRTUAL;
    setup.id.vendor = 0x1b1c;
    setup.id.product = 0x1000;

    if (ioctl(g_fd, UI_DEV_SETUP, &setup) < 0)
        die("UI_DEV_SETUP");
    if (ioctl(g_fd, UI_SET_PHYS, phys) < 0)
        die("UI_SET_PHYS");
}

static void enable_key(int code)
{
    if (ioctl(g_fd, UI_SET_EVBIT, EV_KEY) < 0)
        die("UI_SET_EVBIT");
    if (ioctl(g_fd, UI_SET_KEYBIT, code) < 0)
        die("UI_SET_KEYBIT");
}

static void enable_rel(int code)
{
    if (ioctl(g_fd, UI_SET_EVBIT, EV_REL) < 0)
        die("UI_SET_EVBIT");
    if (ioctl(g_fd, UI_SET_RELBIT, code) < 0)
        die("UI_SET_RELBIT");
}

static void enable_abs(int code, int min, int max)
{
    if (ioctl(g_fd, UI_SET_EVBIT, EV_ABS) < 0)
        die("UI_SET_EVBIT");
    if (ioctl(g_fd, UI_SET_ABSBIT, code) < 0)
        die("UI_SET_ABSBIT");
    struct uinput_abs_setup abs;
    memset(&abs, 0, sizeof(abs));
    abs.code = code;
    abs.absinfo.minimum = min;
    abs.absinfo.maximum = max;
    abs.absinfo.fuzz = 0;
    abs.absinfo.flat = 0;
    abs.absinfo.resolution = 0;
    if (ioctl(g_fd, UI_ABS_SETUP, &abs) < 0)
        die("UI_ABS_SETUP");
}

static void create_device(void)
{
    if (ioctl(g_fd, UI_DEV_CREATE) < 0)
        die("UI_DEV_CREATE");
}

static void destroy_device(void)
{
    LOG("destroying device\n");
    if (g_fd >= 0) {
        ioctl(g_fd, UI_DEV_DESTROY);
        close(g_fd);
        g_fd = -1;
    }
}


int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <abs [range]|rel|wheel|kbd|highkey>"
                        " [settle_ms]\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    int range = (argc > 2) ? atoi(argv[2]) : 32767;
    if (range <= 0)
        range = 32767;
    int settle = (argc > 3) ? atoi(argv[3]) : 800;
    if (settle < 0)
        settle = 0;

    LOG("mode=%s range=%d settle=%dms\n", mode, range, settle);

    if (strcmp(mode, "abs") == 0) {
        create("Sunshine (libvirtualhid) Test Absolute Mouse", "libvirtualhid/uhid/test-abs");
        enable_abs(ABS_X, 0, range);
        enable_abs(ABS_Y, 0, range);
        enable_key(BTN_LEFT);
        create_device();
        LOG("device created, waiting %dms for the bridge to attach\n", settle);
        sleep_ms(settle);

        /* Note: the kernel drops an EV_ABS event whose value is unchanged
         * (input_handle_abs_event()), so every step below changes at least
         * one axis.  X and Y are swept independently, through their minimum,
         * maximum and the quarter points: that is the full coordinate range
         * of the output. */
        struct { double fx, fy; const char *label; } targets[] = {
            { 0.50, 0.50, "centre" },
            { 0.00, 0.50, "x minimum" },
            { 0.25, 0.50, "x 25%" },
            { 0.75, 0.50, "x 75%" },
            { 1.00, 0.50, "x maximum" },
            { 0.50, 0.00, "y minimum" },
            { 0.50, 0.25, "y 25%" },
            { 0.50, 0.75, "y 75%" },
            { 0.50, 1.00, "y maximum" },
            { 0.50, 0.50, "centre again" },
        };
        for (unsigned i = 0; i < sizeof(targets) / sizeof(targets[0]); i++) {
            int x = (int)(targets[i].fx * range + 0.5);
            int y = (int)(targets[i].fy * range + 0.5);
            LOG("[+] step %u %s: ABS_X=%d ABS_Y=%d\n", i, targets[i].label, x, y);
            emit(EV_ABS, ABS_X, x);
            emit(EV_ABS, ABS_Y, y);
            syn();
            sleep_ms(500);
        }
        destroy_device();
    } else if (strcmp(mode, "park") == 0) {
        /* Move an absolute pointer to the middle of the screen and leave it
         * there.  Used to bring the pointer away from the screen edge before
         * the relative/button/key tests. */
        create("Sunshine (libvirtualhid) Test Absolute Mouse", "libvirtualhid/uhid/test-park");
        enable_abs(ABS_X, 0, range);
        enable_abs(ABS_Y, 0, range);
        enable_key(BTN_LEFT);
        create_device();
        LOG("device created, waiting %dms for the bridge to attach\n", settle);
        sleep_ms(settle);
        LOG("[+] park at centre: ABS_X=%d ABS_Y=%d\n", range / 2, range / 2);
        emit(EV_ABS, ABS_X, range / 2);
        emit(EV_ABS, ABS_Y, range / 2);
        syn();
        sleep_ms(300);
        destroy_device();
    } else if (strcmp(mode, "abs-edge") == 0) {
        /* Probe the very last pixels of the output to see how the compositor
         * handles the exact far edge of an absolute device's range. */
        create("Sunshine (libvirtualhid) Test Absolute Mouse", "libvirtualhid/uhid/test-absedge");
        enable_abs(ABS_X, 0, range);
        enable_abs(ABS_Y, 0, range);
        enable_key(BTN_LEFT);
        create_device();
        LOG("device created, waiting %dms for the bridge to attach\n", settle);
        sleep_ms(settle);

        struct { double fx, fy; const char *label; } targets[] = {
            { 871.0 / 872.0, 0.0,        "x=871.0 (last full logical column)" },
            { 871.5 / 872.0, 1846.0 / 1848.0, "x=871.5 y=1846.0" },
            { 1.0,           1847.0 / 1848.0, "x=max(872) y=1847.0" },
            { 0.0,           1.0,        "x=0 y=max(1848)" },
            { 0.5,           0.5,        "park back at the centre" },
        };
        for (unsigned i = 0; i < sizeof(targets) / sizeof(targets[0]); i++) {
            int x = (int)(targets[i].fx * range + 0.5);
            int y = (int)(targets[i].fy * range + 0.5);
            LOG("[+] step %u %s: ABS_X=%d ABS_Y=%d\n", i, targets[i].label, x, y);
            emit(EV_ABS, ABS_X, x);
            emit(EV_ABS, ABS_Y, y);
            syn();
            sleep_ms(600);
        }
        destroy_device();
    } else if (strcmp(mode, "rel") == 0) {
        create("Sunshine (libvirtualhid) Test Mouse", "libvirtualhid/uhid/test-rel");
        enable_rel(REL_X);
        enable_rel(REL_Y);
        enable_key(BTN_LEFT);
        enable_key(BTN_MIDDLE);
        enable_key(BTN_RIGHT);
        create_device();
        LOG("device created, waiting %dms for the bridge to attach\n", settle);
        sleep_ms(settle);

        LOG("[+] rel +120/+80 in one report (accumulate test)\n");
        emit(EV_REL, REL_X, 120);
        emit(EV_REL, REL_X, 80);
        syn();
        sleep_ms(300);

        LOG("[+] rel diagonal +40/+40 (X and Y in one report)\n");
        emit(EV_REL, REL_X, 40);
        emit(EV_REL, REL_Y, 40);
        syn();
        sleep_ms(300);

        LOG("[+] rel -60/-30\n");
        emit(EV_REL, REL_X, -60);
        emit(EV_REL, REL_Y, -30);
        syn();
        sleep_ms(300);

        LOG("[+] BTN_LEFT press\n");
        emit(EV_KEY, BTN_LEFT, 1);
        syn();
        sleep_ms(300);
        LOG("[+] BTN_LEFT release\n");
        emit(EV_KEY, BTN_LEFT, 0);
        syn();
        sleep_ms(300);

        LOG("[+] BTN_RIGHT press+release\n");
        emit(EV_KEY, BTN_RIGHT, 1);
        syn();
        sleep_ms(200);
        emit(EV_KEY, BTN_RIGHT, 0);
        syn();
        sleep_ms(200);
        destroy_device();
    } else if (strcmp(mode, "wheel") == 0) {
        create("Sunshine (libvirtualhid) Test Mouse", "libvirtualhid/uhid/test-wheel");
        enable_rel(REL_X);
        enable_rel(REL_Y);
        enable_rel(REL_WHEEL);
        enable_rel(REL_HWHEEL);
        enable_key(BTN_LEFT);
        create_device();
        LOG("device created, waiting %dms for the bridge to attach\n", settle);
        sleep_ms(settle);

        for (int i = 0; i < 3; i++) {
            LOG("[+] REL_WHEEL +1 (up)\n");
            emit(EV_REL, REL_WHEEL, 1);
            syn();
            sleep_ms(250);
        }
        for (int i = 0; i < 2; i++) {
            LOG("[+] REL_WHEEL -1 (down)\n");
            emit(EV_REL, REL_WHEEL, -1);
            syn();
            sleep_ms(250);
        }
        LOG("[+] REL_HWHEEL +1 (right)\n");
        emit(EV_REL, REL_HWHEEL, 1);
        syn();
        sleep_ms(250);
        LOG("[+] REL_WHEEL +5 (batching test)\n");
        emit(EV_REL, REL_WHEEL, 5);
        syn();
        sleep_ms(250);
        destroy_device();
    } else if (strcmp(mode, "kbd") == 0) {
        create("Sunshine (libvirtualhid) Test Keyboard", "libvirtualhid/uhid/test-kbd");
        enable_key(KEY_A);
        enable_key(KEY_B);
        enable_key(KEY_LEFTCTRL);
        enable_key(KEY_LEFTSHIFT);
        enable_key(KEY_F5);
        enable_key(KEY_SPACE);
        enable_key(KEY_OK);
        create_device();
        LOG("device created, waiting %dms for the bridge to attach\n", settle);
        sleep_ms(settle);

        LOG("[+] KEY_A press\n");
        emit(EV_KEY, KEY_A, 1);
        syn();
        sleep_ms(150);
        LOG("[+] KEY_A release\n");
        emit(EV_KEY, KEY_A, 0);
        syn();
        sleep_ms(250);

        LOG("[+] CTRL press, A press, A release, CTRL release (Ctrl+A)\n");
        emit(EV_KEY, KEY_LEFTCTRL, 1);
        syn();
        sleep_ms(80);
        emit(EV_KEY, KEY_A, 1);
        syn();
        sleep_ms(150);
        emit(EV_KEY, KEY_A, 0);
        syn();
        sleep_ms(80);
        emit(EV_KEY, KEY_LEFTCTRL, 0);
        syn();
        sleep_ms(250);

        LOG("[+] SHIFT+B (uppercase)\n");
        emit(EV_KEY, KEY_LEFTSHIFT, 1);
        syn();
        sleep_ms(80);
        emit(EV_KEY, KEY_B, 1);
        syn();
        sleep_ms(150);
        emit(EV_KEY, KEY_B, 0);
        syn();
        sleep_ms(80);
        emit(EV_KEY, KEY_LEFTSHIFT, 0);
        syn();
        sleep_ms(250);

        LOG("[+] KEY_F5 press/release\n");
        emit(EV_KEY, KEY_F5, 1);
        syn();
        sleep_ms(150);
        emit(EV_KEY, KEY_F5, 0);
        syn();
        sleep_ms(250);

        LOG("[+] KEY_SPACE press/release\n");
        emit(EV_KEY, KEY_SPACE, 1);
        syn();
        sleep_ms(150);
        emit(EV_KEY, KEY_SPACE, 0);
        syn();
        sleep_ms(200);

        LOG("[+] KEY_OK (evdev 352, high key range) press/release\n");
        emit(EV_KEY, KEY_OK, 1);
        syn();
        sleep_ms(150);
        emit(EV_KEY, KEY_OK, 0);
        syn();
        sleep_ms(200);
        destroy_device();
    } else {
        fprintf(stderr, "unknown mode: %s\n", mode);
        return 2;
    }

    LOG("done\n");
    return 0;
}
