local ADDON, ns = ...

-- The saved variables: options, what was learned (validated and scoped), the saved trip, frame positions.
local M = {}
ns.Ledger = M

M.SCHEMA, M.SAMPLE_GAP, M.SAMPLE_TRIES, M.MATCH, M.TRIP_KEEP, M.MAX_CHARS = 3, 0.5, 6, 30, 1800, 50
M.LOADING = 10

local huge, abs, floor, max, min = math.huge, math.abs, math.floor, math.max, math.min
local OPTIONS = { planner = { "b", true }, arrow = { "b", true }, arrowScale = { "s", 1, 0.5, 2 }, arrowLock = { "b", false },
    steps = { "b", true }, stepsScale = { "s", 1, 0.5, 2 }, stepsLock = { "b", false }, mapTrail = { "b", true },
    miniTrail = { "b", true }, arriveYards = { "i", 15, 5, 50 }, hearth = { "b", true }, spells = { "b", true },
    hearthMinSave = { "i", 5, 1, 30 }, caution = { "i", 0, 0, 2 }, followPin = { "b", true },
    drivePin = { "b", false }, arriveSound = { "b", false }, followGuide = { "b", true }, corpseRun = { "b", true },
    findButton = { "b", true }, splitFlights = { "b", false }, splitMinSave = { "i", 1, 1, 10 }, flightTimes = { "b", true },
    marks = { "b", true } }
local KINDS = { point = 1, entrance = 1, pin = 1, quest = 1, party = 1, stop = 1 }
local LEGS = { walk = 1, flight = 1, boat = 1, zeppelin = 1, tram = 1, lift = 1, portal = 1, hearth = 1, spell = 1 }
local ALL = { true, true, true, true, true, true }

-- S is what Learn works on: the selected tables, the build, the network, level and taxi-speed bonus.
local db, acct, realm, char, build, net = false, false, false, false, "", false
local know, dirty, rev, changes, mass, fmMass = false, true, 0, 0, {}, {}
local S = { char = false, level = 0, bonus = 0 }
-- The parts of the knowledge to build again ("all" for every one); the rest is shared with the last table.
local stale, landingOf, rowsOf, guessName, gm, gx, gy = { all = true }, {}, {}, false, nil, nil, nil

local function Num(v, lo, hi)
    return type(v) == "number" and v > -huge and v < huge and (not lo or v >= lo) and (not hi or v <= hi)
end
local function Int(v, lo, hi) return Num(v, lo, hi) and v % 1 == 0 end
local function Tbl(v) return type(v) == "table" end
local function Str(v) return type(v) == "string" end
-- Ids and landmasses are checked once the network data is loaded (at login); before that types and ranges.
local function Has(name, id) return not net or net[name](id) ~= nil end
local function Mass(m) return Int(m) and (not net or mass[m] == true) end
local function Pos(f, a, b, c)
    return Mass(f[a or "m"]) and Num(f[b or "x"], -4e4, 4e4) and Num(f[c or "y"], -4e4, 4e4)
end
local function Fact(f) return Tbl(f) and Str(f.b) and Int(f.n, 1) and Num(f.t) and (f.s == nil or Int(f.s, 0, 2)) end
local function Keep(t, ok)
    for k, v in pairs(Tbl(t) and t or {}) do if not ok(k, v) then t[k] = nil end end
    return Tbl(t) and t or {}
end
local function Count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local function Changed(part) dirty, changes, stale[part or "all"] = true, changes + 1, true return true end
local function Now() return ns.Env.Now() end
local function ValidOption(key, v)
    local o = OPTIONS[key]
    if not o or o[1] == "b" then return o ~= nil and type(v) == "boolean" end
    return (o[1] == "s" and Num(v, o[3], o[4])) or Int(v, o[3], o[4])
end
local function Chain(s, from, to)
    local first, last, n = false, false, 0
    for id in (Str(s) and s or ""):gmatch("%S+") do
        id = tonumber(id)
        if not Int(id) or not Has("StopOfNode", id) then return false end
        first, last, n = first or id, id, n + 1
    end
    return n >= 2 and first == from and last == to
