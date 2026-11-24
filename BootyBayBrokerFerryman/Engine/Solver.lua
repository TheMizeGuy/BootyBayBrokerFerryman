local ADDON, ns = ...

local M = {}
ns.Solver = M

M.GRAIN, M.CAP, M.SPELL_MIN_SAVE, M.RERUN = 64, 400000, 30, 1.25
M.WHATIF_CAP, M.UNREAD_MIN, M.CAL_MS, M.pops = 4000, 60, 5.5, 0
M.POPS, M.PROBE = 32, 2     -- pops between two pauses of a run in a job; grains of the goal's search run first (4.6.2)

local huge, max, min, sqrt = math.huge, math.max, math.min, math.sqrt
-- Label 2p - 1 is place p reached by a ride or a cast, label 2p is p reached by a walk or, for a flight on, a cast.
local lab, from, via, fly = {}, {}, {}, {}
-- The places a walk can still improve, per landmass: one leaves when a label is settled, a flight's (late) with its walk's or X after its ride's.
local open, slot, late = {}, {}, {}
local size, heap, work, cap, root, Arrive, Make = 0, false, 0, 0, 0
-- The walks of the two temporary places, and the same without risk ground for the safer what-if.
local walks = { start = {}, startOk = {}, goal = {}, goalOk = {}, direct = false, directOk = false }
local safe = { start = {}, goal = {}, risky = {}, direct = false }
local ban = { casts = {}, flightsAlt = false }
-- No search reports a landing's walk to the goal: Ground.Route proves it and its measure is kept here.
local tail = { real = {}, land = {}, inside = {}, swim = {}, risk = {}, f = {} }
local function Route() return { n = 0, place = {}, link = {}, pad = {}, proven = false, saves = false, tail = tail } end
local routeA, routeB, routeN = Route(), Route(), Route()
local lineS, lineG, lineD, spot, labels, estimates = {}, {}, 0, {}, {}, {}
local scratch, cal = { n = 0, x = {}, y = {}, z = {}, far = {} }, { 3, 1, 4, 1, 5, 9, 2, 6 }
local ground, G, req, pause, emit, fwd, bwd
local endF, endB, told, shown, best = false, false, false, false, false   -- of the running job
-- a search is made when first needed; apart: no direct grid walk is tried; anchorB: the first anchor the goal's reached
local madeF, madeB, apart, anchorB, probed, noDirect = false, false, false, false, false, false
M.walks, M.ban = walks, ban

-- Whether the way to label x has been at label y: a ride back to a place the way walked into is not taken (4.6.1).
local function Been(x, y, sid) while x ~= sid and x ~= y do x = from[x] end return x == y end
local function Shut(O, p, at) local last = O[O.n]; O[at], slot[last], O.n = last, at, O.n - 1; slot[p] = 0 end
-- Lowers a label; one at or past the best arrival known is kept but never queued.
local function Reach(id, a, f, k, bound)
    if a < lab[id] and not (k < 0 and lab[id + 1] < a and Been(f, id + 1, root)) then
        lab[id], from[id], via[id] = a, f, k
        if a < bound then ns.Heap.Push(heap, id, a) end
    end
end

