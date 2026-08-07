# Two facts the lifecycle scenarios assumed without checking. Both assumptions
# produced failures that looked like product bugs.
#
#   scripts/hypr-harness.sh scripts/facts.probe.sh

echo "  --- does a floating window keep its position when the monitor shrinks? ---"
place probe-f 11 300 200 500 400
echo "    before: $(hcj clients | jq -r '.[]|select(.class=="probe-f")|"at=\(.at) size=\(.size)"')"
E "hl.monitor({ output = '$MON_B', mode = '1280x1024', position = '${BX}x${BY}', scale = 1 })" >/dev/null
sleep 2
echo "    after:  $(hcj clients | jq -r '.[]|select(.class=="probe-f")|"at=\(.at) size=\(.size)"')"
echo "    (B-local y would be at[1] - $BY; the ring sits 14px above that)"
E "hl.monitor({ output = '$MON_B', mode = '1600x1200', position = '${BX}x${BY}', scale = 1 })" >/dev/null
sleep 1.5

echo
echo "  --- does disabling an output remove its wl_output global? ---"
echo "    monitors before: $(hcj monitors | jq -r '[.[].name]|join(",")')"
E "hl.monitor({ output = '$MON_A', disabled = true })" >/dev/null
sleep 2
echo "    monitors after disable: $(hcj monitors | jq -r '[.[].name]|join(",")')"
echo "    wayland-info sees: $(WAYLAND_DISPLAY=$NESTED_WL wayland-info 2>/dev/null | grep -c "'wl_output'") wl_output global(s)"
E "hl.monitor({ output = '$MON_A', mode = '800x600', position = '0x0', scale = 1, disabled = false })" >/dev/null
sleep 2

echo
echo "  --- and does 'output remove' remove it? ---"
hc output remove "$MON_A" >/dev/null 2>&1 && echo "    output remove: accepted" || echo "    output remove: rejected"
sleep 2
echo "    monitors after remove: $(hcj monitors | jq -r '[.[].name]|join(",")')"
echo "    wayland-info sees: $(WAYLAND_DISPLAY=$NESTED_WL wayland-info 2>/dev/null | grep -c "'wl_output'") wl_output global(s)"
