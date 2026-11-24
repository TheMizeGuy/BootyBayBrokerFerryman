local ADDON, ns = ...

-- Marks (INTERFACES 5.6, decision 136): places another addon hands over in named sets, drawn on the world map
-- (Frames/MapMarks.lua) and the minimap (Frames/MiniMarks.lua), never part of a trip. A call is taken at once and
-- applied on the next frame; nothing is saved. A set keeps its marks as its map's landmass yards, listed cell by cell
-- in CELL-yard cells so the minimap reads only the cells near the player.
local M = {}
ns.Marks = M

M.POINTS, M.SETS, M.MARKS, M.SOURCES, M.LABEL, M.CELL = 400, 200, 4000, 4, 40, 256
M.rev, M.held = 0, 0        -- rises with every change applied; the sets applied

local floor, huge, remove, sort = math.floor, math.huge, table.remove, table.sort
local Env, Lead = ns.Env, ns.Lead
local TAKEN = { hand = true, pin = true, restore = true, corpse = true, guide = true }
local WAKE = { zone = true, minimap = true, loadEnd = true }
local WHOLE, LONG = 2 ^ 31 - 1, ("[^\128-\191][\128-\191]*"):rep(M.LABEL + 1)
local Secret = issecretvalue or function() return false end
-- Taken: by source { n = sets, marks = count, [1..n] = sets }, and the sources in the order first taken. Applied: the
-- sets by map and by landmass, each a list with n.
local sources, order, byMap, byLand, keys = {}, {}, {}, {}, {}      -- keys: a mark's cell while its set is built
local queued = false

local function Cell(i, j) return (i + 4096) * 8192 + j + 4096 end
local function Key(x, y) return Cell(floor(x / M.CELL), floor(y / M.CELL)) end
M.Cell = Cell

-- A label: 1 to LABEL characters (UTF-8), with no control character and no escape sequence.
local function Plain(s)
    return type(s) == "string" and s ~= "" and #s <= 4 * M.LABEL and not s:find("[%z\1-\31\127|]")
        and not s:find(LONG)
end
-- Points: a plain array of 0 to 2 * POINTS numbers from 0 to 1, an even count and no hole, read raw; one that raises
-- (a secret value in it) is refused.
local function Judge(p)
    local n, count = #p, 0
    if n > 2 * M.POINTS or n % 2 == 1 then return false end
    for k, v in pairs(p) do
        count = count + 1
        if not (type(k) == "number" and k % 1 == 0 and k >= 1 and k <= n and type(v) == "number" and v >= 0
            and v <= 1) then return false end
    end
    return count == n
end

local function Put(by, k, set)
    local list = by[k]
    if not list then list = { n = 0 }; by[k] = list end
    list.n = list.n + 1
    list[list.n] = set
end
local function Trim(by)
    for k, list in pairs(by) do
        if list.n == 0 then by[k] = nil else for i = list.n + 1, #list do list[i] = nil end end
    end
end
-- The sets taken become the sets applied, each stamped with the rev it is applied at.
local function Apply()
    queued = false
    for _, list in pairs(byMap) do list.n = 0 end
    for _, list in pairs(byLand) do list.n = 0 end
    local held, rev = 0, M.rev + 1
    for i = 1, #order do
        local src = sources[order[i]]
        for j = 1, src.n do
            Put(byMap, src[j].uiMap, src[j])
            Put(byLand, src[j].land, src[j])
            src[j].at = rev
        end
        held = held + src.n
    end
    Trim(byMap)
    Trim(byLand)
    M.held, M.rev = held, rev
    Lead.Mark("tick")
    Lead.Flush()
end
local function Queue() if not queued then queued = true; Env.After(0, Apply) end end

local function Find(src, uiMap, label)
    for i = 1, src and src.n or 0 do
        if src[i].uiMap == uiMap and src[i].label == label then return i, src[i] end
    end
end
local function Drop(name)
    sources[name] = nil
    for i = 1, #order do if order[i] == name then remove(order, i) break end end
end
-- The same places as the set holds, by the arithmetic that made them.
local function Same(set, p, n)
    if set.n ~= n then return false end
    local x, y, top, left, dx, dy = set.x, set.y, set.top, set.left, set.bottom - set.top, set.right - set.left
    for i = 1, n do
        if x[i] ~= top + dx * p[2 * i] or y[i] ~= left + dy * p[2 * i - 1] then return false end
    end
    return true