-- One time-dependent Dijkstra on the padded clock (4.6.1). With a route: the arrival at the goal, or false
-- when there is no way. Without: every label, then false. nil when the work limit stopped it.
local function Search(G, now, walks, ban, route, pause)
    if G.n > size then heap, size = ns.Heap.New(2 * G.n), G.n end
    local W, S, h, Push, Pop = G.W, G.START, heap, ns.Heap.Push, ns.Heap.Pop
    local first, to, kind, tt, wait, sec = G.first, G.to, G.kind, G.tt, G.wait, G.sec
    local pad, risky, mass, toGoal, X, lnd = G.pad, walks.risky, G.mass, walks.goal, G.change == false and -1 or G.change or 0, G.landed
    local alt = ban.flightsAlt and G.alt
    local goal, sid = route and 2 * G.GOAL - 1 or 0, 2 * S - 1
    root = sid
    local bound = route and walks.direct and now + walks.direct or huge
    if pause then pause() end; ns.Heap.Clear(h)
    for id = 1, 2 * G.n do lab[id], slot[id] = huge, 0 end
    for p = 1, X ~= 0 and G.n or 0 do     -- the places a flight leaves: a place's flights are its first links (4.4.3)
        fly[p] = first[p] < first[p + 1] and kind[first[p]] == 1 or alt and alt.first[p] < alt.first[p + 1]
    end
    if pause then pause() end
    for _, O in pairs(open) do O.n = 0 end
    for m, L in pairs(G.list) do
        local O = open[m] or {}
        open[m], O.n = O, L.n
        for i = 1, L.n do O[i], slot[L[i]] = L[i], i end
    end
    for p = 1, W do
        if walks.start[p] and not (p == lnd and X < 0) then Reach(2 * p, now + walks.start[p] + (p == lnd and max(X, 0) or 0), sid, 0, huge) end
    end
    if bound < huge then Reach(goal, bound, sid, 0, huge) end
    for k = first[S], first[S + 1] - 1 do     -- a cast lands as a ride does and, for a flight on, as a walk does
        for id = 2 * to[k] - 1, ban.casts[G.ref[k]] and 0 or 2 * to[k] do Reach(id, now + wait[k] + sec[k], sid, k, huge) end
    end
    local chunk = min(M.POPS, cap - work)
    local left, found, nLate, hLate = chunk, nil, 0, 0
    while left > 0 do
        local id, t = Pop(h)
        if not id or id == goal then found = id and t or false break end
        left = left - 1
        local odd = id % 2
        local p, twin = (id + odd) / 2, id + 2 * odd - 1
        local O, at = open[mass[p]], slot[p]
        local x = X ~= 0 and fly[p] and X or 0     -- what a flight from the ride's label costs more; -1: none leaves it (4.6.1)
        if at > 0 and (odd == 0 or x == 0) then Shut(O, p, at) elseif at > 0 and x > 0 then nLate = nLate + 1; late[nLate] = p end
        while hLate < nLate and lab[2 * late[hLate + 1] - 1] + X <= t do     -- no walk that leaves X after the ride's label is queued
            hLate = hLate + 1; local q = late[hLate]; if slot[q] > 0 then Shut(open[mass[q]], q, slot[q]) end
        end
        -- The twin label, when it left no later (for a flight, the ride's + x), has already taken every ride from here.
        local rides = lab[twin] > t or odd == 1 and lab[twin] == t
        local flies = odd == 1 and x >= 0 and lab[twin] >= t + x or odd == 0 and (x < 0 or lab[twin] + x > t)
        if rides or flies then
            for k = first[p], first[p + 1] - 1 do
                local f = kind[k] == 1
                if f and flies and not alt or rides and not f then
                    local a, q = tt[k] and Arrive(G, k, t) or t + wait[k] + sec[k] + (f and odd * x or 0), 2 * to[k] - 1
                    if a < lab[q] and not (lab[q + 1] < a and Been(id, q + 1, sid)) then
                        lab[q], from[q], via[q] = a, id, k
                        if a < bound then Push(h, q, a) end
                    end
                end
            end
            for k = alt and flies and alt.first[p] or 1, alt and flies and alt.first[p] and alt.first[p + 1] - 1 or 0 do
                Reach(2 * alt.to[k] - 1, t + odd * x + alt.wait[k] + alt.sec[k], id, -k, bound)
            end
        end
        -- Among walks picked for crossing no risk ground the best is not known: there a walk follows a walk.
        if risky then odd = 1 end
        if odd == 1 and O then
            local base = (p - 1) * W
            for i = 1, O.n do
                local q = O[i]
                local w = q ~= lnd and pad[base + q] or X >= 0 and pad[base + q] and pad[base + q] + X     -- the change of 4.6.1
                if w and not (risky and risky[base + q]) then
                    local a = t + w
                    q = q + q
                    -- A walk that lands no earlier than a ride did is noted, not queued, unless a flight leaves and it lands within X of the ride (ever, for -1).
                    if a < lab[q] then
                        lab[q] = a
                        if (a < lab[q - 1] or fly[q / 2] and (X < 0 or a < lab[q - 1] + X)) and a < bound then
                            from[q], via[q] = id, 0
                            Push(h, q, a)
                        end
                    end
                end
            end
        end
        if odd == 1 and goal > 0 and toGoal[p] and t + toGoal[p] < bound then
            bound = t + toGoal[p]
            Reach(goal, bound, id, 0, huge)
        end
        if left == 0 then
            work, M.pops = work + chunk, M.pops + chunk
            if pause then pause() end
            chunk = min(M.POPS, cap - work)
            left = chunk
        end
    end
    work, M.pops = work + chunk - left, M.pops + chunk - left
    if not found then return found end
    local n, x = 0, goal
    while x ~= sid and n <= 2 * size do n, x = n + 1, from[x] end
    if x ~= sid then return nil end
    local place, link, rpad = route.place, route.link, route.pad
    route.n, route.proven, route.saves, x = n, false, false, goal
    for i = n, 1, -1 do
        place[i], link[i], rpad[i] = (x + x % 2) / 2, via[x], lab[x]
        x = from[x]
    end
    place[0], rpad[0] = S, now
    return found
end
function M.Run(G, now, walks, ban, route)
    Arrive, work, cap = ns.Net.Arrive, 0, M.CAP
    return Search(G, now, walks, ban, route) or false
end
function M.Labels(G, now, walks, ban, out)
    Arrive, work, cap = ns.Net.Arrive, 0, M.CAP
    Search(G, now, walks, ban)
    for p = 1, G.W do out[p] = min(lab[2 * p - 1], lab[2 * p]) end
end
local function Line(ax, ay, bx, by, v) return sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by)) / v end
-- Offers the walks of the two temporary places at their straight-line bounds (4.6.2 steps 1 and 2).
local function Offer(request, G)
    local cost, st, gl = request.cost, request.start, request.goal
    local v = max(cost.vLand, cost.vSwim)
    local ws, wsOk, wg, wgOk = walks.start, walks.startOk, walks.goal, walks.goalOk
    for p = 1, G.W do ws[p], wsOk[p], wg[p], wgOk[p], tail.real[p] = false, false, false, false, nil end
    walks.direct, walks.directOk, lineD = false, false, false
    local L = st.n > 0 and ground.Has(st.landmass) and G.list[st.landmass]
    for i = 1, L and L.n or 0 do
        local p = L[i]
        if p <= G.A then lineS[p] = Line(G.x[p], G.y[p], st.x, st.y, v); ws[p] = lineS[p] end
    end
    if st.n == 0 and st.anchor > 0 then ws[st.anchor], wsOk[st.anchor] = 0, true end
    if not gl then return end
    for p = 1, gl.n > 0 and ground.Has(gl.landmass) and G.W or 0 do
        if G.alight[p] and G.mass[p] == gl.landmass then
            lineG[p] = Line(G.x[p], G.y[p], gl.x, gl.y, v); wg[p] = lineG[p]
        end
    end
    if gl.n == 0 and gl.anchor > 0 then wg[gl.anchor], wgOk[gl.anchor] = 0, true end
    if st.landmass ~= gl.landmass then return end
    if st.n > 0 and gl.n > 0 then
        lineD = Line(gl.x, gl.y, st.x, st.y, v); walks.direct = lineD
    elseif st.n + gl.n == 0 and st.anchor > 0 and st.anchor == gl.anchor then
        walks.direct, walks.directOk = 0, true
    end
