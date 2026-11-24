local ADDON, ns = ...

-- The finder's client half (INTERFACES 5.7): the index built when the box opens and dropped when it closes, a text
-- run as a find job, the estimates of every place and the plans of the listed rows asked of Lead, and the rows the
-- box draws. The box hands it the texts: no Client file reads them itself.
local M = {}
ns.Finder = M

M.REST, M.TRIES = 0.25, 3      -- seconds a text rests before its rows are planned; starts of a chore that gave nothing

local format, find, gmatch, gsub, huge = string.format, string.find, string.gmatch, string.gsub, math.huge
local Find, Env, Lead, Request, Bytes = ns.Find, ns.Env, ns.Lead, ns.Request, ns.Bytes
-- what a text may ask for, in the order a tie names it: the flight master, which no status row speaks of, then the
-- learnable services
local ASKED = { 6, 5, 7, 8, 10, 17, 20, 21, 22, 23, 24, 62 }
local WIDTH = 20        -- a record of the gazetteer (tools/gazetteer/FORMAT.md)

local T, kinds, lines, repairWord, classWord, className, trainer, skill, profs = false, false, {}, "", {}, {}, {}, {}, " "
local open, built, job, again, text, subs = false, false, false, false, "", {}
local rows = { n = 0 }
local ctx = { faction = false, class = 0, classWord = classWord, mass = 0, x = false, y = 0, v = 7, fig = nil }
-- The index beside Find's own: entries 1 to nG are the gazetteer's records in order; src: what a later one stands
-- for (a stop, an entrance, a town point), at: a listed record's area.
local nG, src, at, zoneName = 0, {}, {}, {}
local stop = { kind = "stop", anchor = 0 }
local zone, zoneMap = false, 0
local figAt, figX, figY, figWant = -huge, 0, 0, false
local proof = { n = 0, e = {}, mass = {}, x = {}, y = {}, uiMap = {}, kind = {}, ref = {} }
local proved, proofWant, rest, rested, ordered, tries = {}, false, false, false, false, 0

