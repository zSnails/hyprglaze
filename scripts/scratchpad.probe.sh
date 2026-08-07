# Probe: what the WATCHER sees while a special workspace is open.
#
#   scripts/hypr-harness.sh scripts/scratchpad.probe.sh
#
# The watcher filters windows on `w.visible` and maps them by workspace id, so
# whether a scratchpad can overlay the strip depends entirely on what those two
# report — which is not the same as what `hyprctl clients` shows. Writes via
# Lua's io directly; hl.exec_cmd quoting is not worth fighting.

lua_dump() {   # LABEL
    E "local f = io.open('$OUT/lua-$1.txt', 'w')
       for _, m in ipairs(hl.get_monitors()) do
         local fn = hl.get_active_workspace and hl.get_active_workspace(m)
         f:write('MON ', m.name,
           ' m.active_workspace=', tostring(m.active_workspace and m.active_workspace.id),
           ' m.active_special=', tostring(m.active_special_workspace and m.active_special_workspace.id),
           ' get_active_workspace(m)=', tostring(fn and fn.id), '\n')
       end
       for _, w in ipairs(hl.get_windows({ mapped = true })) do
         f:write('WIN ', tostring(w.class),
           ' ws=', tostring(w.workspace and w.workspace.id),
           ' visible=', tostring(w.visible),
           ' hidden=', tostring(w.hidden), '\n')
       end
       f:close()" >/dev/null
    sleep 0.8
    if [ -f "$OUT/lua-$1.txt" ]; then
        echo "  --- $1 ---"
        sed 's/^/    /' "$OUT/lua-$1.txt"
    else
        echo "  --- $1: NO OUTPUT (io.open unavailable in the Lua sandbox) ---"
    fi
}

place probe-x 11 300 200 500 400
lua_dump before

echo "  opening a special workspace on MON_B and putting a window in it"
E "hl.dispatch(hl.dsp.workspace.toggle_special({ name = 'scratch' }))" >/dev/null
sleep 1.5
lua_dump during-empty

env -u DISPLAY WAYLAND_DISPLAY="$NESTED_WL" HYPRLAND_INSTANCE_SIGNATURE="$NESTED_SIG" \
    foot --app-id=probe-scratch >/dev/null 2>&1 &
CLIENT_PIDS+=($!)
sleep 3
lua_dump during-populated

E "hl.dispatch(hl.dsp.workspace.toggle_special({ name = 'scratch' }))" >/dev/null
sleep 1.5
lua_dump after