end
local function Less(a, b) return keys[a] < keys[b] end
-- A set's yards and box, ord its marks sorted by cell, and its cells: ck[1..c] their keys rising, cf[i] the place in
-- ord of cell i's first mark (the next cell's first, or n + 1, ends it). Arrays are reused: a set made again
-- allocates nothing.
local function Build(set, p, n, m, top, left, bottom, right)
    local x, y, ord, ck, cf = set.x, set.y, set.ord, set.ck, set.cf
    local dx, dy, x0, x1, y0, y1 = bottom - top, right - left, huge, -huge, huge, -huge
    for i = 1, n do
        local px, py = top + dx * p[2 * i], left + dy * p[2 * i - 1]
        x[i], y[i], keys[i], ord[i] = px, py, Key(px, py), i
        x0, x1 = px < x0 and px or x0, px > x1 and px or x1
        y0, y1 = py < y0 and py or y0, py > y1 and py or y1
    end
    for i = n + 1, set.n do x[i], y[i], ord[i] = nil, nil, nil end
    sort(ord, Less)
    local c = 0
    for o = 1, n do
        local k = keys[ord[o]]
        if ck[c] ~= k then c = c + 1; ck[c], cf[c] = k, o end
    end
    for i = c + 1, set.c do ck[i], cf[i] = nil, nil end
    set.n, set.c, set.land, set.top, set.left, set.bottom, set.right = n, c, m, top, left, bottom, right
    set.x0, set.x1, set.y0, set.y1 = x0, x1, y0, y1
end

-- Ferryman.Marks: true when taken, the change applied on the next frame; false, changing nothing, otherwise. Every
-- argument is judged before any client call. An empty table takes that set away; the same places again change nothing.
function M.Set(uiMapID, points, source, label)
    if Secret(uiMapID) or Secret(points) or Secret(source) or Secret(label) then return false end
    if not (type(uiMapID) == "number" and uiMapID >= 1 and uiMapID <= WHOLE and uiMapID % 1 == 0
        and type(source) == "string" and source ~= "" and #source <= 32 and not TAKEN[source]
        and Plain(label) and type(points) == "table") then return false end
    local ok, good = pcall(Judge, points)
    if not (ok and good and ns.Driver.ready) then return false end
    local src, n = sources[source], #points / 2
    local i, old = Find(src, uiMapID, label)
    if n == 0 then
        if old then
            remove(src, i)
            src.n, src.marks = src.n - 1, src.marks - old.n
            if src.n == 0 then Drop(source) end
            Queue()
        end
        return true
    end
    if old and Same(old, points, n) then return true end
    if not src and #order >= M.SOURCES or src and not old and src.n >= M.SETS
        or (src and src.marks or 0) - (old and old.n or 0) + n > M.MARKS then return false end
    local info = C_Map.GetMapInfo(uiMapID)
    if not info or (info.mapType or 0) < 3 then return false end
    local m, top, left, bottom, right = Env.MapRect(uiMapID)
    if not m then return false end
    if not src then
        src = { n = 0, marks = 0 }
        sources[source], order[#order + 1] = src, source
    end
    local set = old
    if not set then
        set = { uiMap = uiMapID, label = label, n = 0, c = 0, x = {}, y = {}, ord = {}, ck = {}, cf = {} }
        src.n = src.n + 1
        src[src.n] = set
    elseif old.at == M.rev then
        -- Applied: the maps draw it until the next frame, so the places go to its spare record, the one it replaced.
        set = old.spare or { uiMap = uiMapID, label = label, n = 0, c = 0, x = {}, y = {}, ord = {}, ck = {}, cf = {} }
        set.spare, old.spare, src[i] = old, nil, set
    end
    src.marks = src.marks - (old and old.n or 0) + n
    Build(set, points, n, m, top, left, bottom, right)
    Queue()
    return true
end

-- Ferryman.MarksStop: every set of that source goes, on the next frame; true when it held any.
function M.Stop(source)
    if Secret(source) or type(source) ~= "string" or not sources[source] then return false end
    Drop(source)
    Queue()
    return true
end

-- The sets applied on a map and on a landmass (lists with n), or nil.
function M.OnMap(uiMap) return byMap[uiMap] end
function M.Land(landmass) return byLand[landmass] end
-- Whether the player's map, or a map of zone type or finer above it, holds a set applied.
function M.Here(uiMap)
    local info = uiMap and C_Map.GetMapInfo(uiMap)
    while info and (info.mapType or 0) >= 3 do
        if byMap[info.mapID] then return true end
        info = info.parentMapID and C_Map.GetMapInfo(info.parentMapID)
    end
    return false
end
-- A fact that can change what the minimap shows (the player's map, the zoom, a landmass) is published while a set is
-- applied (Driver.Fact).
function M.Fact(fact) if M.held > 0 and WAKE[fact] then Lead.Mark("tick") end end
