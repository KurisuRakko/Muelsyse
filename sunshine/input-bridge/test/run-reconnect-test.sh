#!/bin/bash
# Reconnect test: the bridge must survive losing the compositor connection
# (e.g. KWin restarting or the Selkies session being rebuilt), re-bind the
# privileged interface and start injecting input again.
#
# A socat proxy sits in front of the real KWin socket and is killed/restarted
# underneath the bridge.  Two details matter:
#
#   * KWin authorises org_kde_kwin_fake_input by inspecting the *peer process*
#     of the socket (SO_PEERCRED).  Behind a proxy that peer is the proxy, not
#     the bridge, so the proxy needs its own .desktop file.  We use a private
#     copy of socat plus a throw-away desktop file (both removed on exit) so no
#     system-wide binary ever gets the privilege.
#   * The probe connects straight to the real socket, otherwise the proxy
#     restart would tear down the probe too and there would be nothing left to
#     observe phase 4 with.
set -u
dir="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$dir")"
out="$root/test-results"
mkdir -p "$out"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
real="$XDG_RUNTIME_DIR/wayland-remote-desktop"
proxy="$XDG_RUNTIME_DIR/wayland-bridgeproxy"

proxbin="$dir/wl-socket-proxy"
proxdesk="$HOME/.local/share/applications/wl-socket-proxy.desktop"

pids=()
cleanup() {
    pkill -f "$proxbin" 2>/dev/null
    for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done
    unlink "$proxy" 2>/dev/null
    unlink "$proxdesk" 2>/dev/null
    unlink "$proxbin" 2>/dev/null
}
trap cleanup EXIT

# --- test-only scaffolding: private proxy copy + matching desktop file --------
cp /usr/bin/socat "$proxbin"
cat > "$proxdesk" <<EOF
[Desktop Entry]
Type=Application
Name=Wayland socket proxy (rakkord-sunshine-input-bridge reconnect test)
Exec=$proxbin
X-KDE-Wayland-Interfaces=org_kde_kwin_fake_input
NoDisplay=true
EOF
# Let KService pick the file up.
kbuildsycoca6 >/dev/null 2>&1 || true
sleep 1

: > "$out/reconnect-phases.log"
[ -e "$proxy" ] && unlink "$proxy"
sleep 0.5

"$proxbin" UNIX-LISTEN:"$proxy",fork UNIX-CONNECT:"$real" &
socpid=$!
pids+=("$socpid")
sleep 0.5

WAYLAND_DISPLAY=wayland-bridgeproxy "$HOME/.local/libexec/rakkord-sunshine-input-bridge" --trace > "$out/bridge-reconnect.log" 2>&1 &
bridepid=$!
pids+=("$bridepid")

# Probe goes straight to the real compositor so it survives the proxy outage.
WAYLAND_DISPLAY=wayland-remote-desktop "$dir/wl-input-probe" 45 > "$out/probe-reconnect.log" 2>&1 &
probepid=$!
pids+=("$probepid")
sleep 3

echo "--- phase 1: input through the proxy" >> "$out/reconnect-phases.log"
"$dir/uinput-dev" rel 0 800 > "$out/reconnect-rel1.out" 2>&1
sleep 0.5
"$dir/uinput-dev" abs 32767 800 > "$out/reconnect-abs1.out" 2>&1

echo "--- phase 2: kill the proxy (compositor connection breaks)" >> "$out/reconnect-phases.log"
# socat -fork keeps an established connection inside a forked child, so killing
# only the listener would leave the bridge's socket alive.  Kill the whole
# private proxy copy (parent + children).
pkill -f "$proxbin" 2>/dev/null
wait "$socpid" 2>/dev/null
sleep 4

echo "--- phase 3: bring the proxy back" >> "$out/reconnect-phases.log"
[ -e "$proxy" ] && unlink "$proxy"
"$proxbin" UNIX-LISTEN:"$proxy",fork UNIX-CONNECT:"$real" &
socpid2=$!
pids+=("$socpid2")
sleep 5

echo "--- phase 4: input again (bridge must have re-bound and re-authenticated)" >> "$out/reconnect-phases.log"
"$dir/uinput-dev" rel 0 800 > "$out/reconnect-rel2.out" 2>&1
sleep 0.5
"$dir/uinput-dev" abs 32767 800 > "$out/reconnect-abs2.out" 2>&1

wait "$probepid" 2>/dev/null
echo "logs in $out"