end
-- Survey rows are saved as one string of whole yards (rounded up), "x" for an anchor with no walk: a table of
-- 4 * Net.A numbers per landing costs about 7 KB of saved text. A table as section 7 writes it is read too.
-- They carry the point they were surveyed from: rows of a point that moved are never used.
local function Rows(r)
    if not (Tbl(r) and Str(r.d) and Int(r.lv, 1, 100) and (Tbl(r.r) or Str(r.r)) and Pos(r)) then return false end
    local n = 0
    for v in (Str(r.r) and r.r or ""):gmatch("%S+") do
        n = (v == "x" and n + 4) or (Int(tonumber(v), -1) and n + 1) or -huge
    end
    for i = 1, Tbl(r.r) and #r.r or 0 do n = Num(r.r[i]) and n + 1 or -huge end
    return n >= 0 and (not net or n == 4 * net.A)
end
local function Decode(r)
    if Tbl(r) then return r end
    local out = {}
    for v in r:gmatch("%S+") do
        local n = #out
        if v == "x" then out[n + 1], out[n + 2], out[n + 3], out[n + 4] = -1, -1, -1, -1 else out[n + 1] = tonumber(v) end
    end
    return out
end
-- A saved sample list holds 1 to cap entries that ok accepts, each with its partner in list b when given.
local function Samples(t, cap, ok, b)
    if not (Tbl(t) and #t >= 1 and #t <= cap and (not b or Tbl(b) and #b == #t)) then return false end
    for i = 1, #t do if not ok(t[i], b and b[i]) then return false end end
    return true
end
local function FlySample(v, bonus) return Num(bonus, 0, 1) and Num(v, 20 * (1 + bonus), 45 * (1 + bonus)) end
local function LoadSample(v) return Num(v, 0, 120) end
local function Trip(t, keep)
    return Tbl(t) and KINDS[t.kind] and Num(t.ref) and Int(t.map) and Num(t.x, 0, 1) and Num(t.y, 0, 1)
        and Str(t.title) and Str(t.source) and Num(t.t) and (not keep or Now() - t.t <= M.TRIP_KEEP)
        and (t.kind ~= "stop" or Int(t.node) and Has("StopOfNode", t.node))
end
local function Trim(t, cap, rank)
    while Count(t) > cap do
        local low, key = huge, nil
        for k, v in pairs(t) do if rank(k, v) < low then low, key = rank(k, v), k end end
        t[key] = nil
    end
end

local function Char(c)
    c.seen, c.faction, c.hello = Num(c.seen) and c.seen or 0, Int(c.faction, 1, 2) and c.faction or nil, c.hello == true
    c.flights = Keep(c.flights, function(m, f)
        return Mass(m) and Tbl(f) and Str(f.b) and Num(f.t)
            and Keep(f.nodes, function(id, v) return v == true and Int(id) and Has("StopOfNode", id) end) == f.nodes
    end)
    c.chains = Keep(c.chains, function(from, row)
        return Int(from) and Tbl(row) and Keep(row, function(to, s) return Chain(s, from, to) end) and true
    end)
    if not (Fact(c.bind) and Str(c.bind.name) and Pos(c.bind)) then c.bind = nil end
    if not (Fact(c.speed) and Num(c.speed.land, 7, 30) and Num(c.speed.swim, 4.72, 15)) then c.speed = nil end
    local portals = {}
    for i = 1, Tbl(c.portals) and 20 or 0 do
        local p = c.portals[i]
        if Fact(p) and Pos(p, "m1", "x1", "y1") and Pos(p, "m2", "x2", "y2") and Num(p.sec, 0, 600) then
            portals[#portals + 1] = p
        end
    end
    c.portals, c.quests = portals, Keep(c.quests, function(id, q) return Int(id) and Tbl(q) and Pos(q) end)
    Trim(c.quests, 50, function(id) return id end)
    c.rows = Keep(c.rows, function(k, r) return Str(k) and Rows(r) end)
    if not Trip(c.trip, true) then c.trip = nil elseif not Trip(c.trip.resume) then c.trip.resume = nil end
end

local function Validate()
    db.options = Keep(db.options, ValidOption)
    for key, o in pairs(OPTIONS) do if db.options[key] == nil then db.options[key] = o[2] end end
    db.frames = Keep(db.frames, function(k, f)
        return (k == "pointer" or k == "steps" or k == "find") and Tbl(f) and Num(f.x, -1e4, 1e4) and Num(f.y, -1e4, 1e4)
    end)
    local a = Tbl(db.account) and db.account or {}
    local f, l = a.fly, a.loading
    db.account = a
    if not (Fact(f) and Num(f.v, 20, 45) and Samples(f.samples, 9, FlySample, f.bonus)) then a.fly = nil end
    if not (Fact(l) and Num(l.v, 0, 120) and Samples(l.samples, 10, LoadSample)) then a.loading = nil end
    a.vessels = Keep(a.vessels, function(p, v)
        if Tbl(v) then v.speed = nil end    -- a speed older versions saved: the rides ship now
        return Int(p) and Has("VesselOfPath", p) and Fact(v) and v.runs == true and (v.off == nil or Num(v.off, -600, 600))
    end)
    a.landings = Keep(a.landings, function(s, w) return Int(s) and Has("SpellByID", s) and Fact(w) and Pos(w) end)
    a.doors = Keep(a.doors, function(m, d)
        return Int(m) and Has("EntranceOfMap", m) and Fact(d) and Pos(d) and type(d.ok) == "boolean"
    end)
    a.errors = Keep(a.errors, function(k, e) return LEGS[k] and Tbl(e) and Int(e.n, 1) and Num(e.sum) and Num(e.abs, 0) end)
    a.clock = Keep(a.clock, function(p, l) return Int(p) and Has("VesselOfPath", p) and ns.Learn.Record(l) end)
    db.realms = Keep(db.realms, function(k, r)
        if Str(k) and k ~= "0" and Tbl(r) then      -- "0" is no realm's id
            r.phases = Keep(r.phases, function(p, tt) return Int(p) and Has("VesselOfPath", p)
                and ns.Learn.One(r.phases, p, tt, net and net.VesselOfPath(p)) end)
            return true
        end
    end)
    -- Only the character logging in is read in full (Ledger.Login); every other one at its own login.
    db.chars = Keep(db.chars, function(g, c)
        if Str(g) and Tbl(c) then c.seen = Num(c.seen) and c.seen or 0 return true end
    end)
    Trim(db.chars, M.MAX_CHARS, function(_, c) return c == char and huge or c.seen end)
end

function M.Load()
    local saved = FerrymanDB
    if Tbl(saved) and Num(saved.v) and saved.v > M.SCHEMA then
        db = { v = M.SCHEMA }
    else
        db = Tbl(saved) and saved or {}
        -- 2: the arrival sound is off by default, also where version 1 had saved its default
        if db.v == 1 and Tbl(db.options) then db.options.arriveSound = false end
        -- 3: caution is off by default; a saved 1 was the old default, a 2 was chosen
        if (db.v == 1 or db.v == 2) and Tbl(db.options) and db.options.caution == 1 then db.options.caution = 0 end
        db.v, FerrymanDB = M.SCHEMA, db
    end
    net, char = false, false
    Validate()
    acct, realm, char = db.account, { phases = {} }, {}
    Char(char)
    Changed()
end

function M.Login(guid, realmKey, faction, b)
    net, build, mass, fmMass = ns.Net, b, {}, {}
    local _, _, platform = net.TramStops()
    for a = 1, net.A do
        local m = net.Anchor(a)
        mass[m] = mass[m] or ns.Env.HasCompanion(m)
    end
    mass[(net.Anchor(platform))] = true
    for i = 1, net.S do
        local kind, m = net.Stop(i)
        fmMass[m] = fmMass[m] or kind == 1 or nil
    end
    char = guid and Tbl(db.chars[guid]) and db.chars[guid] or {}
    if guid then db.chars[guid] = char end
    Validate()
    Char(char)
    db.realms[realmKey] = db.realms[realmKey] or { phases = {} }
    char.seen, char.faction, acct, realm = Now(), faction, db.account, db.realms[realmKey]
    S.char, S.acct, S.realm, S.build, S.net = char, acct, realm, build, net
    S.level, S.bonus = select(4, ns.Env.Character()), ns.Env.FlightBonus()
    ns.Learn.Attach(S, Changed)
    Changed()
end

function M.Options() return db.options end
function M.SetOption(key, v)
    local o = OPTIONS[key]
    if o and o[1] == "s" and Num(v) then v = floor(v * 20 + 0.5) / 20 end
    if not ValidOption(key, v) then return false end
    db.options[key] = v
    return true
end

-- Walking data attached: the landings' saved rows may now be read (Env.LoadGround). True.
function M.GroundAttached() return Changed("landings") end

-- Knowledge: a new frozen table whenever a fact in it changed (INTERFACES 3.4, decision 50).
local function Landing(key, m, x, y, est)
    local r, G, l = char.rows[key], ns.Ground, landingOf[key]
    local caps = r and G.Has and G.Has(m) and G.Caps(m)
    local src = caps and caps.digest == r.d and abs(r.lv - S.level) < 5 and r.m == m and abs(r.x - x) <= 1
        and abs(r.y - y) <= 1 and r or false
    if not (l and l.landmass == m and l.x == x and l.y == y and l.est == est and rowsOf[key] == src) then
        l = { key = key, landmass = m, x = x, y = y, est = est, anchor = net.Nearest(m, x, y, ALL, 0.5) or 0,
            rows = src and Decode(src.r) }
        landingOf[key], rowsOf[key] = l, src
    end
    return l
end
local function Build()
    rev = rev + 1
    local sp, fm, b, name, all, old = char.speed, ns.Measured.flight, char.bind, ns.Env.BindName(), stale.all, know or {}
    local k = { rev = rev, vLand = max(sp and sp.land or 0, net.BASE_RUN), vSwim = max(sp and sp.swim or 0, net.BASE_SWIM),
        remount = (sp and sp.land or 0) >= 0.95 * ns.Measured.move.mounts[1][3] and ns.Measured.move.remount[1] or 0,
        vFly = (acct.fly and acct.fly.v or fm.speed[1]) * (1 + S.bonus), boardFlight = net.BOARD_FLIGHT + fm.takeoff[1],
        hopFlight = fm.hop[1], loading = acct.loading and acct.loading.v or M.LOADING, learned = old.learned,
        unread = old.unread, chains = old.chains, vessels = old.vessels, bind = old.bind, landings = old.landings,
        portals = old.portals, doors = old.doors, quests = old.quests, build = build }
    if all or stale.flights then
        k.learned, k.unread, k.chains = {}, {}, {}
        for m in pairs(fmMass) do k.unread[m] = not char.flights[m] or nil end
        for _, f in pairs(char.flights) do for id in pairs(f.nodes) do k.learned[net.StopOfNode(id)] = true end end
        for from, row in pairs(char.chains) do
            for to, s in pairs(row) do
                local list = {}
                for id in s:gmatch("%d+") do list[#list + 1] = net.StopOfNode(tonumber(id)) end
                k.chains[net.StopOfNode(from) * 1024 + net.StopOfNode(to)] = list
            end
        end
    end
    if all or stale.vessels then k.vessels = {} end
    for v = 1, (all or stale.vessels) and net.VesselCount or 0 do
        local path = net.Vessel(v)
        local service, _, period = net.Service(v)
        local tt, sv, copy = not ns.Learn.Missed(path) and realm.phases[path], acct.vessels[path], false
        for key, x in pairs(tt or {}) do copy = copy or {} copy[key] = x end
        k.vessels[v] = { runs = sv and "yes" or service, period = period, tt = copy }
    end
    if all or stale.landings then
        local m, x, y = b and b.name == name and b.m, b and b.x, b and b.y
        if not m then
            if name ~= guessName then guessName, gm, gx, gy = name, ns.Learn.BindGuess(name) end
            m, x, y = gm, gx, gy
        end
        k.bind, k.landings, k.portals = m and Landing("bind", m, x, y, not (b and b.name == name)) or false, {}, {}
        for i = 1, net.SpellCount do
            local s = net.Spell(i).spell
            local l, lm, lx, ly, est = acct.landings[s], net.Landing(s)
            if l then lm, lx, ly, est = l.m, l.x, l.y, false end
            if lm and not net.IsBindSpell(s) then k.landings[s] = Landing("spell:" .. s, lm, lx, ly, est == true) end
        end
        for i, p in ipairs(char.portals) do
            if p.n >= 2 then
                k.portals[#k.portals + 1] = { key = "portal:" .. i, seconds = p.sec,
                    from = Landing("portal:" .. i .. ":a", p.m1, p.x1, p.y1, false),
                    to = Landing("portal:" .. i .. ":b", p.m2, p.x2, p.y2, false) }
            end
        end
    end
    if all or stale.doors then
        k.doors = {}
        for map, d in pairs(acct.doors) do k.doors[map] = { landmass = d.m, x = d.x, y = d.y, confirmed = d.ok } end
    end
    if all or stale.quests then
        k.quests = {}
        for id, q in pairs(char.quests) do k.quests[id] = { landmass = q.m, x = q.x, y = q.y } end
    end
    for part in pairs(stale) do stale[part] = nil end
    know, dirty = k, false
end
function M.Knowledge()
    if net and (dirty or not know) then Build() end
    return know
end

function M.SetRows(key, digest, lv, rows, m, x, y)
    local r = {}
    for a = 1, #rows / 4 do
        local i = 4 * a - 3
        r[#r + 1] = rows[i] < 0 and "x" or ("%d %d %d %d"):format(math.ceil(rows[i]), math.ceil(rows[i + 1]),
            math.ceil(rows[i + 2]), math.ceil(rows[i + 3]))
    end
    char.rows[key] = { d = digest, lv = lv, r = table.concat(r, " "), m = m, x = floor(x + 0.5), y = floor(y + 0.5) }
    Changed("landings")
end
-- The learning surface of INTERFACES 5.2; the rules live in Learn. Each returns whether Knowledge() changed.
function M.Note(fact, env, a, b)
    local before = changes
    if net then ns.Learn.Note(fact, env, a, b) end
    return changes ~= before
end
function M.Tick(env)
    local before = changes
    if net then ns.Learn.Tick(env) end
    return changes ~= before
end
function M.Taxi(nodes, n, uiMap)
    if not net then return nil, false end
    return ns.Learn.Taxi(nodes, n, uiMap)
end
function M.Flight() return ns.Learn.Flight() end
function M.Ride() return ns.Learn.Ride() end
function M.Timetable(v, now, out) return ns.Learn.Timetable(v, now, out) end
function M.Missed(path, set) return ns.Learn.Missed(path, set) end
function M.LegTimed(kind, predicted, measured)
    local e = acct.errors[kind] or { n = 0, sum = 0, abs = 0 }
    e.n, e.sum, e.abs = e.n + 1, e.sum + predicted - measured, e.abs + abs(predicted - measured)
    acct.errors[kind] = e
end

-- Every learned fact, in the order /ferry learned prints them: fn(key, scope, text, a, b, c, rec, owner, field).
local function Each(fn)
    local E, nc, nq, b, sp, fly, l = ns.Env, 0, Count(char.quests), char.bind, char.speed, acct.fly, acct.loading
    local function Zone(m, x, y) return E.MapName(E.ZoneAt(m, x, y)) or "" end
    local function Vessel(path)
        return E.PlaceName({ kind = "stop", anchor = (net.Call(net.VesselOfPath(path), 1)) })
    end
    for m, f in pairs(char.flights) do
        fn("flights:" .. m, "character", "L_FLIGHTS", E.LandmassName(m) or "", Count(f.nodes), nil, f, char.flights, m)
    end
    for m in pairs(fmMass) do
        if not char.flights[m] then fn("flights:" .. m, "character", "L_FLIGHTS_UNREAD", E.LandmassName(m) or "") end
    end
    for _, row in pairs(char.chains) do nc = nc + Count(row) end
    if nc > 0 then fn("chains", "character", "L_CHAINS", nc, nil, nil, nil, char, "chains") end
    if b then fn("bind", "character", "L_BIND", b.name, nil, nil, b, char, "bind") end
    if sp then
        local pl, ps = floor(sp.land / net.BASE_RUN * 100 + 0.5), floor(sp.swim / net.BASE_SWIM * 100 + 0.5)
        fn("speed", "character", "L_SPEED", pl, ps, nil, sp, char, "speed")
    end
    if fly then fn("flight-speed", "account", "L_FLY", ("%.1f"):format(fly.v), #fly.samples, nil, fly, acct, "fly") end
    for path, v in pairs(acct.vessels) do
        local off = v.off and (v.off < -ns.Learn.RIDE_EARLY or v.off > ns.Learn.RIDE_LATE) and v.off
        fn("vessel:" .. path, "account", off and "L_VESSEL_OFF" or "L_VESSEL", Vessel(path),
            off or floor(select(3, net.Service(net.VesselOfPath(path))) + 0.5), nil, v, acct.vessels, path)
    end
    for path, tt in pairs(realm.phases) do     -- what the pier would show now
        local w = ns.Learn.Timetable(net.VesselOfPath(path), Now())
        fn("phase:" .. path, "realm", w and (w.tier == "about" and "L_PHASE_ABOUT" or "L_PHASE") or "L_PHASE_KEPT", Vessel(path),
            w and floor(w.u + 0.5) or nil, nil, tt, realm.phases, path)
    end
    for id, w in pairs(acct.landings) do
        fn("landing:" .. id, "account", "L_LANDING", id, Zone(w.m, w.x, w.y), nil, w, acct.landings, id)
    end
    for map, d in pairs(acct.doors) do
        fn("door:" .. map, "account", "L_DOOR", E.InstanceName(map) or "", nil, nil, d, acct.doors, map)
    end
    for i, p in ipairs(char.portals) do
        local a, b = Zone(p.m1, p.x1, p.y1), Zone(p.m2, p.x2, p.y2)
        fn("portal:" .. i, "character", "L_PORTAL", a, b, nil, p, char.portals, i)
    end
    if nq > 0 then fn("quests", "character", "L_QUESTS", nq, nil, nil, nil, char, "quests") end
    local np = ns.Seen.Count()
    if np > 0 then fn("places", "account", "L_PLACES", np, nil, nil, nil, acct, "seen") end
    if l then fn("loading", "account", "L_LOADING", floor(l.v + 0.5), nil, nil, l, acct, "loading") end
    for kind, e in pairs(acct.errors) do
        fn("errors", "account", "L_ERROR", kind, floor(e.abs / e.n + 0.5), e.n, nil, acct.errors, kind)
    end
end
local function Tidy()
    Char(char)
    realm.phases = Tbl(realm.phases) and realm.phases or {}
    Changed()
end
function M.Describe(out)
    local n = 0
    Each(function(key, scope, text, a, b, c, rec)
        n = n + 1
        local r = out[n] or {}
        out[n], r.key, r.scope, r.text, r.a, r.b, r.c = r, key, scope, text, a, b, c
        r.build, r.count = rec and (rec.b or rec.build) or build, rec and (rec.n or rec.count) or 1
        r.confirmed = r.build == build and (not rec or (rec.n or rec.count or 2) >= 2)
    end)
    return n
end
function M.Forget(key)
    local n = 0
    Each(function(k, _, _, _, _, _, _, owner, field)
        if owner and (key == nil or k == key) then owner[field], n = nil, n + 1 end
    end)
    if key == nil then
        for _, c in pairs(db.chars) do c.flights, c.chains, c.bind, c.speed, c.portals, c.quests, c.rows = nil end
        for _, r in pairs(db.realms) do r.phases = nil end
        char.rows = nil
    end
    if n > 0 or key == nil then Tidy() end
    return n
end
function M.Strike(key)
    local hit = false
    Each(function(k, _, _, _, _, _, rec, owner, field)
        if k == key and rec and rec.s then
            rec.s = rec.s + 1
            if rec.s >= 2 then owner[field], hit = nil, true end
        end
    end)
    if hit then Tidy() end
    return hit
end

-- A party member's trip is not saved: its title is their name (decision 40), and the index may be someone else's;
-- nor is one that follows RestedXP, which is followed afresh. One level of resume is kept. A flight master keeps
-- its TaxiNodes id: a rebuilt network renumbers stops.
local function Saved(d, inner)
    return d and d.kind ~= "party" and d.source ~= "guide" and { kind = d.kind, ref = d.ref, map = d.uiMap, x = d.mx,
        y = d.my, title = d.title, source = d.source, t = d.at or Now(), resume = not inner and Saved(d.resume, true) or nil,
        node = d.kind == "stop" and select(7, net.Stop(d.ref)) or nil } or nil
end
local function Spec(t, inner)
    return t and { kind = t.kind, ref = t.node and net.StopOfNode(t.node) or t.ref, uiMap = t.map, mx = t.x, my = t.y,
        title = t.title, source = t.source, at = t.t, resume = not inner and Spec(t.resume, true) or nil }
end
-- Any destination, a followed one too, means the character knows how to start: no more hello.
function M.SaveTrip(dest) if dest then char.hello = true end char.trip = Saved(dest) end
function M.SavedTrip()
    local t = char.trip
    return t and Now() - t.t < M.TRIP_KEEP and Spec(t) or nil
end
function M.FramePos(name)
    local f = db.frames[name]
    if f then return f.x, f.y end
end
function M.SetFramePos(name, x, y) if Num(x) and Num(y) then db.frames[name] = { x = x, y = y } end end
function M.ResetFrames() db.frames = {} end
function M.Hello() return char.hello == true end
function M.DiedIn(map) if map ~= nil then char.diedIn = map or nil end return char.diedIn end     -- Driver.Login checks it
-- The learned places (Seen, 5.8): account.seen, made when missing.
function M.Seen() acct.seen = Tbl(acct.seen) and acct.seen or {} return acct.seen end
