#!/bin/bash
# Drive hyprglaze inside a nested, TWO-OUTPUT Hyprland, so multi-monitor
# behaviour can be tested on a machine with one physical display.
#
#   scripts/hypr-harness.sh <script-file> [out-dir]
#
# Why nested Hyprland and not sway: hyprglaze installs src/core/watcher.lua
# into Hyprland's Lua VM via `hyprctl eval` and refuses to start against a
# classic hyprland.conf. sway cannot host it at all.
#
# The host session is never driven. No ydotool, no input injection. Every
# mutating hyprctl carries -i "$NESTED_SIG", and the run aborts if that ever
# resolves to the host's signature.
#
# Sourced test bodies get:
#   $OUT                     artifacts dir
#   $NESTED_SIG $NESTED_WL   the nested instance
#   $AW $AH $AX $AY          MON_A (WAYLAND-1) size and origin, read back
#   $BW $BH $BX $BY          MON_B (WAYLAND-2) size and origin, read back
#   hc/hcj ARGS              hyprctl against the nested instance
#   E LUA                    hyprctl eval against the nested instance
#   start_daemon OUT TAG     launch hyprglaze pinned to an output
#   place CLS WS LX LY W H   open a probe window at monitor-local coords
#   shot NAME OUTPUT         grim one output into $OUT/shots/NAME.png
#   scan FILE COLOUR         "x0 y0 x1 y1 count" or "none"
#   ring_of FILE             bbox of the focused (red) or tracked (green) ring
#   expect EXPR DESC         assert and count
#   wait_for EXPR [SECS]     poll; a timeout ENDS THE RUN
#
# --- Hard-won constraints, all verified on Hyprland 0.56.1 -------------------
#
# * HYPRLAND_NO_SD_VARS=1 IS MANDATORY. Without it the nested Hyprland runs
#   `systemctl --user import-environment WAYLAND_DISPLAY
#   HYPRLAND_INSTANCE_SIGNATURE ...` at start and `unset-environment` at exit,
#   rewriting the HOST session's systemd/dbus activation environment to point
#   at the nested compositor and then clearing it. Every dbus-activated app in
#   the real session breaks afterwards.
#
# * Under a Lua config, `hyprctl dispatch <string>` and `hyprctl keyword` are
#   BOTH REJECTED ("keyword can't work with non-legacy parsers. Use eval.").
#   Everything goes through `hyprctl eval` + hl.dispatch(hl.dsp....).
#
# * `hyprctl eval` swallows return values — it prints "ok". To read state out
#   of Lua, dispatch a custom event or write a file from the chunk.
#
# * Hyprland's Lua objects are READ-ONLY: `w.floating = true` raises "attempt
#   to modify read-only hl object". Use the dispatchers.
#
# * `hyprctl dispatch exec` inherits the environment Hyprland was launched
#   with, which still points at the HOST display. Launch probe clients
#   directly with an explicit WAYLAND_DISPLAY/HYPRLAND_INSTANCE_SIGNATURE.
#
# * `hyprctl -i SIG output create wayland` works nested and yields WAYLAND-2;
#   `hl.monitor{}` via eval re-applies mode/position/scale at runtime.
#
# * j/monitors mixes units: width/height are PHYSICAL mode pixels, x/y are
#   LOGICAL. Verified by setting WAYLAND-1 to an 800x600 mode at scale 1.25
#   and watching an auto-positioned WAYLAND-2 land at x=640, not x=800.
#
# * MON_B is deliberately LARGER than its own origin offset. A window at
#   B-local (300,200) reports layout x=1100, so the coordinate bug paints
#   800px displaced but STILL ON SCREEN — a measurable delta rather than an
#   absence indistinguishable from "the daemon isn't running".
#
# * The probe shader draws the focused window's ring in RED over the GREEN
#   tracked-window ring. With a single window there is no green at all.
set -u

BODY=${1:?usage: hypr-harness.sh <script-file> [out-dir]}
OUT=${2:-$(mktemp -d /tmp/hgh.XXXXXX)}
BIN=${HG_BIN:-./zig-out/bin/hyprglaze}
LAYOUT=${HG_LAYOUT:-x}

cd "$(dirname "$0")/.." || exit 1
[ -x "$BIN" ] || { echo "no binary at $BIN — zig build first" >&2; exit 1; }
for t in Hyprland hyprctl grim jq python3 foot; do
    command -v "$t" >/dev/null || { echo "missing $t" >&2; exit 1; }
done
mkdir -p "$OUT/shots" "$OUT/cfg/hypr" "$OUT/state" "$OUT/cache"

HOST_SIG=${HYPRLAND_INSTANCE_SIGNATURE:-}
HOST_WL=${WAYLAND_DISPLAY:?not in a Wayland session}
[ -n "$HOST_SIG" ] || { echo "not inside Hyprland" >&2; exit 1; }

die() { echo "FATAL: $*" >&2; exit 1; }

