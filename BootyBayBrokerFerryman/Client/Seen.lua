local ADDON, ns = ...

-- The places learned in play (INTERFACES 5.8): service windows, talk options, a guard's answer and titled NPCs looked
-- at teach who stands there, what they serve, their title and the spot, for the whole account. One string per place
-- (section 7), validated at login, at most MAX of them; the finder reads them when its box opens.
local M = {}
ns.Seen = M

M.MAX, M.SAME, M.SPOTS, M.CELL, M.TWICE, M.ASKED, M.PASSED = 1000, 150, 4, 40, 1, 120, 500
M.WIDTH = 22    -- a record of the shipped list (tools/trainers/FORMAT.md)
M.stamp = 0     -- moves at every change of the store: Lookup's answers are made again (5.6)

local find, sub, match, gmatch, gsub, format = string.find, string.sub, string.match, string.gmatch, string.gsub, string.format
local floor, huge = math.floor, math.huge
local Env = ns.Env
-- The window types taught, as the kind each teaches (L2): 67 and 68 are the bank's; 62 is not the chair's.
local TAUGHT = { [5] = 5, [7] = 7, [8] = 8, [10] = 10, [17] = 17, [20] = 20, [21] = 21, [22] = 22, [23] = 23,
    [24] = 24, [67] = 8, [68] = 8 }
-- L3: the kinds learned from a game object or with no unit at all, by kind and spot
local SPOT = { [10] = true, [17] = true, [62] = true }
local FIELDS = "%s;%d;%d;%d;%d;%d;%d;%d;%d;%d;%d;%s;%s"
-- f: the fields of the record last read: kinds, class, faction, map, x, y, uiMap, q, n, t, build, title, name
local f, keys, classWord, named = {}, {}, false, false
local lastKind, lastT = false, -huge
-- L6: the texts of the open talk window's options, by orderIndex and 1e6 + gossipOptionID, and whose they are; the
-- text chosen, the one chosen before it of the same creature from a list that does not offer it again, and the
-- point the client showed and the player's map at the choice
local said, talker, asked, before, asker, askedT = {}, false, false, false, false, -huge
local pMap, pName, pX, pY, aMap = false, false, false, false, false
-- L7: the creatures looked at this session that teach nothing (no title and no service named, or not friendly)
local passed, nPassed = {}, 0

local function Hidden(v) return v == nil or issecretvalue(v) end
local function Text(v) if not Hidden(v) and type(v) == "string" and v ~= "" then return (gsub(v, ";", ",")) end end
local function Int(v, lo, hi) return type(v) == "number" and v % 1 == 0 and v >= lo and v <= hi end

-- A stored string into f; false unless it has thirteen fields, the second to the eleventh numbers.
local function Read(s)
    if type(s) ~= "string" then return false end
    local n, at = 0, 1
    repeat
        local e = find(s, ";", at, true)
        n = n + 1
        if n > 13 then return false end
        f[n] = sub(s, at, e and e - 1 or -1)
        at = e and e + 1
    until not at
    if n ~= 13 then return false end
    for i = 2, 11 do
        f[i] = tonumber(f[i])
        if not f[i] then return false end
    end
    return true
end
local function Write(store, key)
    M.stamp = M.stamp + 1
    store[key] = format(FIELDS, f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12], f[13])
end

local LEARNABLE = { [5] = true, [6] = true, [7] = true, [8] = true, [10] = true, [17] = true, [20] = true, [21] = true,
    [22] = true, [23] = true, [24] = true, [62] = true, [0] = true, [82] = true }
