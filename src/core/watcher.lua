-- hyprglaze in-compositor state watcher. Installed via `hyprctl eval` at
-- daemon startup and re-installed whenever Hyprland reloads its config
-- (the Lua state is recreated) or the heartbeat lapses.
--
-- Pushes compact events onto socket2 (`custom>>hg:...`) so the daemon
-- never has to poll `.socket.sock`:
--   hg:cur:<x>,<y>              cursor moved (floored layout coords)
--   hg:geo:<wsid>\29<records>   active workspace id + the window strip:
--                               active workspace windows plus those on
--                               its nearest existing neighbor workspaces
--                               (same monitor), emitted when anything
--                               changed; records joined by \30, fields
--                               by \31:
--                               addr \31 x \31 y \31 w \31 h \31 class
--                               \31 title \31 rel
--                               rel is -1 (previous), 0 (active) or 1
--                               (next); active records come first so the
--                               daemon's 32-window cap favors them. wsid
--                               rides with the geometry so workspace
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
    local wsid_n = (type(ws) == "number" and ws) or (ws and ws.id) or 0

    -- Nearest existing neighbor workspaces on the same monitor (ids have
    -- gaps, so "adjacent" is the closest id, not id±1). Specials
    -- (negative ids) never join the strip.
    local rel_of = {}
    if wsid_n > 0 then
        rel_of[wsid_n] = 0
        local ws_mon = type(ws) ~= "number" and ws and ws.monitor or nil
        local prev_id, next_id = nil, nil
        for _, other in ipairs(hl.get_workspaces()) do
            local oid = other.id
            if oid > 0 and oid ~= wsid_n and (not ws_mon or other.monitor == ws_mon) then
                if oid < wsid_n and (not prev_id or oid > prev_id) then prev_id = oid end
                if oid > wsid_n and (not next_id or oid < next_id) then next_id = oid end
            end
        end
        if prev_id then rel_of[prev_id] = -1 end
        if next_id then rel_of[next_id] = 1 end
    end

    local buckets = { [-1] = {}, [0] = {}, [1] = {} }
    for _, w in ipairs(hl.get_windows({ mapped = true })) do
        if w.visible then
            local wid = (type(w.workspace) == "number" and w.workspace)
                or (w.workspace and w.workspace.id)
            local rel = wid and rel_of[wid]
            -- Unknown active id: degrade to the old active-only filter.
            if not rel and wsid_n <= 0 and w.workspace == ws then rel = 0 end
            if rel then
                local b = buckets[rel]
                b[#b + 1] = table.concat({
                    w.address,
                    string.format("%.0f", w.at.x),
                    string.format("%.0f", w.at.y),
                    string.format("%.0f", w.size.x),
                    string.format("%.0f", w.size.y),
                    clean(w.class),
                    clean(w.title),
                    tostring(rel),
                }, FS)
            end
        end
    end
    local parts = {}
    for _, rel in ipairs({ 0, -1, 1 }) do
        for _, rec in ipairs(buckets[rel]) do
            parts[#parts + 1] = rec
        end
    end
    -- wsid may be a Lua float (like w.at/w.size); %.0f avoids "4.0".
    local wsid = string.format("%.0f", wsid_n)
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