# --------------------------------------------------------------- teardown ---
# Registered before anything starts; every kill is guarded on a possibly-empty
# pid. No pkill anywhere — `pkill -f <pattern>` matches the shell running it.
HYPR_PID=""; NESTED_SIG=""; DAEMON_PIDS=(); CLIENT_PIDS=()
cleanup() {
    local rc=$? p
    for p in ${DAEMON_PIDS[@]+"${DAEMON_PIDS[@]}"}; do kill "$p" 2>/dev/null; done
    for p in ${CLIENT_PIDS[@]+"${CLIENT_PIDS[@]}"}; do kill "$p" 2>/dev/null; done
    [ -n "$HYPR_PID" ] && kill "$HYPR_PID" 2>/dev/null
    for _ in $(seq 1 20); do
        kill -0 "${HYPR_PID:-0}" 2>/dev/null || break
        sleep 0.1
    done
    [ -n "$HYPR_PID" ] && kill -9 "$HYPR_PID" 2>/dev/null
    if [ -n "$NESTED_SIG" ] && [ "$NESTED_SIG" != "$HOST_SIG" ]; then
        rm -rf "${XDG_RUNTIME_DIR:?}/hypr/$NESTED_SIG"
    fi
    return $rc
}
trap cleanup EXIT INT TERM

cp tools/harness_nested.lua "$OUT/cfg/hypr/hyprland.lua"
cat > "$OUT/cfg/hypr/hyprglaze.toml" <<'TOML'
effect = "windowglow"
theme  = "Rosé Pine"

[transition]
duration = 0.0

# smoothAlpha clamps to [0.001, 0.999]; 0.001 => alpha ~1, i.e. snap in one
# frame. Nothing to wait out, and consecutive frames stay byte-identical.
[cursor]
smoothing = 0.001
[geometry]
smoothing = 0.001

[windowglow]
music = false   # no PipeWire capture thread
grain = 0.0     # kills the only time-varying term
TOML

# ------------------------------------------------------------------- boot ---
# XDG_RUNTIME_DIR stays the REAL one: isolation comes from the instance
# signature, so the 108-byte sun_path cap is avoided by construction
# (/run/user/1000/hypr/<sig>/.socket2.sock measures 95 bytes).
env -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    WAYLAND_DISPLAY="$HOST_WL" \
    HYPRLAND_NO_SD_VARS=1 HYPRLAND_NO_SD_NOTIFY=1 HYPRLAND_NO_CRASHREPORTER=1 \
    XDG_CONFIG_HOME="$OUT/cfg" XDG_STATE_HOME="$OUT/state" XDG_CACHE_HOME="$OUT/cache" \
    Hyprland -c "$OUT/cfg/hypr/hyprland.lua" >"$OUT/hypr.log" 2>&1 &
HYPR_PID=$!

for _ in $(seq 1 80); do
    NESTED_SIG=$(hyprctl -j instances 2>/dev/null |
        jq -r --argjson p "$HYPR_PID" '.[]|select(.pid==$p)|.instance')
    [ -n "$NESTED_SIG" ] && break
    kill -0 "$HYPR_PID" 2>/dev/null || die "Hyprland exited; see $OUT/hypr.log"
    sleep 0.25
done
[ -n "$NESTED_SIG" ] || die "nested Hyprland never registered; see $OUT/hypr.log"
[ "$NESTED_SIG" != "$HOST_SIG" ] || die "resolved to the HOST instance — aborting"
NESTED_WL=$(hyprctl -j instances | jq -r --arg s "$NESTED_SIG" \
    '.[]|select(.instance==$s)|.wl_socket')

hc()  { hyprctl -i "$NESTED_SIG" "$@"; }
hcj() { hyprctl -i "$NESTED_SIG" -j "$@"; }
E()   { hyprctl -i "$NESTED_SIG" eval "$1"; }

# -------------------------------------------------- second output + layout ---
hc output create wayland >/dev/null || die "output create wayland failed"
for _ in $(seq 1 40); do
    [ "$(hcj monitors | jq length)" = "2" ] && break; sleep 0.25
done
[ "$(hcj monitors | jq length)" = "2" ] || die "second output never appeared"

read_monitors() {
    eval "$(hcj monitors | jq -r '
      (.[]|select(.name=="WAYLAND-1")) as $a | (.[]|select(.name=="WAYLAND-2")) as $b |
      "AW=\($a.width); AH=\($a.height); AX=\($a.x); AY=\($a.y);
       BW=\($b.width); BH=\($b.height); BX=\($b.x); BY=\($b.y)"')"
}

