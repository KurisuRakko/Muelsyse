#!/bin/bash
# End-to-end test for muelsyse-sunshine-input-bridge.
#
# Starts a fresh bridge + a Wayland input probe (fullscreen surface that prints
# every input event KWin delivers) and drives both with throw-away uinput
# devices that pretend to be Sunshine's libvirtualhid devices.
set -u
dir="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$dir")"
out="$root/test-results"
mkdir -p "$out"
export WAYLAND_DISPLAY=wayland-remote-desktop
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

sleep 0.5

"$HOME/.local/libexec/muelsyse-sunshine-input-bridge" --trace > "$out/bridge-trace.log" 2>&1 &
bridepid=$!
sleep 1
"$dir/wl-input-probe" 70 > "$out/probe.log" 2>&1 &
probepid=$!
sleep 2.5

# Park the pointer in the middle first: it must be inside the probe surface
# for pointer/keyboard focus to stay on it.
"$dir/uinput-dev" park 32767 800     > "$out/dev-park.out" 2>&1;      sleep 0.5
"$dir/uinput-dev" rel 0 800          > "$out/dev-rel.out" 2>&1;       sleep 0.5
"$dir/uinput-dev" wheel 0 800        > "$out/dev-wheel.out" 2>&1;     sleep 0.5
"$dir/uinput-dev" kbd 0 800          > "$out/dev-kbd.out" 2>&1;       sleep 0.5
"$dir/uinput-dev" park 32767 800     > "$out/dev-park2.out" 2>&1;     sleep 0.5
"$dir/uinput-dev" abs 32767 800      > "$out/dev-abs-32767.out" 2>&1; sleep 0.5
"$dir/uinput-dev" abs 65535 800      > "$out/dev-abs-65535.out" 2>&1; sleep 0.5
"$dir/uinput-dev" abs-edge 32767 800 > "$out/dev-abs-edge.out" 2>&1;  sleep 0.5

wait "$probepid"
kill "$bridepid" 2>/dev/null
wait "$bridepid" 2>/dev/null
echo "logs in $out"
