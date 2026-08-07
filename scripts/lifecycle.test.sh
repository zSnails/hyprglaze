# Exercise the paths the code review found broken, rather than reasoning about
# them. Every scenario here corresponds to a fix that was written blind once
# already and was wrong.
#
#   scripts/hypr-harness.sh scripts/lifecycle.test.sh
#
# One daemon throughout: several layer surfaces on one output produce dropped
# frames that look like tracking bugs.

start_daemon $MON_B lc
place probe-l 11 300 200 500 400
shot base $MON_B
read -r b0 b1 b2 b3 _ <<<"$(ring_of "$OUT/shots/base.png")"
echo "    ring=($b0,$b1)..($b2,$b3)"
expect "[ '$b0' = '$(ring_x0 300)' ]" "baseline: the daemon is tracking its window"

echo
echo "L1  a resolution change rebuilds the effect at the new buffer size"
# Previously the rebuild was gated on the SCALE changing, so a plain mode
# switch updated glViewport while every effect kept its old bounds.
E "hl.monitor({ output = '$MON_B', mode = '1280x1024', position = '${BX}x${BY}', scale = 1 })" >/dev/null
wait_for "[ \"\$(hcj monitors | jq -r --arg m '$MON_B' '.[]|select(.name==\$m)|.width')\" = 1280 ]" 10
sleep 1.5
expect "grep -q 'surface configured: 1280x1024' $OUT/hyprglaze-lc.log" "surface reconfigured to the new mode"
expect "! grep -qi 'effect resize.*failed' $OUT/hyprglaze-lc.log" "the effect rebuilt without error"
# The window is still at B-local (300,200); the ring must follow onto the
# smaller surface rather than being drawn against stale bounds.
shot resized $MON_B
resized=$(ring_of "$OUT/shots/resized.png")
expect "[ '$resized' != none ]" "still tracking after the mode change"
E "hl.monitor({ output = '$MON_B', mode = '1600x1200', position = '${BX}x${BY}', scale = 1 })" >/dev/null
sleep 1.5
read_monitors

echo
echo "L2  losing the pinned output exits non-zero"
# The check used to sit inside the loop body, where `should_close` — set by the
# same dispatch that sets target_gone — ended the loop first and the process
# exited 0, which Restart=on-failure ignores.
start_daemon $MON_A gone
gone_pid=$DAEMON_gone_PID
E "hl.monitor({ output = '$MON_A', disabled = true })" >/dev/null
for _ in $(seq 1 40); do kill -0 "$gone_pid" 2>/dev/null || break; sleep 0.25; done
if kill -0 "$gone_pid" 2>/dev/null; then
    expect false "the daemon exited after its output was disabled"
else
    wait "$gone_pid" 2>/dev/null; rc=$?
    echo "    exit code=$rc"
    expect "[ $rc -ne 0 ]" "exit code is non-zero so Restart=on-failure fires"
    expect "grep -q 'was removed' $OUT/hyprglaze-gone.log" "and it logged which output went"
fi
E "hl.monitor({ output = '$MON_A', mode = '800x600', position = '0x0', scale = 1, disabled = false })" >/dev/null
sleep 1

echo
echo "L3  the surviving instance is unaffected"
# A monitor disappearing must not disturb the daemon pinned to the other one.
expect "kill -0 $DAEMON_lc_PID 2>/dev/null" "the $MON_B daemon is still running"
shot survivor $MON_B
expect "[ \"\$(ring_of $OUT/shots/survivor.png)\" != none ]" "and still tracking its own window"
