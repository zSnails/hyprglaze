# Multi-monitor scenarios. Sourced by scripts/hypr-harness.sh — see that file
# for the helper contract and the compositor constraints.
#
#   scripts/hypr-harness.sh scripts/multimonitor.test.sh
#   HG_LAYOUT=y scripts/hypr-harness.sh scripts/multimonitor.test.sh
#
# The probe shader draws a ring PAD(12) + TH(2) = 14px outside each window
# rect. The daemon flips into GL space (y up) and grim writes rows top-down,
# so the two flips cancel: a window at monitor-local (x, y, w, h) produces a
# ring whose bbox is (x-14, y-14) .. (x+w+13, y+h+13) in PNG coordinates --
# the near edges land on x-14 exactly, the far ones a pixel inside x+w+14
# because the shader's band test is inclusive at both ends.
ring_x0() { echo $(( $1 - 14 )); }
ring_y0() { echo $(( $1 - 14 )); }
ring_x1() { echo $(( $1 + $2 + 13 )); }
ring_y1() { echo $(( $1 + $2 + 13 )); }

echo
echo "S0  monitor origins are logical, not physical"
# WAYLAND-1 at scale 1.25 makes an 800x600 mode 640x480 logical. An
# auto-positioned WAYLAND-2 lands at the LOGICAL right edge if x/y are logical.
E "hl.monitor({ output = 'WAYLAND-1', mode = '800x600', position = '0x0', scale = 1.25 })" >/dev/null
E "hl.monitor({ output = 'WAYLAND-2', mode = '1600x1200', position = 'auto', scale = 1 })" >/dev/null
sleep 1.2
probe_x=$(hcj monitors | jq -r '.[]|select(.name=="WAYLAND-2")|.x')
expect "[ '$probe_x' = '640' ]" "auto-placed WAYLAND-2 sits at logical x=640 (not physical 800)"
apply_layout "$LAYOUT"   # restore

echo
echo "S1  --output pins the layer surface to the named monitor"
start_daemon WAYLAND-2 b
on_b=$(hcj layers | jq -r '.["WAYLAND-2"].levels["0"][]?|select(.namespace=="hyprglaze")|.namespace')
on_a=$(hcj layers | jq -r '.["WAYLAND-1"].levels["0"][]?|select(.namespace=="hyprglaze")|.namespace')
expect "[ '$on_b' = 'hyprglaze' ]" "hyprglaze layer is on WAYLAND-2"
expect "[ -z '$on_a' ]"            "no hyprglaze layer on WAYLAND-1"
shot s1_a WAYLAND-1
# misc.background_color is magenta, so bare output == still magenta.
expect "[ \"\$(scan $OUT/shots/s1_a.png magenta)\" != none ]" "WAYLAND-1 is bare (sentinel intact)"

echo
echo "S2  window rects are monitor-local on an offset output"
place probe-b 11 300 200 500 400
shot s2_b WAYLAND-2
read -r x0 y0 x1 y1 _ <<<"$(ring_of "$OUT/shots/s2_b.png")"
e_x0=$(ring_x0 300); e_y0=$(ring_y0 200)
e_x1=$(ring_x1 300 500); e_y1=$(ring_y1 200 400)
echo "    ring bbox=($x0,$y0)..($x1,$y1)  expected=($e_x0,$e_y0)..($e_x1,$e_y1)"
if [ "$x0" -ne "$e_x0" ]; then
    echo "    delta_x=$(( x0 - e_x0 ))  MON_B origin_x=$BX" \
         "$([ $(( x0 - e_x0 )) -eq "$BX" ] && echo '<- equals the origin: layout coords reach the shader unrebased')"
fi
expect "[ $x0 -eq $e_x0 ]" "ring left edge at window_x - 14"
expect "[ $y0 -eq $e_y0 ]" "ring top edge at window_y - 14"
expect "[ $x1 -eq $e_x1 ]" "ring right edge tracks window width"
expect "[ $y1 -eq $e_y1 ]" "ring bottom edge tracks window height"

echo
echo "S3  the tracked window set is pinned, not focus-following"
shot s3_focus_b WAYLAND-2
place probe-a 1 100 100 300 200
# Focus workspace 1, which the nested config pins to WAYLAND-1. Explicit
# rather than relying on the placement above having left focus there.
E "hl.dispatch(hl.dsp.focus({ workspace = 1 }))" >/dev/null
wait_for "[ \"\$(hcj monitors | jq -r '.[]|select(.focused)|.name')\" = WAYLAND-1 ]" 10
shot s3_focus_a WAYLAND-2
# Compare the tracked geometry, not the bytes: the ring legitimately changes
# colour (red -> green) when focus leaves this monitor, so a byte compare
# would fail on correct behaviour. What must not change is WHICH window is
# traced -- before per-monitor events, this ring jumped to MON_A's window.
read -r bx0 by0 bx1 by1 _ <<<"$(ring_of "$OUT/shots/s3_focus_b.png")"
read -r ax0 ay0 ax1 ay1 _ <<<"$(ring_of "$OUT/shots/s3_focus_a.png")"
echo "    focus on B: ($bx0,$by0)..($bx1,$by1)   focus on A: ($ax0,$ay0)..($ax1,$ay1)"
expect "[ '$ax0 $ay0 $ax1 $ay1' = '$bx0 $by0 $bx1 $by1' ]" \
       "WAYLAND-2 keeps tracing its own window when focus moves to WAYLAND-1"
expect "[ '$ax0' = '$(ring_x0 300)' ]" "...and it is still MON_B's window, not MON_A's"