end
-- A walk not reached costs the larger of its straight line and the frontier; none once its search has ended.
local function Reprice()
    local ws, wsOk, wg, wgOk, cut = walks.start, walks.startOk, walks.goal, walks.goalOk, walks.directOk and req.cost.remount or 0
    local f = not madeF and 0 or fwd ~= nil and not endF and ground.Frontier(fwd)
    local b = not madeB and 0 or bwd ~= nil and not endB and ground.Frontier(bwd)
    if walks.direct and not walks.directOk then walks.direct = f and not noDirect and max(lineD, f) end
    for p = 1, G.A do
        if ws[p] and not wsOk[p] then ws[p] = f and max(lineS[p], f) end
        if wg[p] and not wgOk[p] then wg[p] = b and max(lineG[p], b) end
        -- From a stop the start's search reached, the goal is no nearer than what the direct walk has left, less its remount.
        if lineD and wsOk[p] and wg[p] and not wgOk[p] then wg[p] = walks.direct and max(wg[p], walks.direct - ws[p] - cut) end
    end
end

-- Advances one search by a grain and prices what it reached: false at the work limit, else true, more left.
local function Step(s, ws, ok)
    local units = min(M.GRAIN, cap - work)
    if units <= 0 then return false end
    work = work + units
    local more = ground.Advance(s, units)
    for i = 1, s.hits do
        local id = s.hit[i]
        local padded, _, land, _, swim = ground.Reached(s, id); padded = padded + ns.Trip.Remount(req.cost, swim, land)
        if s == bwd then anchorB = anchorB or id end
        if id == 0 then
            walks.direct, walks.directOk = padded, true
        elseif ws[id] then
            ws[id], ok[id] = padded, true
        end
    end
    s.hits = 0
    -- the goal's, exhausted with no anchor reached nor a node a join from the start reaches: where no direct grid
    -- walk is tried, nothing joins the two
    local st = req.start
    if not more and s == fwd then endF = true elseif not more then
        endB, noDirect = true, apart and not anchorB and st.n > 0 and st.landmass == req.goal.landmass
            and not ground.Touches(s, st.n, st)
    end
    pause()
    return true, more
