# Multi-monitor scenarios. Sourced by scripts/hypr-harness.sh — see that file
# for the helper contract and the compositor constraints.
#
#   scripts/hypr-harness.sh scripts/multimonitor.test.sh
#   HG_LAYOUT=y scripts/hypr-harness.sh scripts/multimonitor.test.sh
#
# The probe shader draws a ring PAD(12) + TH(2) = 14px outside each window
# rect. The daemon flips into GL space (y up) and grim writes rows top-down,
# so the two flips cancel: a window at monitor-local (x, y, w, h) must produce
# a ring bbox of exactly (x-14, y-14) .. (x+w+14, y+h+14) in PNG coordinates.

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
echo "    ring bbox=($x0,$y0)..($x1,$y1)  expected=(286,186)..(814,614)"
if [ "$x0" -ne 286 ]; then
    echo "    delta_x=$(( x0 - 286 ))  MON_B origin_x=$BX" \
         "$([ $(( x0 - 286 )) -eq "$BX" ] && echo '<- equals the origin: layout coords reach the shader unrebased')"
fi
expect "[ $x0 -eq 286 ]" "ring left edge at window_x - 14"
expect "[ $y0 -eq 186 ]" "ring top edge at window_y - 14"
expect "[ $x1 -eq 814 ]" "ring right edge at window_x + w + 14"
expect "[ $y1 -eq 614 ]" "ring bottom edge at window_y + h + 14"

echo
echo "S3  the tracked window set is pinned, not focus-following"
shot s3_focus_b WAYLAND-2
place probe-a 1 100 100 300 200
wait_for "[ \"\$(hcj monitors | jq -r '.[]|select(.focused)|.name')\" = WAYLAND-1 ]" 10
shot s3_focus_a WAYLAND-2
expect "cmp -s $OUT/shots/s3_focus_b.png $OUT/shots/s3_focus_a.png" \
       "WAYLAND-2 is unchanged when focus moves to WAYLAND-1"

echo
echo "S4  two instances, one per monitor, each tracking only its own"
shot s4_a_solo WAYLAND-1
start_daemon WAYLAND-1 a
shot s4_a_dual WAYLAND-1
shot s4_b_dual WAYLAND-2
read -r ax0 ay0 _ _ _ <<<"$(ring_of "$OUT/shots/s4_a_dual.png")"
read -r bx0 by0 _ _ _ <<<"$(ring_of "$OUT/shots/s4_b_dual.png")"
# A's window is at A-local (100,100); B's is at B-local (300,200).
expect "[ '$ax0' = '86'  ]" "WAYLAND-1 instance tracks its own window (x-14=86)"
expect "[ '$bx0' = '286' ]" "WAYLAND-2 instance tracks its own window (x-14=286)"
expect "[ '$ay0' = '86'  ]" "WAYLAND-1 instance y is local too"
expect "[ '$by0' = '186' ]" "WAYLAND-2 instance y is local too"
# The second install must not have killed the first daemon's watcher timer.
sleep 12
expect "! grep -qi 'heartbeat' $OUT/hyprglaze-a.log" "no watcher reinstall storm on instance A"
expect "! grep -qi 'heartbeat' $OUT/hyprglaze-b.log" "no watcher reinstall storm on instance B"

echo
echo "S5  cursor is monitor-local on the offset output"
E "hl.dispatch(hl.dsp.cursor.move({ x = $(( BX + 400 )), y = $(( BY + 300 )) }))" >/dev/null
wait_for "[ \"\$(hcj cursorpos)\" = \"$(( BX + 400 )), $(( BY + 300 ))\" ]" 5
shot s5_b WAYLAND-2
read -r cx0 cy0 cx1 cy1 _ <<<"$(scan "$OUT/shots/s5_b.png" blue)"
expect "[ $(( (cx0 + cx1) / 2 )) -eq 400 ]" "crosshair x is MON_B-local 400"
expect "[ $(( (cy0 + cy1) / 2 )) -eq 300 ]" "crosshair y is MON_B-local 300"