echo
echo "S4  two instances, one per monitor, each tracking only its own"
shot s4_a_solo WAYLAND-1
start_daemon WAYLAND-1 a
shot s4_a_dual WAYLAND-1
shot s4_b_dual WAYLAND-2
read -r ax0 ay0 _ _ _ <<<"$(ring_of "$OUT/shots/s4_a_dual.png")"
read -r bx0 by0 _ _ _ <<<"$(ring_of "$OUT/shots/s4_b_dual.png")"
# A's window is at A-local (100,100); B's is at B-local (300,200). Assert the
# window CONTENTS per instance, not just that both render: before per-monitor
# events both daemons carried the same global set, so a weaker check passed
# while nothing actually worked.
expect "[ '$ax0' = '$(ring_x0 100)' ]" "WAYLAND-1 instance tracks its own window"
expect "[ '$bx0' = '$(ring_x0 300)' ]" "WAYLAND-2 instance tracks its own window"
expect "[ '$ay0' = '$(ring_y0 100)' ]" "WAYLAND-1 instance y is local too"
expect "[ '$by0' = '$(ring_y0 200)' ]" "WAYLAND-2 instance y is local too"
# The second install must not have killed the first daemon's watcher timer.
sleep 12
expect "! grep -qi 'heartbeat' $OUT/hyprglaze-a.log" "no watcher reinstall storm on instance A"
expect "! grep -qi 'heartbeat' $OUT/hyprglaze-b.log" "no watcher reinstall storm on instance B"

echo
echo "S5  cursor is monitor-local on the offset output"
# Aim well clear of probe-b at B-local (300,200)+500x400: the window is opaque
# and composited above the background layer, so a crosshair inside its rect
# would be invisible no matter how correct the coordinate is.
#
# The assertion is against where the cursor ACTUALLY ended up, not where it was
# asked to go. wlrctl's pointer is relative (hence the corner slam), and the
# property under test is "crosshair == cursor - origin" — pinning an exact
# destination would only add a way for the test to fail for reasons unrelated
# to the daemon.
move_cursor $(( BX + 1200 )) $(( BY + 900 )) ||
    echo "    note: cursor did not converge on the target; asserting where it landed"

read -r gx gy <<<"$(hcj cursorpos | jq -r '"\(.x) \(.y)"')"
lx=$(( gx - BX )); ly=$(( gy - BY ))
echo "    cursor global=($gx,$gy)  MON_B-local=($lx,$ly)"
expect "[ $lx -ge 0 ] && [ $lx -lt $BW ] && [ $ly -ge 0 ] && [ $ly -lt $BH ]" \
       "cursor landed on MON_B"

shot s5_b WAYLAND-2
blue=$(scan "$OUT/shots/s5_b.png" blue)
if [ "$blue" = none ]; then
    expect false "cursor crosshair is visible (scan found no blue)"
else
    read -r cx0 cy0 cx1 cy1 _ <<<"$blue"
    mx=$(( (cx0 + cx1) / 2 )); my=$(( (cy0 + cy1) / 2 ))
    echo "    crosshair=($mx,$my)  expected=($lx,$ly)"
    # +/-10px, not exact: cursor.no_hardware_cursors composites the pointer
    # sprite into the output buffer, so grim captures the arrow sitting on top
    # of the crosshair and its darker pixels skew the blob's centre by a few
    # px. The failure this scenario exists to catch is an origin-sized one
    # (800px here), which no plausible sprite can mask.
    tol=10
    expect "[ $mx -ge $(( lx - tol )) ] && [ $mx -le $(( lx + tol )) ]" \
           "crosshair x tracks the cursor, rebased onto MON_B"
    expect "[ $my -ge $(( ly - tol )) ] && [ $my -le $(( ly + tol )) ]" \
           "crosshair y tracks the cursor, rebased onto MON_B"
fi

echo
echo "S6  a scaled output renders at native resolution, not upscaled"
# 1600x1200 mode at scale 1.25 is 1280x960 of logical space. The layer surface
# is configured logical; the buffer must come back up to the mode's real
# pixels, or a quarter of them never get drawn.
E "hl.monitor({ output = 'WAYLAND-2', mode = '1600x1200', position = '${BX}x${BY}', scale = 1.25 })" >/dev/null
sleep 1.5
read_monitors
start_daemon WAYLAND-2 scaled
sleep 1.5
logical=$(hcj monitors | jq -r '.[]|select(.name=="WAYLAND-2")|"\(.width / .scale | floor)x\(.height / .scale | floor)"')
echo "    monitor mode=${BW}x${BH} scale=1.25 -> logical $logical"
expect "grep -q 'rendering at ${BW}x${BH}' $OUT/hyprglaze-scaled.log" \
       "buffer is the mode's native ${BW}x${BH}, not the logical size"
expect "grep -q 'surface configured: ${logical}' $OUT/hyprglaze-scaled.log" \
       "layer surface is still configured in logical pixels"

# And the geometry must stay right in the new unit: a window at logical
# (300,200)+500x400 covers buffer (375,250)+625x500 at scale 1.25.
place probe-s 12 300 200 500 400
shot s6_b WAYLAND-2
read -r sx0 sy0 _ _ _ <<<"$(ring_of "$OUT/shots/s6_b.png")"
echo "    ring origin=($sx0,$sy0)  expected=(361,236)"
expect "[ $sx0 -ge 359 ] && [ $sx0 -le 363 ]" "window rect scales into buffer pixels (x)"
expect "[ $sy0 -ge 234 ] && [ $sy0 -le 238 ]" "window rect scales into buffer pixels (y)"