end
-- one walk from every piece of the landing's spot to every piece of the goal: the least over them (guarantee 4)
local function Tail(p)
    local gl, m, x, y, least = req.goal, G.mass[p], G.x[p], G.y[p], false
    local before, t = ground.settled, tail
    spot.n = ground.Locate(m, x, y, nil, nil, nil, nil, nil, pause)
    for i = 1, spot.n do spot[i] = ground.found[i] end
    if spot.n > 0 and gl.n > 0 then
        least, t.real[p], t.land[p], t.inside[p], t.swim[p], t.risk[p], t.f[p] =
            ground.Route(m, x, y, spot, gl.x, gl.y, gl, req.cost, scratch, pause)
    end
    work = work + ground.settled - before
    walks.goal[p], walks.goalOk[p] = least and least + ns.Trip.Remount(req.cost, t.swim[p], t.land[p]) or false, least and true
    pause()
end
-- Whether the winner's first and last walks are still bounds.
local function Open(route)
    local n, place = route.n, route.place
    if n == 1 then return not walks.directOk, false end
    return route.link[1] == 0 and not walks.startOk[place[1]], route.link[n] == 0 and not walks.goalOk[place[n - 1]]
end
local function Grew(s, was) local f = ground.Frontier(s) return f >= was * M.RERUN and f >= was + 5 end
-- 4.6.2 step 4: where no direct grid walk is tried the goal's search runs a little first: an island's ends at once.
local function Probe()
    local st, gl = req.start, req.goal
    if probed or gl.n == 0 or not ground.Has(gl.landmass) then probed = true return false end
    probed, apart = true, st.landmass ~= gl.landmass or ground.Apart(gl.landmass, st.x, st.y, gl.x, gl.y)
    for _ = 1, apart and M.PROBE or 0 do
        local go, more = Step(Make(-1), walks.goal, walks.goalOk)
        if not (go and more) then break end
    end
    return apart
end
-- 4.6.2 steps 3 to 5: runs and searches until the winner is made of reached walks. Returns its padded
-- arrival, false when there is no way, nil at the work limit.
local function Prove(route, quiet)
    while true do
        Reprice()
        local arr = Search(G, req.now, walks, ban, route, pause)
        pause()
        if not arr then return arr end
        if not told then emit("estimate", arr - req.now) end
        best, told = arr, true
        local needF, needB = Open(route)
        if not (needF or needB) then
            route.proven = true
            return arr
        end
        if not Probe() then
            -- Nothing is shown that a cast could replace (the offered Hearthstone is never planned), nor a last walk
            -- that is still a bound from a stop no shipped walk joins to an anchor the goal's search has reached:
            -- that stop may stand on other ground.
            local q, k = route.place[route.n - 1], G.first[G.START]
            local far = needB and not (q <= G.A and anchorB and ground.Pair(G.mass[q], q, anchorB, req.cost))
            if not (quiet or shown or needF or far) and route.link[1] == 0
                and G.first[G.START + 1] - k <= (G.ref[k] == req.offer and 1 or 0) then
                shown = true
                emit("first", ns.Trip.FromRoute(req, G, route, fwd, bwd, ground))
                pause()
            end
            if needB and q > G.A then
                Tail(q)
            else
                local f0, b0 = needF and ground.Frontier(Make(1)), needB and ground.Frontier(Make(-1))
                local go, f, b, had = true, needF, needB, anchorB
                while go and f == needF and b == needB do
                    if needF then go = Step(fwd, walks.start, walks.startOk) end
                    if go and needB then go = Step(bwd, walks.goal, walks.goalOk) end
                    f, b = Open(route)
                    if needF and (endF or Grew(fwd, f0)) or needB and (endB or Grew(bwd, b0) or anchorB ~= had) then break end
                end
                if not go then return nil end
            end
        end
    end
