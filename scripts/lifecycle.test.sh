# Exercise the paths a code review found broken, rather than reasoning about
# them. Every scenario here corresponds to a fix that was written blind once
# already and was wrong.
#
#   scripts/hypr-harness.sh scripts/lifecycle.test.sh
#
# Needs the host compositor to leave the nested output's window alone; the
# harness says which rule to add if it has not been.

start_daemon $MON_B lc
place probe-l 11 300 200 500 400
shot base $MON_B
read -r b0 b1 b2 b3 _ <<<"$(ring_of "$OUT/shots/base.png")"
echo "    ring=($b0,$b1)..($b2,$b3)"
expect "[ '$b0' = '$(ring_x0 300)' ]" "baseline: the daemon is tracking its window"

echo
echo "L1  a resolution change rebuilds the effect at the new buffer size"
# The rebuild used to be gated on the SCALE changing, so a plain mode switch
# updated glViewport while every effect kept its old bounds. Asserted through
# the geometry rather than a log line: the daemon logs nothing on resize, and
# what matters is that the ring still lands where the window is once the
# surface is a different size.
E "hl.monitor({ output = '$MON_B', mode = '1280x1024', position = '${BX}x${BY}', scale = 1 })" >/dev/null
wait_for "[ \"\$(hcj monitors | jq -r --arg m '$MON_B' '.[]|select(.name==\$m)|.width')\" = 1280 ]" 10
sleep 1.5
shot resized $MON_B
resized=$(ring_of "$OUT/shots/resized.png")
if [ "$resized" = none ]; then
    expect false "still tracking after the mode change"
else
    read -r r0 r1 _ _ _ <<<"$resized"
    echo "    ring after resize=($r0,$r1)  expected=($(ring_x0 300),$(ring_y0 200))"
    expect "[ '$r0' = '$(ring_x0 300)' ]" "ring x still tracks the window on the new surface"
    expect "[ '$r1' = '$(ring_y0 200)' ]" "ring y still tracks it (the y flip uses the new height)"
fi
expect "! grep -qi 'effect resize.*failed' $OUT/hyprglaze-lc.log" "the effect rebuilt without error"
expect "! grep -qi 'stuck at the old size' $OUT/hyprglaze-lc.log" "and did not exhaust its retries"
E "hl.monitor({ output = '$MON_B', mode = '1600x1200', position = '${BX}x${BY}', scale = 1 })" >/dev/null
sleep 1.5
read_monitors

echo
echo "L2  losing the pinned output exits non-zero"
# The check used to sit inside the loop body, where should_close — set by the
# same dispatch that sets target_gone — ended the loop first, so the process
# exited 0 and Restart=on-failure ignored it.
start_daemon $MON_A gone
# Disabling, not `output remove`. Measured (scripts/facts.probe.sh): disabling
# does drop the output from the monitor list and its wl_output global with it,
# which is what a client sees on an unplug. `output remove` reports success on
# a backend-created output and leaves it in place, so the daemon correctly
# never notices and the scenario hangs.
E "hl.monitor({ output = '$MON_A', disabled = true })" >/dev/null
wait_exit "$DAEMON_gone_PID" 45
echo "    exit code=$EXIT_CODE"
# -1 means it never exited. Assert a real, positive status: `-ne 0` alone
# would pass on the timeout sentinel and call a hung daemon a success.
expect "[ $EXIT_CODE -gt 0 ]" "exit code is non-zero so Restart=on-failure fires"
expect "grep -q \"output '$MON_A' was removed\" $OUT/hyprglaze-gone.log" "and it named the output that went"
E "hl.monitor({ output = '$MON_A', mode = '800x600', position = '0x0', scale = 1, disabled = false })" >/dev/null
sleep 1

echo
echo "L3  the surviving instance is unaffected"
# A monitor disappearing must not disturb the daemon pinned to the other one.
expect "kill -0 $DAEMON_lc_PID 2>/dev/null" "the $MON_B daemon is still running"
shot survivor $MON_B
survivor=$(ring_of "$OUT/shots/survivor.png")
expect "[ '$survivor' != none ]" "and still tracking its own window"
expect "! grep -qi 'was removed' $OUT/hyprglaze-lc.log" "and never thought its own output had gone"
