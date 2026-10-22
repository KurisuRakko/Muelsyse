# muelsyse-drop-helper（源码目录 desktop-drop，产物装到 ~/.local/libexec）
CC      ?= cc
CFLAGS  ?= -O2 -g -Wall -Wextra
CFLAGS  += -ffile-prefix-map=$(CURDIR)=.
LDFLAGS ?=

WAYLAND_SCANNER ?= wayland-scanner
# Shipped by the plasma-wayland-protocols package.
FAKE_INPUT_XML   ?= /usr/share/plasma-wayland-protocols/fake-input.xml
OUTPUT_ORDER_XML ?= /usr/share/plasma-wayland-protocols/kde-output-order-v1.xml
# Shipped by the wayland-protocols package.
XDG_OUTPUT_XML   ?= /usr/share/wayland-protocols/unstable/xdg-output/xdg-output-unstable-v1.xml
XDG_SHELL_XML    ?= /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
# The copy in this repository's KWin tree.  deploy-host.sh builds from a copy
# of this directory alone, where the path does not resolve; the generated
# files are committed, so they are only regenerated when the XML is present.
LAYER_SHELL_XML  ?= ../kwin/src/wayland/protocols/wlr-layer-shell-unstable-v1.xml

WAYLAND_CFLAGS := $(shell pkg-config --cflags wayland-client)
WAYLAND_LIBS   := $(shell pkg-config --libs wayland-client)

PREFIX ?= $(HOME)/.local

PROTOCOLS := fake-input kde-output-order-v1 xdg-output wlr-layer-shell xdg-shell
PROTO_HEADERS := $(PROTOCOLS:%=%-client-protocol.h)
PROTO_SOURCES := $(PROTOCOLS:%=%-protocol.c)

all: muelsyse-drop-helper

fake-input-client-protocol.h: $(wildcard $(FAKE_INPUT_XML))
	$(WAYLAND_SCANNER) client-header $< $@

fake-input-protocol.c: $(wildcard $(FAKE_INPUT_XML))
	$(WAYLAND_SCANNER) private-code $< $@

kde-output-order-v1-client-protocol.h: $(wildcard $(OUTPUT_ORDER_XML))
	$(WAYLAND_SCANNER) client-header $< $@

kde-output-order-v1-protocol.c: $(wildcard $(OUTPUT_ORDER_XML))
	$(WAYLAND_SCANNER) private-code $< $@

xdg-output-client-protocol.h: $(wildcard $(XDG_OUTPUT_XML))
	$(WAYLAND_SCANNER) client-header $< $@

xdg-output-protocol.c: $(wildcard $(XDG_OUTPUT_XML))
	$(WAYLAND_SCANNER) private-code $< $@

# wlr-layer-shell references xdg_popup, so xdg-shell is linked in as well.
wlr-layer-shell-client-protocol.h: $(wildcard $(LAYER_SHELL_XML))
	$(WAYLAND_SCANNER) client-header $< $@

wlr-layer-shell-protocol.c: $(wildcard $(LAYER_SHELL_XML))
	$(WAYLAND_SCANNER) private-code $< $@

xdg-shell-client-protocol.h: $(wildcard $(XDG_SHELL_XML))
	$(WAYLAND_SCANNER) client-header $< $@

xdg-shell-protocol.c: $(wildcard $(XDG_SHELL_XML))
	$(WAYLAND_SCANNER) private-code $< $@

muelsyse-drop-helper: drop-helper.c $(PROTO_HEADERS) $(PROTO_SOURCES)
	$(CC) $(CFLAGS) $(WAYLAND_CFLAGS) -I. -o $@ drop-helper.c $(PROTO_SOURCES) $(WAYLAND_LIBS) $(LDFLAGS) -lm

install: muelsyse-drop-helper
	install -Dm755 muelsyse-drop-helper $(DESTDIR)$(PREFIX)/libexec/muelsyse-drop-helper

clean:
	rm -f muelsyse-drop-helper

.PHONY: all install clean