-- Seen.Load's rules (7.2): a key of a creature's spot, of a cell or of a guard's point; kinds each a learnable
-- service (or a guard's flight master), 0 (a titled NPC) or 82 (a named place), a repair mark on a merchant and a
-- profession mark on a trainer only; a class the client knows; a landmass with walking data; a map the client knows.
local function Known(cache, fn, v)
    local ok = cache[v]
    if ok == nil then ok = fn(v) ~= nil; cache[v] = ok end
    return ok
end
local function Valid(key, s, classes, maps)
    if not (Read(s) and (Int(key, 1, M.SPOTS * 1e7 - 1) or type(key) == "string" and find(key, "^[kg]:"))) then
        return false
    end
    for part in gmatch(f[1], "[^.]+") do
        local k, mark = match(part, "^(%d+)([rp]?)$")
        k = tonumber(k)
        if not (k and LEARNABLE[k] and (mark == "" or mark == "r" and k == 5 or mark == "p" and k == 7)) then return false end
    end
    return f[1] ~= "" and (f[2] == 0 or Int(f[2], 1, 31) and Known(classes, C_CreatureInfo.GetClassInfo, f[2]))
        and Int(f[3], 0, 2) and Int(f[4], 0, 1e5) and Env.HasCompanion(f[4]) and Int(f[5], -4e4, 4e4) and Int(f[6], -4e4, 4e4)
        and Int(f[7], 1, 1e6) and Known(maps, Env.MapName, f[7]) and Int(f[8], 0, 2) and Int(f[9], 1, 1e9) and Int(f[10], 0, 1e11)
        and Int(f[11], 0, 1e9)
end

-- When full, the oldest sighting goes first, then the oldest guard's point, then the oldest window.
local QT = "^[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;(%d);[^;]*;(%d+);"
local function Evict(store)
    local low, old, key = huge, huge, nil
    for k, s in pairs(store) do
        local q, t = match(s, QT)
        q, t = tonumber(q), tonumber(t)
        if q and (q < low or q == low and t < old) then low, old, key = q, t, k end
    end
    if key ~= nil then store[key], M.stamp = nil, M.stamp + 1 end
end
local function Count(store)
    local n = 0
    for _ in pairs(store) do n = n + 1 end
    return n
end

function M.Load()
    local store, classes, maps = ns.Ledger.Seen(), {}, {}
    for key, s in pairs(store) do
        if not Valid(key, s, classes, maps) then store[key] = nil end
    end
    for _ = M.MAX + 1, Count(store) do Evict(store) end
    M.stamp = M.stamp + 1
end

-- L8: line 2 of the unit's tooltip is its title when line 3 is the level's line and line 2 is not. This client types
-- no line as the level's, so that line is also known by the lead of the client's own level text; with none, no title.
local function Level(line, T, lead)
    local text = line and line.leftText
    if not line or Hidden(line.type) or Hidden(text) then return false end
    return line.type == T.UnitLevel or lead ~= "" and type(text) == "string" and sub(text, 1, #lead) == lead
end
local function Title(unit)
    local data = C_TooltipInfo.GetUnit(unit)
    local lines, T = data and data.lines, Enum.TooltipDataLineType
    local two, lead = type(lines) == "table" and lines[2], match(TOOLTIP_UNIT_LEVEL or "", "^[^%%]*")
    if not two or Hidden(two.type) or two.type ~= T.None then return end
    if not Level(two, T, lead) and Level(lines[3], T, lead) then return Text(two.leftText) end
end

local function Class(title)
    if not classWord then
        classWord = {}
        for id = 1, 15 do
            local info = C_CreatureInfo.GetClassInfo(id)
            if info and Text(info.className) then classWord[id] = " " .. ns.Find.Fold(info.className) .. " " end
        end
    end
    local folded = title and " " .. ns.Find.Fold(title) .. " "
    for id, w in pairs(folded and classWord or {}) do
        if find(folded, w, 1, true) then return id end
    end
    return 0
end
-- L4 at a window: the other services whose client word the title holds, as kinds (".20": an inn at its goods).
local function Named(title, k)
    named = named or { 8, MINIMAP_TRACKING_BANKER, 20, MINIMAP_TRACKING_INNKEEPER, 21, MINIMAP_TRACKING_AUCTIONEER,
        22, MINIMAP_TRACKING_STABLEMASTER, 23, MINIMAP_TRACKING_BATTLEMASTER }
    local out, folded = "", " " .. ns.Find.Fold(title or "") .. " "
    for i = 1, 9, 2 do
        local w = named[i + 1]
        if named[i] ~= k and w and find(folded, " " .. ns.Find.Fold(w) .. " ", 1, true) then out = out .. "." .. named[i] end
    end
    return out
end

-- The kinds of a record with new ones: a new one in place of the same kind when it carries a mark (a kind seen
-- again without one keeps its mark: a talk window cannot tell), and no "titled NPC" left beside a service.
local function Join(old, new)
    local out, has = "", "." .. gsub(new, "%a", "") .. "."
    for part in gmatch(new, "[^.]+") do
        local k = match(part, "^%d+")
        out = out .. "." .. (part == k and match("." .. old .. ".", "%.(" .. k .. "%a?)%.") or part)
    end
    for part in gmatch(old, "[^.]+") do
        if part ~= "0" and not find(has, "." .. match(part, "^%d+") .. ".", 1, true) then out = out .. "." .. part end
    end
    return sub(out, 2)
end

-- Section 7.2's merge: a creature's spot nearest within SAME yards of its id's four (else the first free, else the
-- oldest), or the record of key (a cell, a guard's point).
local function Store(kinds, id, key, name, title, m, x, y, uiMap, q, again)
    local store, fresh = ns.Ledger.Seen(), false
    if id then
        local near, free, oldest, oldT = M.SAME * M.SAME, nil, nil, huge
        for s = 0, M.SPOTS - 1 do
            local spot = id + 1e7 * s
            if Read(store[spot]) then
                local d = f[4] == m and (f[5] - x) ^ 2 + (f[6] - y) ^ 2 or huge
                if d <= near then near, key = d, spot end
                if f[10] < oldT then oldest, oldT = spot, f[10] end
            elseif not free then
                free = spot
            end
        end
        fresh = not key
        key = key or free or oldest
    end
    local faction, now = select(3, Env.Character()), Env.Now()
    if not fresh and Read(store[key]) then
        f[1], f[3], f[9] = Join(f[1], kinds), f[3] == faction and faction or 0, f[9] + (again and 0 or 1)
    else
        if store[key] == nil and Count(store) >= M.MAX then Evict(store) end
        f[1], f[2], f[3], f[9], f[12], f[13] = kinds, 0, faction, 1, "", ""
    end
    f[4], f[5], f[6], f[7], f[8], f[10] = m, floor(x + 0.5), floor(y + 0.5), uiMap, q, floor(now)
    f[11], f[12], f[13] = tonumber(match(Env.Build(), "(%d+)$")) or 0, title or f[12], name or f[13]
    if find("." .. f[1], ".7", 1, true) then f[2] = find("." .. f[1] .. ".", ".7p.", 1, true) and 0 or Class(f[12]) end
    Write(store, key)
end

-- L1: where the player stands, or nil where nothing is learned.
local function Here()
    local env = Env.Read()
    if env.ok and not (env.instance or env.taxi or ns.Senses.carried) and env.uiMap then return env end
end
local function Cell(k, env) return format("k:%d:%d:%d:%d", k, env.landmass, floor(env.x / M.CELL), floor(env.y / M.CELL)) end
-- Two events of one kind within TWICE s are one observation.
local function Again(k, now)
    local again = k == lastKind and now - lastT < M.TWICE
    lastKind, lastT = k, now
    return again
end
-- L3: the creature of the npc unit, else false; its id (nil when hidden), name and title.
local function Creature() return not UnitIsGameObject("npc") and UnitExists("npc") and not UnitPlayerControlled("npc") end
local function Who(unit)
    local id = UnitCreatureID(unit)
    if Hidden(id) or not Int(id, 1, 1e7 - 1) then id = nil end
    return id, Text(UnitName(unit)), Title(unit)
end

-- L1 to L4: a window opened (Senses: its type, or with direct its kind).
function M.Window(kind, direct)
    local k = not Hidden(kind) and (direct and kind or TAUGHT[kind])
    local env = k and Here()
    if not env or k == 7 and C_Trainer.GetTrainerType() == Enum.TrainerType.Pet then return end
    local again, creature = Again(k, env.now), Creature()
    if not (creature or SPOT[k]) then return end
    local id, name, title
    if creature then id, name, title = Who("npc") end
    local mark = k == 5 and CanMerchantRepair() and "r" or k == 7 and IsTradeskillTrainer() and "p" or ""
    Store(k .. mark .. Named(title, k), id, not id and Cell(k, env), name, title, env.landmass, env.x, env.y, env.uiMap, 2, again)
end

-- The point the client shows on the player's map or the first of its parents that has one: map, name, x, y.
local function Point()
    local map = C_Map.GetBestMapForUnit("player")
    for _ = 0, 4 do
        if Hidden(map) or not Int(map, 1, 1e6) then return end
        local id = C_GossipInfo.GetPoiForUiMapID(map)
        local info = not Hidden(id) and id and C_GossipInfo.GetPoiInfo(map, id)
        local pos, name = info and info.position, info and Text(info.name)
        if pos and name and not (Hidden(pos.x) or Hidden(pos.y)) then return map, name, pos.x, pos.y end
        local up = C_Map.GetMapInfo(map)
        map = up and up.parentMapID
    end
end

-- L6: after a choice, within ASKED s and on the map of the choice, a point unlike the one the client showed then is
-- the answer. Its kind is the one the last text names (the finder's words), else the one before; with none, a named
-- place (82). A class trainer's key carries its class.
function M.Guard()
    if not asked or Env.Now() - askedT > M.ASKED then asked = false return end
    local map, name, x, y = Point()
    if not map or map == pMap and name == pName and x == pX and y == pY then return end
    local at = C_Map.GetBestMapForUnit("player")
    if Hidden(at) or Hidden(aMap) or at ~= aMap then asked = false return end
    pMap, pName, pX, pY = map, name, x, y
    local text, other = asked, before
    asked, before = false, false
    local m, wx, wy = Env.MapToWorld(map, x, y)
    if not (m and Here()) then return end
    local k, prof = ns.Finder.Names(text)
    if not k and other then k, prof = ns.Finder.Names(other) end
    local kinds = (k or 82) .. (prof and "p" or "")
    local key = k == 7 and not prof and Class(text) > 0 and "7." .. Class(text) or kinds
    Store(kinds, nil, format("g:%d:%s:%s", map, key, name), name, text, m, wx, wy, map, 1)
end

-- L5: a talk window's options, their texts kept for a choice (L6); a creature whose options carry a service's icon
-- is learned as those services. Closed, the texts go. Either way the point is read, as it may be an answer.
function M.Talk(closed)
    for k in pairs(said) do said[k] = nil end
    talker = false
    local creature = not closed and Creature()
    if creature then
        local kinds, icons = "", ns.Gazetteer.icons
        for _, o in ipairs(C_GossipInfo.GetOptions() or {}) do
            local text, icon, i, id = Text(o.name), o.overrideIconID or o.icon, o.orderIndex, o.gossipOptionID
            if text and Int(i, 0, 1e5) then said[i] = text end
            if text and Int(id, 0, 1e7) then said[1e6 + id] = text end
            local k = not Hidden(icon) and icons[icon]
            if k and not find(kinds .. ".", "." .. k .. ".", 1, true) then kinds = kinds .. "." .. k end
        end
        local id, name, title = Who("npc")
        talker = id or true
        local env, k = kinds ~= "" and Here(), tonumber(match(kinds, "%d+"))
        if env then Store(sub(kinds, 2), id, not id and Cell(k, env), name, title, env.landmass, env.x, env.y, env.uiMap, 2, Again(-k, env.now)) end
    end
    M.Guard()
end

-- L6: an option chosen (Senses' hooks: its orderIndex, else its gossipOptionID).
function M.Chose(option, byIndex)
    local text = not Hidden(option) and type(option) == "number" and said[byIndex and option or 1e6 + option]
    if not text then return end
    local now, listed = Env.Now(), false
    for _, s in pairs(said) do listed = listed or s == asked end
    before = not listed and asked and talker == asker and now - askedT <= M.ASKED and asked
    asked, asker, askedT = text, talker, now
    pMap, pName, pX, pY = Point()
    aMap = C_Map.GetBestMapForUnit("player")
end

-- L7: a friendly creature looked at, once a session: one with a title or a service in its name is a sighting at the
-- player's own spot, any other passed over (PASSED at most). A known one costs its id and five lookups.
local function Pass(id)
    if nPassed >= M.PASSED then passed, nPassed = {}, 0 end
    passed[id], nPassed = true, nPassed + 1
end
function M.Sight(unit)
    local id = UnitCreatureID(unit)
    if Hidden(id) or passed[id] or not Int(id, 1, 1e7 - 1) then return end
    local store = ns.Ledger.Seen()
    if store[id] or store[id + 1e7] or store[id + 2e7] or store[id + 3e7] then return end
    local react = UnitReaction(unit, "player")
    if Hidden(react) then return elseif react < 4 or UnitPlayerControlled(unit) then return Pass(id) end
    local env = Here()
    if not env then return end
    local _, name, title = Who(unit)
    local k, prof = ns.Finder.Names(title)
    if not k then k, prof = ns.Finder.Names(name) end
    if not (k or title) then return Pass(id) end
    Store(k and k .. (prof and "p" or "") or "0", id, nil, name, title, env.landmass, env.x, env.y, env.uiMap, 0)
end

-- Every record to fn(kind, class, mark, faction, m, x, y, uiMap, q, title, name), one call per kind (7.3); fn
-- may pause: the keys are taken first, and a record gone meanwhile is passed over.
function M.Each(fn)
    local store, n = ns.Ledger.Seen(), 0
    for k in pairs(store) do n = n + 1; keys[n] = k end
    for i = 1, n do
        local key = keys[i]
        keys[i] = nil
        if Read(store[key]) then
            local class, faction, m, x, y, uiMap, q = f[2], f[3], f[4], f[5], f[6], f[7], f[8]
            local title, name = f[12] ~= "" and f[12] or nil, f[13] ~= "" and f[13] or nil
            for part in gmatch(f[1], "[^.]+") do
                local kind, mark = match(part, "^(%d+)(%a?)$")
                kind = tonumber(kind)
                fn(kind == 0 and 80 or kind, kind == 7 and class or 0, mark, faction, m, x, y, uiMap, q, title, name)
            end
        end
    end
end

-- The records of the shipped list (Data/Trainers.lua: trainers, and the keepers of inns, banks and auction houses) no
-- window of whose creature, learned as that kind, has opened on their landmass, to fn as Each hands a record (q -1, uiMap its zone),
-- its area last; a keeper by its kind, with no title; a trainer's title by fmt with the names given, else the list's own (5.8, decisions 120, 129).
function M.Listed(fn, fmt, classes, skills)
    local R, U, C = ns.Trainers, ns.Bytes.U, ns.Bytes.C
    local s, store = R.entries, ns.Ledger.Seen()
    for o = 1, #s, M.WIDTH do
        local id, mt, what = U(s, o, 3), U(s, o + 3, 1), U(s, o + 16, 2)
        local m, ty, known = (mt - mt % 16) / 16, (mt - mt % 4) / 4 % 4, false
        for k = 0, M.SPOTS - 1 do
            known = known or Read(store[id + 1e7 * k]) and f[4] == m and f[8] > 0
                and find("." .. f[1] .. ".", "%." .. (ty == 0 and what or 7) .. "%a?%.") ~= nil
        end
        if not known then
            local named = ty == 1 and classes[what] or ty == 2 and skills[what]
            fn(ty == 0 and what or 7, ty == 1 and what or 0, ty == 2 and "p" or "", mt % 4, m, C(s, o + 4), C(s, o + 7), U(s, o + 13, 3), -1,
                ty > 0 and (named and format(fmt, named) or R.titles[U(s, o + 18, 2)] or "") or nil, R.names[U(s, o + 20, 2)], U(s, o + 10, 3))
        end
    end
end

-- The record of key: its kinds whole, faction, landmass, x, y, uiMap, q, title and name (nil when it has none);
-- nothing when there is none (Lookup, 5.6).
function M.Record(key)
    if Read(ns.Ledger.Seen()[key]) then
        return f[1], f[3], f[4], f[5], f[6], f[7], f[8], f[12] ~= "" and f[12] or nil, f[13] ~= "" and f[13] or nil
    end
end

-- The records.
function M.Count()
    local n = 0
    for _, s in pairs(ns.Ledger.Seen()) do if Read(s) then n = n + 1 end end
    return n
end
