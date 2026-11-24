local ADDON, ns = ...

-- The Ledger's learning rules (INTERFACES 5.2, DESIGN 5 "What ships measured, and what is learned"): what a
-- Senses fact, a tick or the flight window teaches. The Ledger owns the saved tables and hands them over at
-- login; everything here is reached through Ledger.Note, Ledger.Tick and Ledger.Taxi.
local M = {}
ns.Learn = M

local huge, sqrt, min, max, floor, abs = math.huge, math.sqrt, math.min, math.max, math.floor, math.abs
local FAR, CAST_WINDOW, PORTAL_WINDOW, EXIT_REACH, PORTAL_START_MATCH, RIDE_END = 50, 20, 60, 40, 15, 100
M.RIDE_EARLY, M.RIDE_LATE = 7, 4
-- A speed is travel speed once held unchanged this long: past Sprint, Dash and the speed potions (15 to 20 s),
-- so a mount, a form or an aura counts. A summon offer is answered within two minutes.
local SUSTAIN, SUMMON_WINDOW, RECENT, CHOSE = 30, 120, 3, 5
local FM, PORTAL_START = { [1] = true }, { [2] = true, [3] = true, [4] = true }
-- Follow-up reads are aimed at fixed offsets from the triggering fact, a hair early, so frame timing never
-- pushes the last one past SAMPLE_TRIES * SAMPLE_GAP.
local LOOK_EARLY = 0.002

local S, Changed = { char = false }, false
local seen, outdoor = { t = -huge }, { t = -huge }
local loading, loadT, castT, deathT, summonT, flight, ride = false, false, -huge, -huge, -huge, false, { start = false }
local wantHearth, wantSpell, wantBound, wantPortal, wantExit, exitT = false, false, false, false, false, 0
local tries, looking, lookT, tickT, holdV, holdT, holdSwim = 0, false, 0, -huge, 0, 0, false
local hops = {}
local slots, chosen, choseT = {}, false, -huge    -- the last window read's slot to node; the stop chosen in it, when
local missed = {}       -- vessels whose estimated departure a wait saw pass: untimed until a ride, this session

local function Now() return ns.Env.Now() end
local function Dist(m1, x1, y1, m2, x2, y2) return m1 == m2 and sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2) or huge end
-- Saved positions keep whole yards and times whole seconds: the client writes every other number with 17
-- digits, so the saved text stays small.
local function R(v, step) step = step or 1 return floor(v / step + 0.5) * step end
local function Learned(f, n) f.b, f.t, f.n = S.build, floor(Now()), n or (f.n or 0) + 1 return f end
local function Merge(old, m, x, y)
    if old and Dist(old.m, old.x, old.y, m, x, y) <= ns.Ledger.MATCH then return Learned(old) end
    return Learned({ m = m, x = R(x), y = R(y), s = 0 }, 1)
end
local function Median(list)
    local s, n = {}, #list
    for i = 1, n do s[i] = list[i] end
    table.sort(s)
    return n % 2 == 1 and s[(n + 1) / 2] or (s[n / 2] + s[n / 2 + 1]) / 2