-- A kind: its word on a row, the name of an unnamed place of it, the folded words a text names it by, and as
-- phrases (says) each client word and each short form, padded with spaces.
local function Kind(word, place, more, short)
    local k = { word = word or false, place = place or false, says = {}, words = Find.Fold((word or "") .. " "
        .. (place ~= word and place or "") .. " " .. (more or "") .. " " .. (short or "")) }
    local all = (word or "") .. "|" .. (place or "") .. "|" .. (more or "") .. "|" .. gsub(short or "", " ", "|")
    for s in gmatch(all, "[^|]+") do k.says[#k.says + 1] = " " .. Find.Fold(s) .. " " end
    return k
end
local function Words()
    local none, class, prof = Kind(), MINIMAP_TRACKING_TRAINER_CLASS or "", MINIMAP_TRACKING_TRAINER_PROFESSION or ""
    kinds = {
        [5] = Kind(MERCHANT, MERCHANT, nil, T.FIND_WORDS_MERCHANT),
        [6] = Kind(MINIMAP_TRACKING_FLIGHTMASTER, nil, nil, T.FIND_WORDS_FLIGHT),
        [7] = Kind(nil, nil, class .. "|" .. prof, T.FIND_WORDS_TRAINER),
        [8] = Kind(MINIMAP_TRACKING_BANKER, BANK),
        [10] = Kind(GUILD_BANK, GUILD_BANK, nil, T.FIND_WORDS_GUILDBANK),
        [17] = Kind(MINIMAP_TRACKING_MAILBOX, MINIMAP_TRACKING_MAILBOX, MAIL_LABEL, T.FIND_WORDS_MAIL),
        [20] = Kind(MINIMAP_TRACKING_INNKEEPER, MINIMAP_TRACKING_INNKEEPER, nil, T.FIND_WORDS_INN),
        [21] = Kind(MINIMAP_TRACKING_AUCTIONEER, BUTTON_LAG_AUCTIONHOUSE, AUCTIONS, T.FIND_WORDS_AUCTION),
        [22] = Kind(MINIMAP_TRACKING_STABLEMASTER, MINIMAP_TRACKING_STABLEMASTER, STABLES, T.FIND_WORDS_STABLE),
        [23] = Kind(MINIMAP_TRACKING_BATTLEMASTER, nil, nil, T.FIND_WORDS_BATTLE),
        [24] = Kind(MINIMAP_TRACKING_TRANSMOGRIFIER, nil, nil, T.FIND_WORDS_TRANSMOG),
        [62] = Kind(MINIMAP_TRACKING_BARBER, BARBERSHOP, nil, T.FIND_WORDS_BARBER),
        [80] = none, [81] = Kind(ZONE), [82] = none, [83] = none, [84] = none, [85] = none, [86] = none,
        [87] = Kind(nil, nil, nil, T.FIND_WORDS_BOAT), [88] = Kind(nil, nil, nil, T.FIND_WORDS_ZEPPELIN),
        [89] = Kind(nil, nil, nil, T.FIND_WORDS_TRAM), [90] = Kind(LFG_TYPE_DUNGEON), [91] = Kind(RAID),
    }
    for i = 1, #ASKED do lines[i] = kinds[ASKED[i]].words end
    -- a learned place goes by its own kind's words: a class or a profession trainer's; a guild vault never by "bank"
    trainer[""], trainer.p = Find.Fold(class .. " " .. T.FIND_WORDS_TRAINER), Find.Fold(prof .. " " .. T.FIND_WORDS_TRAINER)
    kinds[10].words = Find.Fold(T.FIND_WORDS_GUILDBANK)
    repairWord = Find.Fold(MINIMAP_TRACKING_REPAIR or "")
    local stops = {}
    for w in gmatch(Find.Fold(T.FIND_STOP), "[^ ]+") do stops[w] = true end
    Find.article, Find.stop = T.FIND_ARTICLE ~= "" and Find.Fold(T.FIND_ARTICLE) or nil, stops
    for id = 1, 15 do
        local info = C_CreatureInfo.GetClassInfo(id)
        if info and info.className then className[id], classWord[id] = info.className, Find.Fold(info.className) end
    end
    for id, english in pairs(ns.Trainers.skills) do
        local name = C_TradeSkillUI.GetTradeSkillDisplayName(id)
        skill[id] = type(name) == "string" and name ~= "" and name or false
        profs = profs .. Find.Fold(skill[id] or english) .. " "
    end
    return true
end

-- The texts, from the box's file: the learner may ask its words before the box first opens (Names).
function M.Texts(texts) T = texts end
-- L6, L7 (Seen): the kind of ASKED's whose longest phrase is a whole run of the text's folded words, the first of a
-- tie; for a trainer, whether the text holds a word of the profession trainers' that the class trainers' lack.
function M.Names(text)
    if not (text and (kinds or T and Words())) then return end
    local folded, best, len, prof = " " .. Find.Fold(text) .. " ", nil, 0, false
    for i = 1, #ASKED do
        for _, s in ipairs(kinds[ASKED[i]].says) do
            if #s > len and find(folded, s, 1, true) then best, len = ASKED[i], #s end
        end
    end
    for w in gmatch(best == 7 and trainer.p or "", "[^ ]+") do
        prof = prof or find(folded, " " .. w .. " ", 1, true) and not find(" " .. trainer[""] .. " ", " " .. w .. " ", 1, true)
    end
    return best, prof and true or false
end

-- H2's climb: the first of a map and its parents, four steps at most, that an entry has as its zone.
local function Climb(id)
    for _ = 0, 4 do
        if not id or id == 0 then return false end
        if zoneName[id] then return id end
        local info = C_Map.GetMapInfo(id)
        id = info and info.parentMapID
    end
    return false
end

-- M4: every place as one entry, the gazetteer's records first, then the network's own places, each in the zone
-- the gazetteer gives it, then the learned ones (7.3). The network's and the learned are named by the client, so
-- they pause four times as often.
local function Build(pause)
    local G, Net, U, C, UNIT = ns.Gazetteer, ns.Net, Bytes.U, Bytes.C, Find.UNIT
    local S, E = Net.S, Net.EntranceCount
    local s, areas, areaLine, j = G.entries, {}, {}, 0
    Find.Reset()
    local function Area(id)
        local name = areas[id]
        if name == nil then name = Env.AreaName(id) or false; areas[id] = name end
        return name
    end
    local function Map(z)
        local name = zoneName[z]
        if name == nil then name = z > 0 and Env.MapName(z) or false; zoneName[z] = name end
        return name
    end
    for k = 1, Bytes.Count(s, WIDTH) do
        local o = (k - 1) * WIDTH + 1
        local kind, mf, where, z = U(s, o, 1), U(s, o + 1, 1), U(s, o + 8, 3), U(s, o + 11, 3)
        local id, own = U(s, o + 14, 3), U(s, o + 17, 2)
        local words = areaLine[where * 1e6 + z]
        if not words then
            words = Find.Fold((Area(where) or "") .. " " .. (Map(z) or ""))
            areaLine[where * 1e6 + z] = words
        end
        -- a room the files only suggest (flag 1) yields its row to another source at the files' rank (K6)
        Find.Add(id > 0 and Area(id) or own > 0 and G.names[own] or kinds[kind].place or "", kinds[kind].words, words, kind,
            (mf - mf % 8) / 8, C(s, o + 2), C(s, o + 5), U(s, o + 19, 1) + 128, z, mf % 8 == 1)
        if k % UNIT == 0 then pause() end
    end
    nG = Find.points.n
    local function Add(shown, kind, i, m, x, y, faction, area, at)
        j = j + 1
        local z = U(G.zones, 3 * at - 2, 3)
        src[j] = i
        Find.Add(shown, kinds[kind].words, Find.Fold((area or "") .. " " .. (Map(z) or "")), kind, m, x, y, faction + 128, z)
        if j % (UNIT / 4) == 0 then pause() end
    end
    local function Name(a) stop.anchor = a; return Env.PlaceName(stop) end
    for i = 1, Net.S do
        local kind, m, x, y, _, faction = Net.Stop(i)
        if kind == 1 then Add(Name(i), 6, i, m, x, y, faction, nil, i) end
    end
    for v = 1, Net.VesselCount do
        local _, air, _, _, calls = Net.Vessel(v)
        for c = 1, calls do
            local a = Net.Call(v, c)
            local _, m, x, y = Net.Stop(a)
            Add(format(air and T.FIND_ZEPPELIN or T.FIND_BOAT, Name((Net.Call(v, c % calls + 1)))), air and 88 or 87, a,
                m, x, y, 0, Name(a), a)
        end
    end
    for k = 1, Net.EntranceCount do
        local map, raid, m, x, y = Net.Entrance(k)
        if m then Add(Env.InstanceName(map) or "", raid and 91 or 90, k, m, x, y, 0, nil, S + k) end
    end
    for k = 1, Net.PlaceCount do
        local area, m, x, y, icon, english = Net.Place(k)
        if Env.HasCompanion(m) then Add(Area(area) or english, icon == 5 and 86 or 85, k, m, x, y, 0, nil, S + E + k) end
    end
    local door1, door2 = Net.TramStops()
    for i = 1, 2 do
        local a = i == 1 and door1 or door2
        local m, x, y = Net.Anchor(a)
        Add(T.FIND_TRAM, 89, a, m, x, y, 0, Name(a), a)
    end
    -- a learned place, then a record of the shipped list (a trainer; a keeper, which has no title): its title then its
    -- kind's words (a trainer's class, a merchant's repair); src its title for line 2. Rank 0 a window, 1 a guard's point, 2 the list (q -1), 3 a sighting.
    local function Learned(kind, class, mark, faction, m, x, y, uiMap, q, title, name, where)
        local K, repair = kinds[kind], mark == "r"
        if not (K and Env.HasCompanion(m)) then return end
        local z = Climb(uiMap) or Env.ZoneAt(m, x, y) or 0
        local words = (title and Find.Fold(title) .. " " or "") .. (kind == 7 and trainer[mark] or K.words)
            .. (classWord[class] and " " .. classWord[class] or "")
        j = j + 1
        src[j], at[j] = name and title or false, where
        Find.Add(name or title or K.place or K.word or "", repair and words .. " " .. repairWord or words,
            Find.Fold((where and Area(where) or "") .. " " .. (Map(z) or "")), kind, m, x, y, faction + 4 * class
            + (q == 2 and 0 or q == 1 and 64 or q < 0 and 128 or 192) + (repair and 256 or 0), z)
        if j % (UNIT / 4) == 0 then pause() end
    end
    ns.Seen.Each(Learned)
    ns.Seen.Listed(Learned, T.FIND_TRAINER, className, skill)
end

local function Publish(what)
    for i = 1, #subs do subs[i](rows, what) end
end

local function Put(kind, name, line, e, tier)
    local n = rows.n + 1
    local row = rows[n] or {}
    rows[n], rows.n = row, n
    row.kind, row.name, row.line, row.e, row.tier, row.secs = kind, name or "", line or "", e or 0, tier or 0, nil
    return row
end

-- A row's second line (B5): the kind's word, unless the name is the kind's place word (a learned place's own title,
-- unless a guard's point is named by it); the area, unless it is the name; then a sighting's note. A place the data gives no area is said by the zone the client names there, and
-- one that would say nothing (a city on its own map) by its continent.
local function Join(a, b) return a and b and format(T.FIND_LINE, a, b) or a or b end
local function Line(e)
    local name, kind, m, x, y, _, _, rank, _, z = Find.Entry(e)
    local K, area, note = kinds[kind], zoneName[z], rank == 3 and T.FIND_SEEN
    local word = K.word and K.place ~= name and K.word
    if e <= nG then
        local s, o = ns.Gazetteer.entries, (e - 1) * WIDTH + 1
        area = Env.AreaName(Bytes.U(s, o + 8, 3)) or area
    elseif kind >= 87 and kind <= 89 then
        stop.anchor = src[e - nG]
        area = Env.PlaceName(stop)
    elseif type(src[e - nG]) == "string"
        and not (rank == 1 and find(" " .. Find.Fold(name) .. " ", " " .. Find.Fold(src[e - nG]) .. " ", 1, true)) then
        word = src[e - nG]
    end
    if at[e - nG] then area = Env.AreaName(at[e - nG]) or area end
    if not area then
        local at = Env.ZoneAt(m, x, y)
        area = at and Env.MapName(at)
    end
    return Join(Join(word, area ~= name and area), note) or Env.LandmassName(m) or ""
end

-- H2: the player's zone.
local function Zone(uiMap)
    if uiMap ~= zoneMap then zoneMap, zone = uiMap, Climb(uiMap) end
    return zone
end

-- H1: a text that asks for a service none of which stands in the player's zone gets a first row that says so. A
-- trainer is the class's the text names, or the player's own for the class trainers' words alone; true: neither.
local function Status()
    local i, class, repair = Find.Kind(text, lines, classWord, repairWord)
    local kind = i and ASKED[i] or repair and 5
    if not kind or kind == 6 then return not kind and Find.Only(text, profs) or nil end
    repair = repair and kind == 5
    if kind == 7 and not class and ctx.class > 0 and Find.Only(text, " " .. trainer[""] .. " ") then class = ctx.class end
    if kind == 7 and not class then return true end
    -- H2: with no zone (an instance, a deck) the landmass stands in, when the client can name it
    local z, now = Zone(Env.now.uiMap), Env.now
    local land = not z and now.landmass and Env.LandmassName(now.landmass)
    local here, anywhere = Find.Has(kind, kind == 7 and class or nil, repair, z or nil, ctx.faction or nil,
        land and now.landmass or nil)
    if here or anywhere and not (z or land) then return end
    Put("status", kind == 7 and format(T.FIND_TRAINER, className[class] or "") or repair and MINIMAP_TRACKING_REPAIR
        or kinds[kind].word, anywhere and format(T.FIND_NONE_HERE, z and zoneName[z] or land) or T.FIND_NONE)
end

-- K9: once every row of the first row's tier has its plan, those rows go in the order of their planned times, a
-- row with no way last; once a list.
local function Order()
    local a = rows.n > 0 and rows[1].kind == "status" and 2 or 1
    local first = a <= rows.n and rows[a]
    if ordered or not first or first.kind ~= "place" then return false end
    local b = a
    while b <= rows.n and rows[b].tier == first.tier do
        if rows[b].secs == nil then return false end
        b = b + 1
    end
    ordered = true
    for i = a + 1, b - 1 do
        local row, k = rows[i], i - 1
        local secs = row.secs or huge
        while k >= a and (rows[k].secs or huge) > secs do rows[k + 1], k = rows[k], k - 1 end
        rows[k + 1] = row
    end
    return true
end

local function MakeRows()
    local found = Find.rows
    rows.n, ordered = 0, false
    if not find(text, "%S") then return Put("hint", T.FIND_HINT) end
    local ask = Status()
    for r = 1, found.n do
        local e = found.e[r]
        Put("place", Find.name[e], Line(e), e, found.tier[r]).secs = proved[e]
    end
    if rows.n == 0 then Put("nothing", ask and T.FIND_NONE or T.FIND_NOTHING, ask and T.FIND_ASK) end
    Order()
end

-- B8: where a row leads, as a map position: on its zone's map, else on the map the client names there.
local function Dest(e)
    local _, _, m, x, y, _, _, _, _, z = Find.Entry(e)
    local mx, my
    if z > 0 then mx, my = Env.WorldToMap(z, m, x, y) end
    if not mx then
        z = Env.ZoneAt(m, x, y)
        if z then mx, my = Env.WorldToMap(z, m, x, y) end
    end
    return mx and z or nil, mx, my
end
local function StopOf(e) local kind, a = select(2, Find.Entry(e)), src[e - nG]; return kind == 6 and type(a) == "number" and a end

-- K9: the listed rows that have no figure yet are planned once the text has rested and the estimates are in.
local function List()
    local n = 0
    for i = 1, rows.n do
        local row = rows[i]
        if row.kind == "place" and row.secs == nil then
            n = n + 1
            local _, kind, m, x, y = Find.Entry(row.e)      -- an instance's row as its entrance, a flight master's as its stop (B8)
            proof.e[n], proof.mass[n], proof.x[n], proof.y[n], proof.uiMap[n], proof.kind[n], proof.ref[n] = row.e, m, x, y,
                Dest(row.e) or 0, (kind == 90 or kind == 91) and "entrance" or StopOf(row.e) and "stop" or "point", StopOf(row.e) or 0
        end
    end
    proof.n = n
    return n
end
local function Prove()
    proofWant = open and rested and ctx.fig and not job and true or false
    if proofWant or figWant then Lead.Chores(Env.Read()) end
end
local function OnProof(i, secs)
    tries = 0
    if i == "none" then proofWant = false return end
    local e = proof.e[i]
    proved[e] = secs
    for r = 1, rows.n do
        if rows[r].e == e and rows[r].kind == "place" then rows[r].secs = secs end
    end
    Publish(Order() and "order" or "figures")
end

local Run
local function OnFind(what)
    if what == "rows" then
        MakeRows()
        return Publish("rows")
    end
    job = false
    if what == "end" then Prove() end
end
local function Query()
    again = true
    if not job then job = ns.Work.Start("find", Run, false, OnFind) end
end
-- K8: the estimates of every entry, from where the player stands; the text is then listed again.
local function OnFigures(what, out)
    figWant, tries = false, 0
    if what ~= "estimates" then return end
    local fig = ctx.fig or {}
    for e = 1, Find.points.n do fig[e] = out[e] end
    ctx.fig = fig
    Query()
end
Run = function(_, pause, emit)
    if not built then Build(pause); built = true end
    local q
    repeat
        q, again = text, false
        Find.Query(q, ctx, pause)
    until q == text and not again
    emit("rows")
end

-- Where the player stands, for the order before the estimates; the estimates are asked again when they are old
-- or from elsewhere (K8), and what was planned from there is forgotten with them.
local function Here()
    local env = Env.Read()
    local away = Request.Away(env)
    ctx.mass, ctx.x, ctx.y, ctx.v = env.landmass, not away and env.x, env.y, ns.Ledger.Knowledge().vLand
    if not (away or figWant) and (not ctx.fig or env.now - figAt > Request.FIGURE_AGE
        or (env.x - figX) ^ 2 + (env.y - figY) ^ 2 > Request.FIGURE_YARDS ^ 2) then
        figWant = true
        for e in pairs(proved) do proved[e] = nil end
    end
    return env
end

function M.Subscribe(fn) subs[#subs + 1] = fn end
function M.Rows() return rows end

function M.Open(texts)
    if open then return end
    if T ~= texts or not kinds then T = texts; Words() end
    local _, _, faction = Env.Character()
    local _, class = UnitClassBase("player")
    ctx.faction, ctx.class = faction ~= 0 and faction, not issecretvalue(class) and class or 0
    open, built, text, rested, rest, zoneMap, figAt, rows.n, tries = true, false, "", false, false, 0, -huge, 0, 0
    Put("hint", T.FIND_HINT)
    Here()
    Query()
end

function M.Close()
    if not open then return end
    open, figWant, proofWant, rest = false, false, false, false
    Lead.Quit(OnFigures)
    Lead.Quit(OnProof)
    if job then ns.Work.Cancel(job) end
    job, ctx.fig, rows.n, nG, src, at, zoneName, proved = false, nil, 0, 0, {}, {}, {}, {}
    Find.Reset()
end

-- A keystroke: what was being planned for the old list is dropped, and the text is listed.
function M.Type(new)
    if not open or new == text then return end
    text, rested, rest, proofWant, tries = new, false, M.REST, false, 0
    Lead.Quit(OnProof)
    local env = Here()
    Query()
    if figWant then Lead.Chores(env) end
end

-- From the open box's OnUpdate: the rest after the last keystroke.
function M.Tick(elapsed)
    if not rest then return end
    rest = rest - elapsed
    if rest <= 0 then
        rest, rested = false, true
        Prove()
    end
end

-- B8: a trip of the player's own to row i's place; false and the Driver's reason when it is refused.
function M.Choose(i)
    local row = i <= rows.n and rows[i]
    if not row or row.kind ~= "place" then return false end
    local name, kind = Find.Entry(row.e)
    if kind == 90 or kind == 91 then
        return ns.Driver.Go("entrance", (ns.Net.Entrance(src[row.e - nG])), nil, nil, nil, name, "hand")
    end
    local uiMap, mx, my = Dest(row.e)
    return ns.Driver.Go(StopOf(row.e) and "stop" or "point", StopOf(row.e) or 0, uiMap, mx, my, name, "hand")
end

-- The two needs. A chore a plan cancelled is started again; one that keeps ending with nothing said (an error in
-- it) is given up after TRIES starts, until the next keystroke.
Lead.Need(function(env)
    if not (figWant and built) or tries >= M.TRIES then return end
    figAt, figX, figY, tries = env.now, env.x, env.y, tries + 1
    return Request.Figures(env, Find.points, OnFigures)
end)
Lead.Need(function(env)
    if not proofWant or tries >= M.TRIES then return end
    if List() == 0 then proofWant = false return end
    tries = tries + 1
    return Request.Prove(env, proof, OnProof)
end)
