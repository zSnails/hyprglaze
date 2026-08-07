-- hyprglaze in-compositor state watcher. Installed via `hyprctl eval` at
-- daemon startup and re-installed whenever Hyprland reloads its config
-- (the Lua state is recreated) or the heartbeat lapses.
--
-- Pushes compact events onto socket2 (`custom>>hg:...`) so the daemon
-- never has to poll `.socket.sock`:
--   hg:cur:<x>,<y>              cursor moved (floored layout coords)
--   hg:mgeo:<mon>\29<wsid>\29<ox>\29<oy>\29<records>
--                               one event PER MONITOR, emitted when that
--                               monitor's state changed. <mon> is the
--                               output name, <ox>/<oy> its layout origin,
--                               <wsid> its active workspace, then the
--                               window strip: that workspace's windows
--                               plus those on its nearest existing
--                               neighbor workspaces on the same monitor.
--                               Records joined by \30, fields by \31:
--                               addr \31 x \31 y \31 w \31 h \31 class
--                               \31 title \31 rel
--                               rel is -1 (previous), 0 (active) or 1
--                               (next); active records come first so the
--                               32-window cap favors them. wsid and the
--                               origin ride with the geometry so workspace
--                               identity, monitor position and window set
--                               can never tear apart.
--   hg:hb                       heartbeat, every 128 ticks (~2s)
--
-- One watcher serves every daemon: each filters for its own monitor, so
-- there is a single 16ms timer no matter how many instances run. Emitting
-- per monitor also keeps each socket2 line under the daemon's 8KiB line
-- buffer, which a combined all-monitors event would overrun.
--
-- Coordinates stay GLOBAL layout coords on the wire; the origin travels in
-- the header and the daemon rebases. That keeps the record format byte
-- identical to what `hyprctl clients -j` reports, which matters when
-- debugging by eye.
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
-- Mirrors hypr.max_visible_windows. Capping here rather than daemon-side is
-- what makes the line budget a proof: 32 records plus the header cannot
-- reach the 8KiB socket2 line buffer, whose overflow is a silent truncation.
local MAX = 32
local ORDER = { 0, -1, 1 }
local last_geo, last_cx, last_cy, ticks = {}, nil, nil, 0

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

    local mons = hl.get_monitors()

    -- Each monitor's active workspace. Compare monitors by .id rather than
    -- by object identity: __eq is registered today but is optional on these
    -- objects, and an id compare cannot silently degrade to always-false.
    local midx, active = {}, {}
    for mi, m in ipairs(mons) do
        midx[m.id] = mi
        local ws = hl.get_active_workspace(m)
        local sp = hl.get_active_special_workspace and hl.get_active_special_workspace(m)
        local wsid = (type(ws) == "number" and ws) or (ws and ws.id) or 0
        -- A special workspace displaces the regular one on that monitor.
        if sp and sp.id and sp.id ~= 0 then wsid = sp.id end
        active[mi] = wsid
    end

    -- Nearest existing neighbor workspaces per monitor (ids have gaps, so
    -- "adjacent" is the closest id, not id±1). Specials never join a strip.
    local prev_id, next_id = {}, {}
    for _, other in ipairs(hl.get_workspaces()) do
        local om, oid = other.monitor, other.id
        local mi = om and midx[om.id]
        if mi and oid > 0 then
            local a = active[mi]
            if a > 0 and oid ~= a then
                if oid < a and (not prev_id[mi] or oid > prev_id[mi]) then prev_id[mi] = oid end
                if oid > a and (not next_id[mi] or oid < next_id[mi]) then next_id[mi] = oid end
            end
        end
    end

    -- Flat workspace -> (monitor, slot) maps, so the window pass below stays
    -- a single table index per window, exactly as cheap as before.
    local slot_mi, slot_rel, buckets = {}, {}, {}
    for mi = 1, #mons do
        buckets[mi] = { [-1] = {}, [0] = {}, [1] = {} }
        local a = active[mi]
        -- ~= 0 rather than > 0: a special workspace has a negative id and
        -- must still populate its monitor's active slot.
        if a ~= 0 then
            slot_mi[a], slot_rel[a] = mi, 0
            if a > 0 then
                local p, n = prev_id[mi], next_id[mi]
                if p then slot_mi[p], slot_rel[p] = mi, -1 end
                if n then slot_mi[n], slot_rel[n] = mi, 1 end
            end
        end
    end

    for _, w in ipairs(hl.get_windows({ mapped = true })) do
        if w.visible then
            local wid = (type(w.workspace) == "number" and w.workspace)
                or (w.workspace and w.workspace.id)
            local mi = wid and slot_mi[wid]
            if mi then
                local rel = slot_rel[wid]
                local b = buckets[mi][rel]
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

    local seen = {}
    for mi, m in ipairs(mons) do
        local parts, n = {}, 0
        for _, rel in ipairs(ORDER) do
            local b = buckets[mi][rel]
            for k = 1, #b do
                if n >= MAX then break end
                n = n + 1
                parts[n] = b[k]
            end
        end
        -- wsid and the origin may be Lua floats (like w.at/w.size); %.0f
        -- avoids rendering them as "4.0".
        local geo = m.name
            .. GS .. string.format("%.0f", active[mi])
            .. GS .. string.format("%.0f", m.x)
            .. GS .. string.format("%.0f", m.y)
            .. GS .. table.concat(parts, RS)
        -- Comparing the whole string means a monitor that merely MOVED
        -- re-emits with no window event involved, so a layout change to the
        -- left of a daemon's monitor corrects its origin within one tick.
        if geo ~= last_geo[m.name] then
            last_geo[m.name] = geo
            hl.dispatch(hl.dsp.event("hg:mgeo:" .. geo))
        end
        seen[m.name] = true
    end
    -- Drop cached state for unplugged monitors so a replug re-emits.
    for name in pairs(last_geo) do
        if not seen[name] then last_geo[name] = nil end
    end

    ticks = ticks + 1
    if ticks % 128 == 0 then
        hl.dispatch(hl.dsp.event("hg:hb"))
    end
end, { timeout = 16, type = "repeat" })
