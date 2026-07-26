-- hyprglaze in-compositor state watcher. Installed via `hyprctl eval` at
-- daemon startup and re-installed whenever Hyprland reloads its config
-- (the Lua state is recreated) or the heartbeat lapses.
--
-- Pushes compact events onto socket2 (`custom>>hg:...`) so the daemon
-- never has to poll `.socket.sock`:
--   hg:cur:<x>,<y>              cursor moved (floored layout coords)
--   hg:geo:<wsid>\29<records>   active workspace id + visible windows,
--                               emitted when either changed; records
--                               joined by \30, fields by \31:
--                               addr \31 x \31 y \31 w \31 h \31 class \31 title
--                               wsid rides with the geometry so workspace
--                               identity and window set stay atomic
--   hg:hb                       heartbeat, every 128 ticks (~2s)
--
-- Class/title are stripped of control characters (so they can never
-- contain the separators or a newline) and truncated to 64 bytes.
-- Dispatcher objects must go through hl.dispatch(); calling the closure
-- directly is an error on 0.56.

if __hyprglaze and __hyprglaze.t then
    __hyprglaze.t:set_enabled(false)
end
__hyprglaze = {}

local FS, RS, GS = string.char(31), string.char(30), string.char(29)
local last_geo, last_cx, last_cy, ticks = nil, nil, nil, 0

local function clean(s)
    return string.sub(string.gsub(s or "", "[%z\1-\31\127]", ""), 1, 64)
end

__hyprglaze.t = hl.timer(function()
    local c = hl.get_cursor_pos()
    local cx, cy = math.floor(c.x), math.floor(c.y)
    if cx ~= last_cx or cy ~= last_cy then
        last_cx, last_cy = cx, cy
        hl.dispatch(hl.dsp.event("hg:cur:" .. cx .. "," .. cy))
    end

    local ws = hl.get_active_workspace()
    -- ws.id may be a Lua float (like w.at/w.size); %.0f avoids "4.0".
    local wsid = string.format("%.0f", (type(ws) == "number" and ws) or (ws and ws.id) or 0)

    local parts = {}
    for _, w in ipairs(hl.get_windows({ workspace = ws, mapped = true })) do
        if w.visible then
            parts[#parts + 1] = table.concat({
                w.address,
                string.format("%.0f", w.at.x),
                string.format("%.0f", w.at.y),
                string.format("%.0f", w.size.x),
                string.format("%.0f", w.size.y),
                clean(w.class),
                clean(w.title),
            }, FS)
        end
    end
    -- Compare wsid + records together: a switch between two identically
    -- laid out (e.g. both empty) workspaces must still emit.
    local geo = wsid .. GS .. table.concat(parts, RS)
    if geo ~= last_geo then
        last_geo = geo
        hl.dispatch(hl.dsp.event("hg:geo:" .. geo))
    end

    ticks = ticks + 1
    if ticks % 128 == 0 then
        hl.dispatch(hl.dsp.event("hg:hb"))
    end
end, { timeout = 16, type = "repeat" })
