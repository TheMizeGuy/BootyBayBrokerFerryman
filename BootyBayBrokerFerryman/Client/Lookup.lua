local ADDON, ns = ...

-- Where a profession's nearest trainer and a creature stand, for Ferryman.Trainer and Ferryman.Creature (INTERFACES
-- 5.6): the shipped list indexed at the first call that needs it, the places learned in play (Seen), and per question
-- its answer, kept while the player stays within SAME yards of where it was made and the store is unchanged.
local M = {}
ns.Lookup = M

M.SAME, M.KEEP = 5, 64      -- yards an answer stands; creatures whose answers are kept before all are let go
local Env, Driver = ns.Env, ns.Driver
local NPC_MAX, SPOT, WHOLE = 1e7 - 1, 1e7, 2 ^ 31 - 1      -- Seen keys a creature's spots by its id plus SPOT a spot
local find, floor, sqrt = string.find, math.floor, math.sqrt
-- A secret value raises at a compare, a sum or as a key: an argument holding one is refused before it is read.
local Secret = issecretvalue or function() return false end
local byLine, byId, nextOf, order, words = false, false, false, false, false
local lines, npcs, kept, faction = {}, {}, 0, 0
local extra, xVer = { n = 0, key = {}, line = {} }, -1
-- The places of the question last gathered, one set for all questions: each keeps only its answer.
local cand = { n = 0, m = {}, x = {}, y = {}, src = {}, owner = false, ver = -1, fac = -1 }
-- The store last read, held weakly so one replaced is not kept; ver moves when it or Seen.stamp does.
local held, ver, verStamp = setmetatable({}, { __mode = "v" }), 0, -1

local function ReadOnly() error("Ferryman: read-only", 2) end
local function Frozen(t) return setmetatable({}, { __index = t, __metatable = false, __newindex = ReadOnly }) end
local function Whole(v, hi) return not Secret(v) and type(v) == "number" and v >= 1 and v <= hi and v % 1 == 0 end
local function Version()
    local st, stamp = ns.Ledger.Seen(), ns.Seen.stamp
    if held[1] ~= st or verStamp ~= stamp then held[1], verStamp, ver = st, stamp, ver + 1 end
    return ver, st
end