apply_layout() {
    case "$1" in
      x)    a_mode=800x600;  b_mode=1600x1200; b_pos=800x0 ;;
      y)    a_mode=800x600;  b_mode=1600x1200; b_pos=0x600 ;;
      side) a_mode=1280x800; b_mode=1280x800;  b_pos=1280x0 ;;
      *)    die "unknown layout '$1' (want x|y|side)" ;;
    esac
    E "hl.monitor({ output = 'WAYLAND-1', mode = '$a_mode', position = '0x0', scale = 1 })" >/dev/null
    E "hl.monitor({ output = 'WAYLAND-2', mode = '$b_mode', position = '$b_pos', scale = 1 })" >/dev/null
    sleep 1
    read_monitors
    # If B's origin came back (0,0) every scenario passes vacuously.
    [ "$BX" -ne 0 ] || [ "$BY" -ne 0 ] || die "MON_B origin is (0,0) — the test would be vacuous"
}
apply_layout "$LAYOUT"

# ---------------------------------------------------------------- helpers ---
start_daemon() {   # OUTPUT TAG
    env -u DISPLAY WAYLAND_DISPLAY="$NESTED_WL" HYPRLAND_INSTANCE_SIGNATURE="$NESTED_SIG" \
        XDG_CONFIG_HOME="$OUT/cfg" XDG_STATE_HOME="$OUT/state" \
        "$BIN" --config "$OUT/cfg/hypr/hyprglaze.toml" \
               --effect windowglow --shader tools/harness_probe.frag \
               --output "$1" >"$OUT/hyprglaze-$2.log" 2>&1 &
    DAEMON_PIDS+=($!)
    eval "DAEMON_${2}_PID=$!"
    wait_for "hcj layers | jq -e --arg m '$1' '.[\$m].levels[\"0\"][]?|select(.namespace==\"hyprglaze\")' >/dev/null" 15
}

place() {          # CLASS WS LOCAL_X LOCAL_Y W H   (monitor-local coords)
    local cls=$1 ws=$2 lx=$3 ly=$4 w=$5 h=$6 ox=0 oy=0
    case "$ws" in 1[0-9]) ox=$BX; oy=$BY ;; esac
    local gx=$(( lx + ox )) gy=$(( ly + oy ))
    # Launch directly: `dispatch exec` would inherit the HOST display.
    env -u DISPLAY WAYLAND_DISPLAY="$NESTED_WL" HYPRLAND_INSTANCE_SIGNATURE="$NESTED_SIG" \
        foot --app-id="$cls" >/dev/null 2>&1 &
    CLIENT_PIDS+=($!)
    wait_for "hcj clients | jq -e --arg c '$cls' '.[]|select(.class==\$c)' >/dev/null" 15
    E "for _,w in ipairs(hl.get_windows()) do if w.class=='$cls' then hl.dispatch(hl.dsp.window.move({ workspace = $ws })) end end" >/dev/null
    sleep 0.4
    E "hl.dispatch(hl.dsp.window.float({ action = 'on' }))" >/dev/null; sleep 0.4
    E "hl.dispatch(hl.dsp.window.resize({ x = $w, y = $h, relative = false }))" >/dev/null; sleep 0.4
    E "hl.dispatch(hl.dsp.window.move({ x = $gx, y = $gy, relative = false }))" >/dev/null
    # Never trust the request; the read-back is the ground truth.
    wait_for "[ \"\$(hcj clients | jq -r --arg c '$cls' '.[]|select(.class==\$c)|\"\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])\"')\" = \"$gx $gy $w $h\" ]" 10
}

shot() { sleep 0.4; WAYLAND_DISPLAY="$NESTED_WL" grim -o "$2" "$OUT/shots/$1.png" 2>>"$OUT/grim.log"; }
scan() { python3 tools/harness_scan.py "$1" "$2"; }

# The focused window's ring is red; unfocused tracked windows are green.
ring_of() { local r; r=$(scan "$1" red); [ "$r" = none ] && r=$(scan "$1" green); echo "$r"; }

FAILED=0
expect() {         # EXPR DESC
    if eval "$1" >/dev/null 2>&1; then echo "  ok   $2"
    else echo "  FAIL $2"; FAILED=$((FAILED + 1)); fi
}
wait_for() {       # EXPR [SECS] — a timeout ends the run: once compositor
                   # state is unknown, later measurements mean nothing.
    local deadline=$(( SECONDS + ${2:-10} ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        eval "$1" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    echo "TIMEOUT waiting for: $1" >&2
    echo "  stopping: compositor state is no longer known, so every later" >&2
    echo "  assertion would be measuring nothing." >&2
    echo "$OUT"; exit 1
}

"$BIN" --help 2>&1 | grep -q -- '--output' ||
    echo "NOTE: this build has no --output flag; expect a red baseline" >&2

echo "nested=$NESTED_SIG wl=$NESTED_WL"
echo "MON_A ${AW}x${AH} @($AX,$AY)   MON_B ${BW}x${BH} @($BX,$BY)"

# shellcheck source=/dev/null
. "$BODY"

if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED check(s) failed; artifacts in $OUT" >&2; echo "$OUT"; exit 1
fi
echo "all checks passed; artifacts in $OUT"
echo "$OUT"