end

-- The unread what-if (4.6.2 step 8): the plan as if every faction-legal flight point were learned.
local function Unread(arr, route)
    local st, gl, unread, alt, saves, stop, walk, least = req.start, req.goal, req.know.unread, G.alt, 0, 0, 0, huge
    if alt then
        local full = cap
        ban.flightsAlt, cap, best = true, min(cap, work + M.WHATIF_CAP), false
        local other = Prove(route, true)
        if other == nil then other = best end
        ban.flightsAlt, cap = false, full
        if other and arr - other >= M.UNREAD_MIN then saves = arr - other end
    end
    for p = 1, alt and fwd and G.A or 0 do
        if G.mass[p] == st.landmass and (alt.first[p + 1] or 0) > (alt.first[p] or 0) then
            local padded, real, land, _, swim = ground.Reached(fwd, p)
            local r = padded and ns.Trip.Remount(req.cost, swim, land)
            if padded and padded + r < least then stop, walk, least = p, real + r, padded + r end
        end
    end
    if unread[st.landmass] then emit("unread", { landmass = st.landmass, saves = saves, stop = stop, walk = walk }) end
    if gl.landmass ~= st.landmass and unread[gl.landmass] then
        emit("unread", { landmass = gl.landmass, saves = saves, stop = 0, walk = 0 })
    end
end
local function Risk(s, p) return s and select(6, ground.Reached(s, p)) or 0 end
-- The safer what-if: the best plan over the walks known now that cross no risk ground.
local function Safer(route)
    local W, A, S, cost = G.W, G.A, G.START, req.cost
    for p = 1, W do
        safe.start[p] = walks.startOk[p] and Risk(fwd, p) == 0 and walks.start[p]
        safe.goal[p] = walks.goalOk[p] and (p > A and tail.risk[p] or Risk(p <= A and bwd, p)) == 0 and walks.goal[p]
        if p % 32 == 0 then pause() end
    end
    safe.direct = walks.directOk and Risk(fwd, 0) == 0 and walks.direct
    local priced, seen = 0, 0
    for at in pairs(safe.risky) do safe.risky[at] = nil end
    for p = 1, W do
        local L, rows = G.alight[p] and G.list[G.mass[p]], p > A and G.landing[p - A].rows
        for i = 1, L and L.n or 0 do
            local at = (p - 1) * W + L[i]
            seen = seen + 1
            if seen % 256 == 0 then pause() end
            if G.pad[at] then
                local risk = rows and rows[4 * L[i]] or 1
                if p <= A then risk = select(4, ground.Pair(G.mass[p], p, L[i], cost)) end
                if risk ~= 0 then safe.risky[at] = true end
                priced = priced + 1
                if priced % 64 == 0 then work = work + 1; pause() end
            end
        end
    end
    local arr = Search(G, req.now, safe, ban, route, pause)
    -- both on the real clock from req's moment (trip.arrive has a cast first made in the water): no change is charged
    if arr then emit("safer", ns.Trip.Arrival(req, G, route, fwd, bwd, ground) - ns.Trip.Arrival(req, G, routeA, fwd, bwd, ground)) end
end
local function Setup(request, pauseFn, emitFn, again)     -- again: the job turns to another request (step 5a)
    local net = request.net or ns.Net
    ground, req, pause, emit = request.ground or ns.Ground, request, pauseFn, emitFn
    Arrive, work, cap = net.Arrive, 0, M.CAP
    G = net.Graph(request, pause)
    Offer(request, G)
    for i in pairs(ban.casts) do ban.casts[i] = nil end; if request.offer then ban.casts[request.offer] = true end
    ban.flightsAlt, endF, endB, told, shown = false, false, false, again and told, again and shown
    madeF, madeB, apart, anchorB, probed, noDirect = false, false, false, false, false, false
end
-- The search of one end, made the first time it is needed: every region the end may stand on is a source; the
-- start's has the goal as its point when the two share a landmass.
function Make(direction)
    local f, gl = direction == 1, req.goal
    if f and madeF or not f and madeB then return f and fwd or bwd end
    local at = f and req.start or gl
    if f then madeF = true else madeB = true end
    if at.n == 0 or not ground.Has(at.landmass) then return nil end
    local s = ground.Acquire(pause) or error("Ferryman: no-free-search")
    if f then fwd = s else bwd = s end     -- Abandon releases it from here on
    ground.Begin(s, at.landmass, direction, req.cost)
    for i = 1, at.n do ground.AddSource(s, at[i], at.x, at.y) end
    if f and gl.n > 0 and gl.landmass == at.landmass then ground.SetPoint(s, gl.n, gl, gl.x, gl.y) end
    s.hits = 0
    return s