end
local function Push(list, v, cap)
    list[#list + 1] = v
    if #list > cap then table.remove(list, 1) end
    return Median(list)
end
local function NodeOf(a)
    local net = S.net
    local ok = a and a > 0 and a <= net.S
    local kind, _, _, _, _, _, ref = net.Stop(ok and a or 1)
    return ok and kind == 1 and ref or nil
end

function M.Attach(state, changed)
    S, Changed = state, changed
    for path in pairs(missed) do missed[path] = nil end
    ride.start, flight, loading, loadT = false, false, false, false
    wantHearth, wantSpell, wantBound, wantPortal, wantExit = false, false, false, false, false
end

-- A position is taken only when two reads half a second apart agree (env.still), never inside a loading
-- screen; while no tick runs, up to SAMPLE_TRIES one-shot follow-up reads (INTERFACES decision 42).
local Look
local function Schedule()
    local L = ns.Ledger
    looking = true
    ns.Env.After(max(0, lookT + (L.SAMPLE_TRIES - tries + 1) * L.SAMPLE_GAP - LOOK_EARLY - Now()), Look)
end
local function StartLooks()
    tries, lookT = ns.Ledger.SAMPLE_TRIES, Now()
    if not looking and lookT - tickT > 1.5 then Schedule() end
end
local function Store(owner, field, m, x, y)
    owner[field] = Merge(owner[field], m, x, y)
    Changed("landings")
    return owner[field]
end
local function Bind(name, m, x, y)
    local char = S.char
    if char.bind and char.bind.name ~= name then char.bind = nil end
    Store(char, "bind", m, x, y).name = name
end
-- A portal spell's jump counts only from where the portal was opened.
local function Jumped(w)
    if w and Dist(seen.m, seen.x, seen.y, w.m, w.x, w.y) <= EXIT_REACH then w.jumped = true end
end
-- outdoor.on: every read since the last outdoor one followed on (no gap over 1.5 s, jump or loading screen), so
-- the way from it indoors to a portal is known to start there.
local function Track(env)
    if loading or not env.ok then return end
    if env.jump then Jumped(wantSpell) end
    outdoor.on = outdoor.on and not env.jump and env.now - seen.t <= 1.5
    seen.m, seen.x, seen.y, seen.t, seen.moving = env.landmass, env.x, env.y, env.now, ns.Senses.moving == true
    seen.instance, seen.map = env.instance, env.instanceMap
    if not (env.instance or env.indoors) then
        outdoor.m, outdoor.x, outdoor.y, outdoor.t, outdoor.on = env.landmass, env.x, env.y, env.now, true
    end
end
-- A full list makes room by dropping the oldest single traversal.
local function Portal(w, m, x, y)
    local portals, hit, old = S.char.portals, nil, nil
    for i, q in ipairs(portals) do
        if Dist(q.m1, q.x1, q.y1, w.m, w.x, w.y) <= PORTAL_START_MATCH then hit = i end
        if q.n == 1 and (not old or q.t < portals[old].t) then old = i end
    end
    local q = hit and portals[hit]
    if q and Dist(q.m2, q.x2, q.y2, m, x, y) <= ns.Ledger.MATCH then
        Learned(q)
    else
        hit = hit or (#portals < 20 and #portals + 1) or old
        if not hit then return end
        portals[hit] = Learned({ m1 = w.m, x1 = R(w.x), y1 = R(w.y), m2 = m, x2 = R(x), y2 = R(y),
            sec = R(w.sec, 0.1), s = 0 }, 1)
    end
    Changed("landings")
end
local function Sample(env)
    if loading or not env.ok or env.still < ns.Ledger.SAMPLE_GAP then return end
    local E, m, x, y, t, w, late = ns.Env, env.landmass, env.x, env.y, env.now, wantHearth, 0
    -- At the bind place: its name is the subzone's, or in a city the zone's.
    local name = (wantHearth or wantBound) and E.BindName() or ""
    local here = name ~= "" and (E.SubZone() == name or E.MapName(env.uiMap) == name)
    if w and (t - w.t > CAST_WINDOW or env.instance) then wantHearth = false end
    if wantHearth and Dist(m, x, y, w.m, w.x, w.y) >= FAR then
        if here then Bind(name, m, x, y) end
        wantHearth = false
    end
    w = wantSpell
    if w and (t - w.t > (w.dest == 3 and PORTAL_WINDOW or CAST_WINDOW) or env.instance) then wantSpell = false end
    if wantSpell and Dist(m, x, y, w.m, w.x, w.y) >= FAR and (w.dest ~= 3 or w.jumped) then
        Store(S.acct.landings, w.spell, m, x, y)
        wantSpell = false
    end
    w, late = wantBound, ns.Ledger.SAMPLE_TRIES * ns.Ledger.SAMPLE_GAP
    if here and w and t - w.t <= late and Dist(m, x, y, w.m, w.x, w.y) <= ns.Ledger.MATCH then Bind(name, m, x, y) end
    w, wantBound, wantPortal = wantPortal, false, false
    if w and t - w.t <= RECENT and not env.instance then Portal(w, m, x, y) end
    local d = wantExit and t - exitT <= late and S.acct.doors[wantExit]
    if d and not d.ok and Dist(d.m, d.x, d.y, m, x, y) <= EXIT_REACH then d.ok = Changed("doors") end
    wantExit = false
end
Look = function()
    looking, tries = false, tries - 1
    if Now() - tickT <= 1.5 then return end
    local env = ns.Env.Read()
    Track(env)
    Sample(env)
    if (wantHearth or wantSpell or wantBound or wantPortal or wantExit) and tries > 0 then Schedule() end
end

local function Landed(env, anchor)
    local f, from, to, char, acct = flight, NodeOf(flight.from), NodeOf(anchor), S.char, S.acct
    local chain = from and to and char.chains[from] and char.chains[from][to]
    local yards, prev, bonus = f.loads == 0 and chain and not chain:find("%S%s+%S+%s+%S") and 0, nil, S.bonus -- one leg (16.6)
    flight = false
    for id in (yards and chain or ""):gmatch("%d+") do
        local i = S.net.StopOfNode(tonumber(id))
        local part = prev and i and S.net.FlightYards(prev, i)
        yards, prev = yards and (not prev or part) and yards + (part or 0), i
    end
    local base = yards and yards / (env.now - f.t) / (1 + bonus)
    if not (base and base >= 20 and base <= 45) then return end
    local fly, bases = acct.fly or { samples = {}, bonus = {} }, {}
    acct.fly = fly
    Push(fly.samples, R(base * (1 + bonus), 0.01), 9)
    Push(fly.bonus, bonus, 9)
    for i = 1, #fly.samples do bases[i] = fly.samples[i] / (1 + fly.bonus[i]) end
    fly.v = Median(bases)
    Learned(fly, #fly.samples)
    Changed("fly")
end
-- The one vessel that calls at dock a and runs (shipped so, or seen to); none, or two, is timed by no ride.
local function VesselAt(a)
    local net, found = S.net, 0
    for v = 1, net.VesselCount do
        if net.CallAt(v, a) and (net.Service(v) ~= "no" or S.acct.vessels[(net.Vessel(v))]) then found = found == 0 and v or -1 end
    end
    return max(found, 0)
end
-- The ride ends at the last read that moved without walking: the boat docking, not where the player stops. Left
-- standing, the deck slowing at a steady rate came to rest 2 d / v after it. A ride that took the table's time
-- teaches where in its lap the vessel is, on the realm's one timetable of it (Clock.Observe, the shipped row's claim
-- its prior); one that did not teaches that the table is not this vessel's. The vessel's last six observations are
-- kept (account.clock), whether the ride crossed a client build with them.
local function Observed(path, t, x, r, laps, miss)
    local list = S.acct.clock[path] or {}
    S.acct.clock[path], list[#list + 1] = list, { t = floor(t), laps = laps, miss = R(miss, 0.1), r = r, x = x }
    if #list > 6 then table.remove(list, 1) end
end
local function Rode(env)
    local v, C, net = ride.v, ns.Clock, S.net
    local path = net.Vessel(v)
    local _, _, P, lo, hi, prior = net.Service(v)
    local sm, sx, sy = net.Anchor((net.Call(v, ride.to)))
    local d, endT = Dist(env.landmass, env.x, env.y, ride.m, ride.x, ride.y), ride.endT
    if endT and not ride.walked and d < huge then endT = endT + min(2 * d / ride.vEnd, env.now - endT) end
    if not endT or Dist(sm, sx, sy, ride.m, ride.x, ride.y) > RIDE_END then return end
    local off = endT - ride.start - net.Ride(v, ride.call)
    S.acct.vessels[path] = Learned({ runs = true, off = R(off, 0.1) }, ((S.acct.vessels[path] or {}).n or 0) + 1)
    if off >= -M.RIDE_EARLY and off <= M.RIDE_LATE then
        local tt = S.realm.phases[path] or C.New(P, C.Start(P, prior) / P, S.build)
        local x = tt.phase and tt.build ~= S.build or nil
        S.realm.phases[path], tt.off = tt, nil
        Observed(path, env.now, x, C.Observe(tt, ride.start - net.Offset(v, ride.call), env.now, S.build, prior, P, lo, hi))
    else    -- the first ride off the table's time is passed over; a second in a row drops the timetable
        local tt = S.realm.phases[path]
        S.realm.phases[path] = tt and not tt.off and tt or nil
        if tt then tt.off = true end
    end
    missed[path] = nil
    Changed("vessels")
end
local function LoadEnd(env, isLogin, isReload)
    local net, acct = S.net, S.acct
    if loadT and not (isLogin or isReload) then
        local l, gone, summoned = acct.loading or { samples = {} }, env.now - loadT, loadT - summonT <= SUMMON_WINDOW
        if gone <= 120 then     -- longer is a stall, and the saved table would drop every sample for it
            acct.loading, l.v = l, Push(l.samples, R(gone, 0.01), 10)
            Learned(l, #l.samples)
            Changed("loading")
        end
        if gone <= 600 and seen.m and (not seen.moving or loadT - seen.t <= 2) and env.ok and not (env.instance or seen.instance
            or env.dead or env.taxi or flight or summoned or ns.Senses.carried or ride.start)
            and loadT - castT > CAST_WINDOW and Dist(env.landmass, env.x, env.y, seen.m, seen.x, seen.y) > 500
            and not net.Nearest(seen.m, seen.x, seen.y, PORTAL_START, ns.Senses.CARRY_REACH) then
            wantPortal = { m = seen.m, x = seen.x, y = seen.y, sec = gone, t = env.now }
        end
        local k = env.instance and net.EntranceOfMap(env.instanceMap)
        if k and not select(3, net.Entrance(k)) and outdoor.on and outdoor.t > max(castT, deathT)
            and loadT - seen.t <= RECENT and not (flight or summoned) then
            local old = acct.doors[env.instanceMap]
            local d = Merge(old, outdoor.m, outdoor.x, outdoor.y)
            d.ok, acct.doors[env.instanceMap] = d == old, d
            Changed("doors")
        end
        if seen.instance and not env.instance and acct.doors[seen.map] then wantExit, exitT = seen.map, env.now end
        Jumped(wantSpell)
        -- The cast windows count time the player could act in, not the loading screen.
        if wantHearth then wantHearth.t = wantHearth.t + gone end
        if wantSpell then wantSpell.t = wantSpell.t + gone end
    end
    if isLogin or isReload then ride.start, flight = false, false end
    loading, loadT, outdoor.on = false, false, false
    StartLooks()
end

function M.Note(fact, env, a, b)
    local net, char = S.net, S.char
    if fact == "loadStart" then
        loading, loadT = true, env.now
        if flight then flight.loads = flight.loads + 1 end
        return
    elseif fact == "loadEnd" then
        LoadEnd(env, a, b)
    end
    Track(env)
    if fact == "chose" then
        chosen, choseT = slots[a] and net.StopOfNode(slots[a]) or false, env.now
    elseif fact == "tookOff" then
        flight = { from = a, t = env.now, loads = 0, to = env.now - choseT <= CHOSE and chosen }
    elseif fact == "landed" and flight then
        Landed(env, a)
    elseif fact == "cast" then
        local k = net.SpellByID(a)
        local w = { m = env.landmass, x = env.x, y = env.y, t = env.now, spell = a, dest = k and net.Spell(k).dest }
        castT = env.now
        if w.dest and env.ok then
            wantHearth, wantSpell = w.dest == 1 and w, w.dest ~= 1 and w
            StartLooks()
        end
    elseif fact == "bound" then
        wantBound = env.ok and { t = env.now, m = env.landmass, x = env.x, y = env.y }
        Changed("landings")
        StartLooks()
    elseif fact == "summon" then
        summonT = env.now
    elseif fact == "carried" then
        local v = VesselAt(a)
        local c = v > 0 and net.CallAt(v, a)
        ride.v, ride.call, ride.to, ride.endT = v, c, c and c % select(5, net.Vessel(v)) + 1, false
        ride.start = c and env.now - (b or 2 * env.dt)
    elseif fact == "dropped" and ride.start then
        Rode(env)
        ride.start = false
    elseif fact == "died" then
        deathT = env.now
    elseif fact == "quest" then
        char.quests[a] = b and env.ok and not env.instance and { m = env.landmass, x = R(env.x), y = R(env.y) } or nil
        local n, low = 0, huge
        for id in pairs(char.quests) do n, low = n + 1, min(low, id) end
        if n > 50 then char.quests[low] = nil end
        Changed("quests")
    elseif fact == "level" then
        S.level = a or S.level
        Changed("landings")
    elseif fact == "spells" and ns.Env.FlightBonus() ~= S.bonus then
        S.bonus = ns.Env.FlightBonus()
        Changed("fly")
    elseif fact == "login" then
        ride.start, flight = false, false
    end
end

-- Travel speed: the highest readable speed held unchanged for SUSTAIN seconds of ticks, outdoors on the ground
-- or swimming, alive and carried by nothing; a jump, a stop, a step indoors or a hidden reading passes over the
-- hold without breaking it. Also the end of a timed ride.
function M.Tick(env)
    local v, swim, char, net, gap = env.speed, env.swimming, S.char, S.net, env.now - tickT
    tickT = env.now
    Track(env)
    Sample(env)
    local walking = v ~= 0 and (v or ns.Senses.moving)
    if ride.start and env.ok and not ns.Senses.loading and env.moved >= 0.5 and not walking then
        ride.endT, ride.m, ride.x, ride.y = env.now, env.landmass, env.x, env.y
        ride.vEnd, ride.walked = env.moved / env.dt, false
    end
    ride.walked = ride.walked or walking
    local ok = env.ok and not (env.dead or env.taxi or env.flying or ns.Senses.carried)
    local pass = not v or v == 0 or env.falling or (env.indoors and not swim)
    if not ok or gap > 1.5 or not pass and (swim ~= holdSwim or abs(v - holdV) > 0.01) then
        holdV, holdT, holdSwim = ok and not pass and v or 0, env.now, swim
    end
    if not ok or pass or env.now - holdT < SUSTAIN then return end
    local field, sp = swim and "swim" or "land", char.speed
    local was = sp and sp[field] or (swim and net.BASE_SWIM or net.BASE_RUN)
    if holdV > was + 0.01 and holdV <= (swim and 15 or 30) then
        sp = sp or { land = net.BASE_RUN, swim = net.BASE_SWIM }
        sp[field], char.speed = R(holdV, 0.001), Learned(sp)
        Changed("speed")
    end
end

function M.Taxi(nodes, n)
    local net, char, set, cur, m = S.net, S.char, {}, nil, nil
    for k in pairs(slots) do slots[k] = nil end
    for i = 1, n do
        local r = nodes[i]
        local id = r.node ~= 0 and r.node or r.landmass and NodeOf(net.Nearest(r.landmass, r.x, r.y, FM, 100)) or 0
        local stop = id ~= 0 and net.StopOfNode(id)
        slots[r.slot] = stop and id or nil
        if stop and (r.state == "current" or r.state == "reachable") then
            local _, sm = net.Stop(stop)
            set[id], m, cur = true, r.state == "current" and sm or m or sm, r.state == "current" and id or cur
        end
    end
    if not m then return nil, false end
    local old, row, count, same = char.flights[m], char.chains[cur] or {}, 0, true
    for id in pairs(set) do count, same = count + 1, same and old ~= nil and old.nodes[id] == true end
    for _ in pairs(old and old.nodes or {}) do count = count - 1 end
    same = old ~= nil and same and count == 0
    char.flights[m] = { nodes = set, b = S.build, t = Now() }
    for i = 1, cur and n or 0 do
        local h, to, ids, whole = ns.Env.TaxiHops(nodes[i].slot, hops), slots[nodes[i].slot], {}, true
        for j = 1, h > 0 and h + 1 or 0 do ids[j], whole = slots[hops[j]] or 0, whole and slots[hops[j]] ~= nil end
        local s = table.concat(ids, " ")
        if whole and h > 0 and to and nodes[i].state == "reachable" and ids[1] == cur and ids[h + 1] == to
            and row[to] ~= s then
            row[to] = Changed("flights") and s
        end
    end
    if cur then char.chains[cur] = row end
    if not same then Changed("flights") end
    return m, not same
end
-- The flight under way: { from, t, loads, to } or false; read only (5.5.13).
function M.Flight() return flight end
function M.Ride() return ride.start and ride end
-- The realm's one timetable of vessel v as it may be shown at now (5.2.1, Clock.View, into out when given): false
-- with none, none usable, or one whose estimated departure a wait saw pass this session.
function M.Timetable(v, now, out)
    local tt = not missed[(S.net.Vessel(v))] and S.realm.phases[(S.net.Vessel(v))]
    return tt and ns.Clock.View(tt, now, S.build, select(6, S.net.Service(v)), out) or false
end
-- Whether path's timetable is set aside for the session; set: a wait saw its estimated departure pass (5.5.11 P5).
function M.Missed(path, set) if set and not missed[path] then missed[path] = Changed("vessels") end return missed[path] == true end
local function Fin(v) return type(v) == "number" and v == v and v > -huge and v < huge end
-- A saved timetable tt of path p, whether it is kept (Ledger's validation). One an older version saved with the zone
-- copies it was learned on (at) and other copies' timetables (alt) becomes one: its phase, seen, count and build the
-- latest seen's, its period and sigma the surest valid one's. A timetable the rides never refined takes the shipped
-- period and starting sigma (Clock.Start) of vessel v when they changed.
function M.One(phases, p, tt, v)
    local C, all, last, sure = ns.Clock, { tt }, nil, nil
    for _, a in ipairs(type(tt) == "table" and type(tt.alt) == "table" and tt.alt or {}) do all[#all + 1] = a end
    for _, a in ipairs(all) do
        local ok = C.Valid(a) and a.phase
        last = ok and (not last or a.seen > last.seen) and a or last
        sure = ok and (not sure or a.sigma < sure.sigma) and a or sure
    end
    if not last then return C.Valid(tt) and not tt.alt and tt.phase == false end
    tt = #all > 1 and { period = sure.period, sigma = sure.sigma, phase = last.phase, seen = last.seen, count = sure.count,
        build = last.build } or tt
    tt.at, tt.alt, phases[p] = nil, nil, tt
    local shipped, prior = v and select(3, ns.Net.Service(v)), v and select(6, ns.Net.Service(v)) or nil
    local s, P = tt.sigma, tt.period
    if shipped and (tt.count <= 1 or abs(s - C.SIGMA_TABLE * P) <= 1e-9 * P or abs(s - C.Start(P, prior)) <= 1e-9 * P) then
        tt.period, tt.sigma = shipped, C.Start(shipped, prior)
    end
    if v and tt.wide and not (prior and prior.period == tt.wide) then tt.wide, tt.strikes = nil, nil end
    return C.Valid(tt)
end
-- A saved account.clock list (Ledger's validation): at most six observations, each { t, laps, miss, r, x }.
local RESULT = { first = true, refined = true, anchored = true, reset = true }
function M.Record(list)
    local n = 0
    for k, o in pairs(type(list) == "table" and list or {}) do
        n = n + 1
        if not (type(k) == "number" and k >= 1 and k <= 6 and k % 1 == 0 and type(o) == "table" and Fin(o.t) and Fin(o.laps)
            and o.laps >= 0 and o.laps % 1 == 0 and Fin(o.miss) and RESULT[o.r] and (o.x == nil or o.x == true)) then return false end
    end
    return type(list) == "table" and n == #list
end

-- Where the hearthstone lands until learned: the inn point of the bind place, else the town point named so.
function M.BindGuess(name)
    local E, net = ns.Env, S.net
    for k = 1, net.BindCount or 0 do
        local area, m, x, y = net.BindPoint(k)
        if E.AreaName(area) == name then return m, x, y end
    end
    for k = 1, net.PlaceCount or 0 do
        local area, m, x, y = net.Place(k)
        if area ~= 0 and E.AreaName(area) == name then return m, x, y end
    end
    for i = 1, net.S or 0 do -- a flight master in the bind's area: Orgrimmar, Brackenwall, the new towns
        local kind, m, x, y, _, _, _, area = net.Stop(i)
        if kind == 1 and area ~= 0 and E.AreaName(area) == name then return m, x, y end
    end
    for k = 1, net.PlaceCount or 0 do
        local area, m, x, y, _, english = net.Place(k)
        if area == 0 and english == name then return m, x, y end
    end
end
