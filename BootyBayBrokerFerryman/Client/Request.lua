local ADDON, ns = ...

-- What a plan is asked (INTERFACES 5.5.2 and 5.5.7): where a destination is, where the player stands, the
-- request the Solver takes; and the side jobs built the same way: a landing's survey, the travel times of
-- the "Where to?" entrances, the bench.
local M = {}
ns.Request = M

M.FIGURE_AGE, M.FIGURE_YARDS, M.BENCH_PLANS, M.HISTORY_SECONDS, M.HISTORY_YARDS = 10, 100, 12, 5, 20
M.AT_STOP = 5
M.GHOST = 1.25      -- the Ghost aura's run bonus (spell 8326), for a speed the client hides

local huge = math.huge
local ALL = { true, true, true, true, true, true }
local STOPS = { true, true, true, true }
local RIDES = { "flight", "boat", "zeppelin", "tram", "portal" }     -- what a ghost cannot take
local hereM, here, hereX, hereY, hereAt = false, false, 0, 0, -huge   -- the previous look: landmass, region,
-- position, time
local wantSurvey, wantFigures, wantBench = false, false, false
local figures, figAt, figM, figX, figY = {}, -huge, false, 0, 0
local doors = { n = 0, mass = {}, x = {}, y = {}, map = {}, at = 0, m = false, fx = 0, fy = 0 }

local function Call(fn, a)
    local ok, err = pcall(fn, a)
    if not ok then geterrorhandler()(err) end
end

-- A world point as a map position, for a destination that was not given on a map.
local function OnMap(m, x, y, ref)
    local E = ns.Env
    local uiMap, mx, my = E.ZoneAt(m, x, y), nil, nil
    if uiMap then mx, my = E.WorldToMap(uiMap, m, x, y) end
    return mx and uiMap or 0, mx or 0.5, my or 0.5, m, x, y, ref
end

-- Where an entrance is (5.5.14 C3): the network's door, else one the Ledger learned; for a door the data holds no walk
-- to, where the game's way in leaves the ground a walk reaches, or false: no run to a body there (decisions 124, 126).
M.WAYIN = { [90] = { 0, -5160, 675 }, [43] = false, [48] = false, [109] = false, [230] = false }
local function Door(map)
    local w, k, door, m, x, y, _ = M.WAYIN[map], ns.Net.EntranceOfMap(map), ns.Ledger.Knowledge().doors[map]
    if w then return w[1], w[2], w[3] end
    if k then _, _, m, x, y = ns.Net.Entrance(k) end
    if not m and door then return door.landmass, door.x, door.y end
    return m, x, y
end

-- Where a destination of each kind is now: uiMap, mx, my, landmass, x, y, ref; or nil and the reason.
function M.Point(kind, ref, uiMap, mx, my)
    local E, Net, know = ns.Env, ns.Net, ns.Ledger.Knowledge()
    local m, x, y, _
    if kind == "pin" then
        uiMap, mx, my = E.Pin()
    elseif kind == "quest" then
        ref = ref ~= 0 and ref or E.Quest() or 0
        uiMap, mx, my = E.QuestPlace(ref)
        local q = not uiMap and know.quests[ref]
        if q then m, x, y = q.landmass, q.x, q.y end
    elseif kind == "entrance" then
        m, x, y = Door(ref)
    elseif kind == "party" then
        _, m, x, y = E.Party(ref)
    elseif kind == "stop" then
        if ref >= 1 and ref <= Net.S and Net.Stop(ref) == 1 then m, x, y = Net.Anchor(ref) end
    elseif kind == "corpse" then
        uiMap, mx, my = ns.Senses.Body()
        if not uiMap and ref > 0 and M.WAYIN[ref] ~= false then return M.Point("entrance", ref) end     -- a body inside: its entrance
    end
    if m then return OnMap(m, x, y, ref) end
    if kind ~= "point" and not uiMap then return nil, "E_NOPLACE" end
    if type(mx) == "number" and type(my) == "number" then m, x, y = E.MapToWorld(uiMap, mx, my) end
    if not m then return nil, "E_NOWORLD" end
    return uiMap, mx, my, m, x, y, ref
end

