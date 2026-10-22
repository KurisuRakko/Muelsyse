# muelsyse-sunshine-input-bridge（源码目录 sunshine/input-bridge，产物装到 ~/.local/libexec）
CC      ?= cc
CFLAGS  ?= -O2 -g -Wall -Wextra
CFLAGS  += -ffile-prefix-map=$(CURDIR)=.
LDFLAGS ?=

WAYLAND_SCANNER ?= wayland-scanner
# Shipped by the plasma-wayland-protocols package.
PROTO_XML ?= /usr/share/plasma-wayland-protocols/fake-input.xml

WAYLAND_CFLAGS := $(shell pkg-config --cflags wayland-client)
WAYLAND_LIBS   := $(shell pkg-config --libs wayland-client)

PREFIX ?= $(HOME)/.local

all: muelsyse-sunshine-input-bridge test/uinput-dev test/wl-input-probe

fake-input-client-protocol.h: $(PROTO_XML)
	$(WAYLAND_SCANNER) client-header $< $@

fake-input-protocol.c: $(PROTO_XML)
	$(WAYLAND_SCANNER) private-code $< $@

muelsyse-sunshine-input-bridge: bridge.c fake-input-client-protocol.h fake-input-protocol.c
	$(CC) $(CFLAGS) $(WAYLAND_CFLAGS) -o $@ bridge.c fake-input-protocol.c $(WAYLAND_LIBS) $(LDFLAGS) -lm

test/uinput-dev: test/uinput-dev.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS) -lm

XDG_SHELL_XML ?= /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml

xdg-shell-client-protocol.h: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) client-header $< $@

xdg-shell-protocol.c: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

test/wl-input-probe: test/wl-input-probe.c xdg-shell-client-protocol.h xdg-shell-protocol.c
	$(CC) $(CFLAGS) $(WAYLAND_CFLAGS) -I. -o $@ test/wl-input-probe.c xdg-shell-protocol.c $(WAYLAND_LIBS) $(LDFLAGS) -lm

install: muelsyse-sunshine-input-bridge
	install -Dm755 muelsyse-sunshine-input-bridge $(DESTDIR)$(PREFIX)/libexec/muelsyse-sunshine-input-bridge

clean:
	rm -f muelsyse-sunshine-input-bridge test/uinput-dev test/wl-input-probe

.PHONY: all install clean
