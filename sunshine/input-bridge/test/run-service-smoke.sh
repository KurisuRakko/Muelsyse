#!/bin/bash
# Smoke test against the *deployed* bridge: it assumes
# rakkord-sunshine-input.service is already running and does not start a second
# bridge instance (two bridges would inject every event twice).
#
# It drives throw-away "Sunshine (libvirtualhid)" devices and prints what KWin
# actually delivered to a minimal Wayland client, proving the whole deployed
# path (systemd unit -> desktop file -> fake_input -> KWin) works.
set -u
dir="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$dir")"
out="$root/test-results"
mkdir -p "$out"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY=wayland-remote-desktop

if [ "$(systemctl --user is-active rakkord-sunshine-input.service)" != "active" ]; then
    echo "rakkord-sunshine-input.service is not active - start it first" >&2
    exit 1
fi

"$dir/wl-input-probe" 22 > "$out/service-smoke-probe.log" 2>&1 &
probe=$!
sleep 2.5

"$dir/uinput-dev" abs   32767 800 > "$out/service-smoke-abs.out"   2>&1
"$dir/uinput-dev" rel   0     800 > "$out/service-smoke-rel.out"   2>&1
"$dir/uinput-dev" wheel 0     800 > "$out/service-smoke-wheel.out" 2>&1
"$dir/uinput-dev" kbd   0     800 > "$out/service-smoke-kbd.out"   2>&1

wait "$probe"
echo "logs in $out"