-- A Ground call from outside a job decodes a bounded part of what it needs (INTERFACES 16.7): nothing and
-- M.busy while the rest is still to be read, which the next call carries on.
-- M.share: while set (a tick), the units every call of that tick shares
M.busy, M.pause, M.share = false, false, false
function M.Ground(fn, a, b, c, d, e, f, g, h)
    local G = ns.Ground
    M.busy = false
    -- inside a job that reads (LOCATE's, the estimate's, the bench's) the look waits for its decoding (Locate's
    -- pause is its ninth argument, Nearest's fifth); a job dropped while it read leaves M.pause to no one else
    if M.pause and coroutine.running() then return fn(a, b, c, d, fn == G.Nearest and M.pause or e, f, g, h, M.pause) end
    if M.share and M.share <= 0 then M.busy = true; return end
    G.Bound(M.share or G.BOUND)
    local ok, r1, r2, r3, r4 = pcall(fn, a, b, c, d, e, f, g, h)
    local left = G.Bound(nil)
    if M.share then M.share = ok and left or 0 end
    M.busy = not ok and r1 == G.BUSY
    if ok then return r1, r2, r3, r4 end
    if not M.busy then error(r1, 0) end
end

-- The regions the player may stand on, in Ground.found; continuity comes from the previous look while it is
-- recent and near (INTERFACES 16.7). A look cut short (M.busy, 0 regions) leaves the previous look as it was.
function M.Regions(env)
    local G, m = ns.Ground, env.landmass
    local dx, dy = env.x - hereX, env.y - hereY
    local prev = hereM == m and not env.jump and env.now - hereAt <= M.HISTORY_SECONDS
        and dx * dx + dy * dy <= M.HISTORY_YARDS * M.HISTORY_YARDS and here or nil
    local n, _, own = M.Ground(G.Locate, m, env.x, env.y, env.uiMap or nil, env.indoors, prev, prev and hereX, prev and hereY)
    if not n then return 0, 0 end
    hereM, here, hereX, hereY, hereAt = m, n > 0 and G.found[1] or false, env.x, env.y, env.now
    return n, own
end

-- A point within M.AT_STOP yards (planar) of a stop's anchor also stands on the anchor's own piece: the look
-- cannot tell a raised roost from the floor below it, and the plan takes the least over its sources.
local function Holds(at, n, piece) for i = 1, n do if at[i] == piece then return true end end end
local function AtStop(at, n)
    local a = ns.Net.Nearest(at.landmass, at.x, at.y, STOPS, M.AT_STOP)
    local piece = a and M.Ground(ns.Ground.AnchorRegion, a)
    if not piece or Holds(at, n, piece) then return n end
    at[n + 1] = piece
    return n + 1
end

-- The start and goal LOCATE gave up on, made inside a job with its pause (Driver's read job): Start's and Goal's
-- answers, which LOCATE then takes as they are, so no read is asked for twice.
function M.Read(env, dest, pause)
    M.pause = pause
    local start, why = M.Start(env)
    local goal, gwhy = M.Goal(dest)
    M.pause = false
    return { start, why, goal, gwhy }
end

-- LOCATE: the player's position as a request's start, or nil and why it cannot be had.
function M.Away(env)     -- why no trip can start where the player is, when none can
    if env.ok and env.landmass == ns.Net.TramMap then return "tram" end      -- planned once out of it (decision 17)
    if env.instance then return "instance" end
    if not env.ok then return "lost" end
    if env.taxi and not ns.Senses.held then return "air" end
    if ns.Senses.carried then return "carried" end
end
function M.Start(env)
    local away = M.Away(env)
    if away then return nil, away end
    local G, m, x, y = ns.Ground, env.landmass, env.x, env.y
    local start, loaded = { landmass = m, x = x, y = y, n = 0, anchor = 0 }, ns.Env.LoadGround(m)
    if loaded then
        hereM = false       -- a request's start is a fresh look
        local n, own = M.Regions(env)
        -- found[1..own]: what the data cannot tell apart under the player, one piece where the raster names it;
        -- indoors on an indoors piece, the indoors ones; and a near stop's. The rest (all) only with no walk (16.7)
        local inside, k = own > 1 and env.indoors and M.Ground(G.Indoors, m, G.found[1]), 0
        if M.busy then return nil, "busy" end
        for i = 1, own do if not inside or M.Ground(G.Indoors, m, G.found[i]) then k = k + 1; start[k] = G.found[i] end end
        start.n = k > 0 and AtStop(start, k) or 0
        if M.busy then return nil, "busy" end
        start.all = start.n
        for i = 1, n do
            if not Holds(start, start.all, G.found[i]) then start.all = start.all + 1; start[start.all] = G.found[i] end
        end
    else
        start.anchor = ns.Net.Nearest(m, x, y, ALL, ns.Driver.BOARD_NEAR) or 0
    end
    -- on no ground only a swimmer or a ghost (who runs on water) with ground in reach keeps the start: it goes to the shore
    local near = start.n > 0 or start.anchor > 0 or (env.swimming or env.ghost) and loaded and M.Ground(G.Nearest, m, x, y, G.FAR_SNAP)
    if not near then return nil, near == nil and M.busy and "busy" or ns.Env.GroundRefused(m) and "nodata" or "lost" end
    return start
end

-- PLAN's first step: the destination as a request's goal, or nil and why the trip fails.
function M.Goal(dest)
    local G, m, x, y = ns.Ground, dest.landmass, dest.x, dest.y
    local goal = { landmass = m, x = x, y = y, n = 0, anchor = 0, kind = dest.kind, ref = dest.ref, moved = false,
        guide = dest.source == "guide" }
    if not ns.Env.LoadGround(m) then
        goal.anchor = ns.Net.Nearest(m, x, y, ALL, ns.Driver.GOAL_ANCHOR) or 0
        if goal.anchor == 0 then return nil, "noGround" end
        return goal
    end
    local n, _, own, sure = M.Ground(G.Locate, m, x, y, dest.uiMap ~= 0 and dest.uiMap or nil)
    if M.busy then return nil, "busy" end
    if n == 0 then
        local region = M.Ground(G.Nearest, m, x, y, G.FAR_SNAP)
        if M.busy then return nil, "busy" end
        if not region then return nil, "tooFar" end     -- else the plan finds the nearest ground a walk reaches
    else
        -- a point with no height is every candidate of its look, the soonest reached; a stop its anchor's own piece; an
        -- entrance or a body inside an instance (its entrance) the pieces its floor names; the others (all) when no walk ends there
        local a = dest.kind == "stop" and ns.Net.Anchor(dest.ref) == m and M.Ground(G.AnchorRegion, dest.ref)
        local k = a and 1 or sure and (dest.kind == "entrance" or dest.kind == "stop" or dest.kind == "corpse" and dest.ref > 0) and own or n
        for i = 1, k do goal[i] = a or G.found[i] end
        if not (a or M.busy) then k = AtStop(goal, k) end
        if M.busy then return nil, "busy" end
        local all = k
        for i = 1, (sure or a) and n or 0 do
            if not Holds(goal, all, G.found[i]) then all = all + 1; goal[all] = G.found[i] end
        end
        n, goal.all = k, all > k and all or nil
    end
    goal.n = n
    return goal
end

-- 5.5.7: the cost, the casts usable now and the declined legs. A landing that cannot be planned through
-- yet is remembered for a survey; held: a cast with a landing was left out for the fight.
function M.Build(now, start, goal, declined, nDeclined, landed)
    local E, Net, G, L = ns.Env, ns.Net, ns.Ground, ns.Ledger
    local know, options = L.Knowledge(), L.Options()
    local _, _, faction, level = E.Character()
    local ghost = goal and goal.kind == "corpse"      -- a ghost (5.5.14) runs, on water too, unharmed: no ride, no cast
    local run = ghost and (E.now.run or Net.BASE_RUN * M.GHOST)
    local priced = not ghost and options.caution > 0 and ((G.Has(start.landmass) and G.Caps(start.landmass).risk)
        or (goal and G.Has(goal.landmass) and G.Caps(goal.landmass).risk))
    local request = { now = now, know = know, start = start, goal = goal or nil, casts = {}, avoid = {}, held = false,
        hearthMinSave = options.hearthMinSave * 60, spellMinSave = ns.Solver.SPELL_MIN_SAVE, offer = false, change = options.splitFlights and options.splitMinSave * 60, landed = start.n > 0 and landed or nil,
        whatIf = not ghost and (know.unread[start.landmass] or (goal and know.unread[goal.landmass])) == true,
        cost = { remount = run and 0 or know.remount, vLand = run or know.vLand, vInside = run or Net.BASE_RUN, vSwim = run or know.vSwim,
            factor = priced and Net.CAUTION[options.caution] or 1, faction = faction, level = level } }
    local function Unsurveyed(landing)
        if landing.anchor == 0 and not landing.rows and G.Has(landing.landmass) then
            wantSurvey = wantSurvey or landing
        end
    end
    for k = 1, ghost and 0 or Net.SpellCount do
        local spell = Net.Spell(k)
        local hearth = Net.IsBindSpell(spell.spell)
        local offer = hearth and goal and goal.guide or false      -- offered, never planned (5.5.10 G14)
        local landing = hearth and options.hearth and know.bind
            or not hearth and options.spells and know.landings[spell.spell]
        local ready, item = false, 0
        if landing then ready, item = E.CastReady(spell) end
        request.held = request.held or (landing and not (ready or offer) and (E.now.combat or ns.Lead.snap.combat)) or false
        if ready and not (offer and request.offer) then     -- one bind cast offered: a second would be planned
            request.casts[#request.casts + 1] = { kind = hearth and "hearth" or "spell", spell = spell.spell,
                item = item, seconds = spell.castSeconds, landing = landing }
            request.offer = offer and #request.casts or request.offer
            Unsurveyed(landing)
        end
    end
    for i = 1, #know.portals do Unsurveyed(know.portals[i].to) end
    for i = 1, nDeclined or 0 do request.avoid[i] = { kind = declined[i].kind, ref = declined[i].ref } end
    for i = 1, ghost and #RIDES or 0 do request.avoid[#request.avoid + 1] = { kind = RIDES[i], ref = 0 } end
    return request
end

-- The survey a landing waits for (4.6.4), as a job's argument; nil when none can be made.
function M.SurveyJob()
    local landing, G = wantSurvey, ns.Ground
    wantSurvey = false
    if not landing then return nil end
    local m, x, y = landing.landmass, landing.x, landing.y
    M.busy = false
    local n = ns.Env.LoadGround(m) and M.Ground(G.Locate, m, x, y) or 0
    if n == 0 then
        wantSurvey = M.busy and landing
        return nil
    end
    local _, _, faction, level = ns.Env.Character()
    local job = { key = landing.key, landmass = m, x = x, y = y, n = n, regions = {}, rows = {}, level = level,
        cost = { vLand = ns.Net.BASE_RUN, vInside = ns.Net.BASE_RUN, vSwim = ns.Net.BASE_SWIM, factor = 1,
            faction = faction, level = level } }
    for i = 1, n do job.regions[i] = G.found[i] end
    return job
end
function M.RunSurvey(job, pause, emit)
    ns.Ground.Survey(job.landmass, job.x, job.y, job.n, job.regions, job.cost, job.rows, pause)
    emit("rows", job)
end

-- "Where to?": every entrance with its travel time, the timed ones first. The figures are lower bounds from
-- an estimate job, shown only near where it was made, and asked for again when they are old or not from here.
local function ByTime(a, b)
    local s, t = a.seconds or huge, b.seconds or huge
    if s ~= t then return s < t end
    if a.name ~= b.name then return a.name < b.name end
    return a.map < b.map
end
function M.Entrances(out, env)
    local Net, E, know = ns.Net, ns.Env, ns.Ledger.Knowledge()
    local n = Net.EntranceCount
    local here = env.ok and env.landmass == figM and (env.x - figX) ^ 2 + (env.y - figY) ^ 2 <= M.FIGURE_YARDS ^ 2
    for k = 1, n do
        local map, _, m = Net.Entrance(k)
        local rec = out[k] or {}
        out[k], rec.map, rec.known = rec, map, (m or know.doors[map]) ~= nil
        rec.seconds, rec.name = here and figures[map] or false, E.InstanceName(map) or ""
    end
    for i = n + 1, #out do out[i] = nil end
    table.sort(out, ByTime)
    wantFigures = wantFigures or not here or env.now - figAt > M.FIGURE_AGE
    return n
end
-- The figures and where they hold are taken only when they arrive: a job a plan cancelled leaves them asked for.
local function OnFigures(what, out)
    if what ~= "estimates" then return end
    for map in pairs(figures) do figures[map] = nil end
    for i = 1, doors.n do figures[doors.map[i]] = out[i] end
    figAt, figM, figX, figY = doors.at, doors.m, doors.fx, doors.fy
    ns.Lead.Mark("notice")
end
-- the start is looked at inside the job, with its pause; "none": there is no start to estimate from
local function RunEstimate(job, pause, emit)
    M.pause = pause
    local start = M.Start(job.env)
    M.pause = false
    if not start then return emit("none") end
    local request = M.Build(job.env.now, start, nil)
    request.points = job.points
    ns.Solver.Estimate(request, pause, emit)
end
function M.Estimate(env)
    if not wantFigures then return false end
    wantFigures = false
    local Net, n = ns.Net, 0
    for k = 1, Net.EntranceCount do
        local map = Net.Entrance(k)
        local m, x, y = Door(map)
        if m then
            n = n + 1
            doors.map[n], doors.mass[n], doors.x[n], doors.y[n] = map, m, x, y
        end
    end
    doors.n, doors.at, doors.m, doors.fx, doors.fy = n, env.now, env.landmass, env.x, env.y
    return ns.Lead.Chore("estimate", RunEstimate, { env = env, points = doors }, OnFigures)
end
-- The finder's figures: the same estimates over any points ({ n, mass, x, y }); sink("estimates", out) or sink("none").
function M.Figures(env, points, sink)
    return ns.Lead.Chore("estimate", RunEstimate, { env = env, points = points }, sink)
end
-- The finder's proofs: each point of list ({ n, mass, x, y, uiMap, kind, ref }) planned in turn as a trip of the player's own
-- from here; sink(i, seconds or false): the proven trip's arrival from now, false with no way. "none": no start.
local function RunProve(job, pause, emit)
    local env, list, plans = job.env, job.list, {}
    local now = env.now
    M.pause = pause
    local start = M.Start(env)
    for i = 1, start and list.n or 0 do
        local goal = M.Goal({ landmass = list.mass[i], x = list.x[i], y = list.y[i], uiMap = list.uiMap[i],
            kind = list.kind and list.kind[i] or "point", ref = list.ref and list.ref[i] or 0 })
        plans[i] = goal and M.Build(now, start, goal) or false
    end
    M.pause = false
    if not start then return emit("none") end
    for i = 1, list.n do
        local secs = false
        if plans[i] then
            ns.Solver.Plan(plans[i], pause, function(what, trip) if what == "done" then secs = trip.arrive - now end end)
        end
        emit(i, secs)
        pause()
    end
end
function M.Prove(env, list, sink)
    return ns.Lead.Chore("prove", RunProve, { env = env, list = list }, sink, ns.Solver.Abandon)
end

-- /ferry bench: plans from here to the entrances the data places, timed as Work runs them (TESTING.md 4).
local function Rank(list, share)
    table.sort(list)
    return list[math.max(1, math.ceil(#list * share))] or 0
end
-- the start's and the entrances' looks are made inside the job, with its pause
local function RunBench(job, pause, emit)
    local Net, env, list = ns.Net, job.env, job.list
    M.pause = pause
    local start = M.Start(env)
    for k = 1, start and Net.EntranceCount or 0 do
        local map, _, m, x, y = Net.Entrance(k)
        local goal = m and #list < M.BENCH_PLANS
            and M.Goal({ landmass = m, x = x, y = y, uiMap = 0, kind = "entrance", ref = map })
        if goal then list[#list + 1] = M.Build(env.now, start, goal) end
    end
    M.pause = false
    emit("run", #list)
    if #list == 0 then return end
    local Work, firsts, dones, cpu = ns.Work, {}, {}, 0
    Work.ResetStats()
    for i = 1, #job.list do
        local s0, _, ms0 = Work.Stats()
        local first, done
        ns.Solver.Plan(job.list[i], pause, function(what)
            local s = Work.Stats() - s0 + 1
            if what == "first" then first = s elseif what == "done" or what == "none" then done = s end
        end)
        local _, _, ms = Work.Stats()
        firsts[i], dones[i], cpu = first or done or 0, done or 0, math.max(cpu, ms - ms0)
        pause()
    end
    emit("bench", { Rank(firsts, 0.95), firsts[#firsts] or 0, Rank(dones, 0.95), dones[#dones] or 0, cpu })
end
-- each landmass's walking data: the milliseconds its load took this session, or not loaded
local function Walk(m)
    local ms = ns.Env.GroundMs(m)
    return { key = ms and "BENCH_GROUND" or "BENCH_NO_GROUND", ns.Env.LandmassName(m) or m, ms }
end
local function OnBench(what, v)
    if what == "run" then
        Call(wantBench, { { key = "BENCH_RUN", v }, Walk(0), Walk(1) })
        if v == 0 then wantBench = false end
    end
    if what ~= "bench" then return end
    local E, Solver, report = ns.Env, ns.Solver, wantBench
    local _, peak = ns.Work.Stats()
    local cal = C_AddOnProfiler.MeasureCall(Solver.Calibrate)
    wantBench = false
    Call(report, {
        { key = "BENCH_PLAN", v[1], v[2], v[3], v[4], v[5] },
        { key = "BENCH_SLICE", peak, E.Metric("CountTimeOver5Ms"), E.Metric("PeakTime") },
        { key = "BENCH_LEAD", E.Metric("RecentAverageTime") },
        { key = "BENCH_RATIO", cal.elapsedMilliseconds / Solver.CAL_MS },
    })
end
function M.Bench(report) wantBench = wantBench or report end
function M.BenchJob(env)
    if not wantBench then return false end
    return ns.Lead.Chore("bench", RunBench, { env = env, list = {} }, OnBench, ns.Solver.Abandon)
end