end
function M.Plan(request, pauseFn, emitFn)
    -- 4.6.2 step 1: a start on no ground (a swimmer at sea) has no walk: the plan is made from its shore
    local at = request.start
    request = at.n == 0 and at.anchor == 0 and ns.Trip.Shore(request, request.ground or ns.Ground, pauseFn, true) or request
    Setup(request, pauseFn, emitFn)
    local casts, A, B, N, st, gl, none = request.casts, routeA, routeB, routeN, request.start, request.goal, false
    -- 4.6.2 step 5a: where no stop's walk leads to the goal's ground, or to the start's, the plan ends, or begins,
    -- at the nearest ground one reaches; first a start with no walk from its pieces in question takes all (16.7).
    local arr = not (ground.Cut(gl.landmass, gl.n, gl, pause)
        and not (st.landmass == gl.landmass and select(2, ground.Cut(st.landmass, st.n, st, pause)))) and Prove(A)
    for side = 0, 2 do
        local to = arr == false and (side < 2 or endF) and ns.Trip.Shore(request, ground, pause, side == 2, side == 0)
        if to then
            M.Abandon()
            request = to
            Setup(to, pauseFn, emitFn, true)
            arr = Prove(A)
        end
    end
    -- 4.6.2 step 6: a first move that is a link is a cast; it stays only when it saves enough against the proven
    -- plan with every cast banned. One that does not is banned (its class falls with it) and the next best is proven.
    if arr and A.link[1] ~= 0 then
        for i = 1, #casts do ban.casts[i] = true end
        none = Prove(N, true) or false   -- cut off by the cap: the proven cast stands, with no saving shown
        for i = 1, #casts do ban.casts[i] = i == request.offer or nil end
    end
    while arr and A.link[1] ~= 0 do
        local hearth = casts[G.ref[A.link[1]]].kind == "hearth"
        if not none or none - arr >= (hearth and request.hearthMinSave or request.spellMinSave) then break end
        ban.casts[G.ref[A.link[1]]] = true
        arr = Prove(A, true)
    end
    if arr then
        local trip = ns.Trip.FromRoute(request, G, A, fwd, bwd, ground)
        if A.link[1] ~= 0 and none then
            -- the shown saving is on the real clock (DESIGN "Caution"); the choice above is on the padded one
            local real = ns.Trip.Arrival(request, G, N, fwd, bwd, ground) - trip.arrive
            A.saves, trip.saves = none - arr, real > 0 and real
        end
        emit("done", trip)
        if request.whatIf then Unread(arr, B) end
        if trip.riskSeconds > 0 then Safer(B) end
        ban.casts[request.offer or 0] = nil     -- 5.5.10 G14: a followed trip's Hearthstone, offered, never planned
        local with = request.offer and Prove(B, true)
        local real = with and arr - with >= request.hearthMinSave and ns.Trip.Arrival(request, G, B, fwd, bwd, ground)
        if real and real - request.now < trip.arrive - trip.planned then emit("hearth", real - request.now) end
    else
        emit("none", arr == nil and "cap" or st.n == 0 and st.anchor == 0 and "lost" or "noWay")     -- lost: no shore (step 1)
    end
    M.Abandon()
end
function M.Abandon()
    if fwd then ground.Release(fwd) end; if bwd then ground.Release(bwd) end; fwd, bwd = nil, nil
end
function M.Estimate(request, pauseFn, emitFn)
    Setup(request, pauseFn, emitFn)
    Search(G, request.now, walks, ban, nil, pause)
    for p = 1, G.W do labels[p] = min(lab[2 * p - 1], lab[2 * p]) end
    emit("estimates", ns.Trip.Estimates(request, G, labels, estimates, pause))
end
function M.Calibrate()
    local byte, s, x = string.byte, "abcdefghijklmnopqrstuvwxyz01234567", 0
    for i = 1, 200000 do x = (x + byte(s, i % 34 + 1) * cal[i % 8 + 1]) % 65536 end
end