-- The list's profession trainers by skill line and every record by its creature (a chain through nextOf); no client
-- call. Set only once whole.
local function List()
    local s, U, W = ns.Trainers.entries, ns.Bytes.U, ns.Seen.WIDTH
    local l, b, n = {}, {}, {}
    for o = 1, #s, W do
        local id, mt = U(s, o, 3), U(s, o + 3, 1)
        n[o], b[id] = b[id], o
        if (mt - mt % 4) / 4 % 4 == 2 then
            local what = U(s, o + 16, 2)
            local r = l[what] or {}
            l[what], r[#r + 1] = r, o
        end
    end
    byLine, byId, nextOf = l, b, n
end
-- Each profession's client name, folded, for a learned trainer's title: one that cannot be read (no function, a raise,
-- a secret, none, or one that folds to nothing) is the list's English one; where both fold to nothing, no title names
-- the line.
local function Words()
    local T, Fold = C_TradeSkillUI, ns.Find.Fold
    local Name = type(T) == "table" and T.GetTradeSkillDisplayName
    local o, w = {}, {}
    for id, english in pairs(ns.Trainers.skills) do
        local ok, name = false, nil
        if type(Name) == "function" then ok, name = pcall(Name, id) end
        local word = ok and not Secret(name) and type(name) == "string" and Fold(name) or ""
        if word == "" and type(english) == "string" then word = Fold(english) end
        if word ~= "" then o[#o + 1], w[id] = id, word end
    end
    table.sort(o)
    order, words = o, w
end
local function Faction()
    if faction == 0 then faction = select(3, Env.Character()) end
    return faction
end
local function Add(c, m, x, y, src)
    local n = c.n + 1
    c.n, c.m[n], c.x[n], c.y[n], c.src[n] = n, m, x, y, src
end
local function Drop(c, i)
    local n = c.n
    c.m[i], c.x[i], c.y[i], c.src[i] = c.m[n], c.x[n], c.y[n], c.src[n]
    c.src[n], c.n = nil, n - 1
end

-- The point on a map as Go takes it: a map the client knows, its fractions converting back to the point.
local function OnMap(map, m, x, y)
    local mx, my = Env.WorldToMap(map, m, x, y)
    if not (mx and C_Map.GetMapInfo(map)) then return nil end
    local wm, wx, wy = Env.MapToWorld(map, mx, my)
    if wm == m and (wx - x) ^ 2 + (wy - y) ^ 2 <= 1 then return mx, my end
end
-- On the given map, else on the map the client names at the point: the map and the fractions, or nil.
local function Spot(map, m, x, y)
    local mx, my
    if map and map > 0 then mx, my = OnMap(map, m, x, y) end
    if not mx then
        map = Env.ZoneAt(m, x, y)
        if map then mx, my = OnMap(map, m, x, y) end
    end
    if mx then return map, mx, my end
end

-- A creature's places: each spot a window or talk taught, and a sighting's for a creature the list lacks; then each
-- place of the list on a landmass where no taught spot that can be placed is. A listed creature serves the list's
-- faction, another the faction its learners had; fac: the faction to serve, or false for any. src: the store's key,
-- or minus the offset.
local function Places(c, id, fac, st)
    local Seen, U, C, s = ns.Seen, ns.Bytes.U, ns.Bytes.C, ns.Trainers.entries
    local o, on0, on1 = byId[id], false, false
    local lf = o and U(s, o + 3, 1) % 4
    for k = 0, Seen.SPOTS - 1 do
        local key = id + SPOT * k
        if st[key] ~= nil then
            local _, f, m, x, y, map, q = Seen.Record(key)
            f = lf or f
            if m and (q > 0 or not o) and (not fac or f == 0 or f == fac) and (not o or Spot(map, m, x, y)) then
                Add(c, m, x, y, key)
                on0, on1 = on0 or q > 0 and m == 0, on1 or q > 0 and m == 1
            end
        end
    end
    while o do
        local mt = U(s, o + 3, 1)
        local m = (mt - mt % 16) / 16
        if not (m == 0 and on0 or m == 1 and on1) and (not fac or mt % 4 == 0 or mt % 4 == fac) then
            Add(c, m, C(s, o + 4), C(s, o + 7), -o)
        end
        o = nextOf[o]
    end
end
-- The learned trainers of creatures the list lacks (a guard's point, a sighting, another creature), each by the first
-- profession, by skill line, whose folded name its folded title holds; made again when the store changed.
local function Extras(st, v)
    if xVer == v then return end
    local n, Fold = 0, ns.Find.Fold
    for key, s in pairs(st) do
        if type(s) == "string" and not byId[type(key) == "number" and key % SPOT or 0]
            and (find(s, "^7[%a.;]") or find(s, "^[^;]*%.7[%a.;]")) then
            local title = select(8, ns.Seen.Record(key))
            local folded = title and Fold(title)
            for i = 1, folded and #order or 0 do
                if find(folded, words[order[i]], 1, true) then
                    n = n + 1
                    extra.key[n], extra.line[n] = key, order[i]
                    break
                end
            end
        end
    end
    for i = n + 1, extra.n do extra.key[i] = nil end
    extra.n, xVer = n, v
end
local function Line(c, skill, fac, st, v)
    local l, s, U = byLine[skill], ns.Trainers.entries, ns.Bytes.U
    for i = 1, l and #l or 0 do
        local id = U(s, l[i], 3)
        if byId[id] == l[i] then Places(c, id, fac, st) end
    end
    Extras(st, v)
    for i = 1, extra.n do
        if extra.line[i] == skill then
            local _, f, m, x, y = ns.Seen.Record(extra.key[i])
            if m and (f == 0 or f == fac) then Add(c, m, x, y, extra.key[i]) end
        end
    end
end

-- Nearest: the least distance in the plane on the player's landmass; with none there, or no position, the first by
-- landmass, then world x, then world y.
local function Before(c, i, j)
    if c.m[i] ~= c.m[j] then return c.m[i] < c.m[j] end
    if c.x[i] ~= c.x[j] then return c.x[i] < c.x[j] end
    return c.y[i] < c.y[j]
end
local function Choose(c, m, x, y)
    local best, bd = 0, nil
    for i = 1, c.n do
        local d = m == c.m[i] and (c.x[i] - x) ^ 2 + (c.y[i] - y) ^ 2 or nil
        if best == 0 or d and (not bd or d < bd or d == bd and Before(c, i, best)) or not (d or bd) and Before(c, i, best) then
            best, bd = i, d
        end
    end
    return best, bd
end
-- The place handed out: on the record's zone or learned map, else on the map the client names at the point; nil where
-- no map Go takes holds it.
local function Place(src, m, x, y, yards)
    local R, U, name, map, npc = ns.Trainers, ns.Bytes.U, nil, nil, nil
    if type(src) == "number" and src < 0 then
        name, map, npc = R.names[U(R.entries, 20 - src, 2)], U(R.entries, 13 - src, 3), U(R.entries, -src, 3)
    else
        local _, _, _, _, _, uiMap, _, title, who = ns.Seen.Record(src)
        npc = type(src) == "number" and src % SPOT or nil
        local o = npc and byId[npc]
        name, map = who or title or o and R.names[U(R.entries, o + 20, 2)], uiMap
    end
    local uiMap, mx, my = Spot(map, m, x, y)
    return mx and Frozen({ name = name or "", uiMapID = uiMap, x = mx, y = my, zone = Env.MapName(uiMap), yards = yards,
        npcID = npc }) or nil
end
-- The same question from within SAME yards, the store unchanged, is its kept answer and reads nothing else; else the
-- places are gathered again unless the shared set holds this question's, and an answer is a new table only when its
-- place, its yards or the learned record it was made from changed. The faction is read only here, for a trainer.
local function Answer(e, collect, q, v, st)
    local m, x, y = Env.Position()
    if e.ver == v and e.pm == (m or false) and (not m or (x - e.px) ^ 2 + (y - e.py) ^ 2 <= M.SAME ^ 2) then
        return e.place
    end
    e.ver, e.pm, e.px, e.py = v, m or false, x, y
    local c, fac = cand, collect == Line and Faction()
    if c.owner ~= e or c.ver ~= v or c.fac ~= fac then
        local n = c.n
        c.n, c.owner = 0, false
        collect(c, q, fac, st, v)
        for i = c.n + 1, n do c.src[i] = nil end
        c.owner, c.ver, c.fac = e, v, fac
    end
    while c.n > 0 do
        local i, d = Choose(c, m, x, y)
        local src, yards = c.src[i], d and floor(sqrt(d) + 0.5)
        if e.at == src and e.yards == yards and e.rec == st[src] then return e.place end
        local p = Place(src, c.m[i], c.x[i], c.y[i], yards)
        if p then
            e.place, e.at, e.yards, e.rec = p, src, yards, st[src]
            return p
        end
        Drop(c, i)
    end
    e.place, e.at, e.rec = nil, nil, nil
    return nil
end

local function Known(id, st)
    for k = 0, ns.Seen.SPOTS - 1 do
        if st[id + SPOT * k] ~= nil then return true end
    end
    return byId[id] ~= nil
end
-- Ferryman.Trainer: a line of the list's skills; its names read at the first line asked.
function M.Trainer(skill)
    if not (Whole(skill, WHOLE) and Driver.ready) then return nil end
    local e = lines[skill]
    if not e then
        if not ns.Trainers.skills[skill] then return nil end
        if not byId then List() end
        if not words then Words() end
        e = {}
        lines[skill] = e
    end
    local v, st = Version()
    return Answer(e, Line, skill, v, st)
end
-- Ferryman.Creature: one the list or the store knows; with the store changed, one no longer known is let go.
function M.Creature(id)
    if not (Whole(id, NPC_MAX) and Driver.ready) then return nil end
    if not byId then List() end
    local v, st = Version()
    local e = npcs[id]
    if not (e and e.ver == v or Known(id, st)) then
        if e then npcs[id], kept = nil, kept - 1 end
        return nil
    end
    if not e then
        if kept >= M.KEEP then npcs, kept = {}, 0 end
        e, kept = {}, kept + 1
        npcs[id] = e
    end
    return Answer(e, Places, id, v, st)
end
