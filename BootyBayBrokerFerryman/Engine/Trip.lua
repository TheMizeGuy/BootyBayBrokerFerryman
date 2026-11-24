local ADDON, ns = ...

local M = {}
ns.Trip = M

M.PASS = 12
M.LOOK = 16
M.BEND_AHEAD = 8
M.TURN = 0.7
M.END = 2
M.WINDOW = 3

local sqrt, min, max, huge = math.sqrt, math.min, math.max, math.huge
local RIDE = { "flight", "boat", "tram", "lift", "portal" }

function M.Remount(cost, swim, land) return swim > 0 and max(0, min(cost.remount or 0, land * (1 / cost.vInside - 1 / cost.vLand))) or 0 end
-- A walk's seconds at cost; f: the scale Ground.Reached put its yards up to their line by, whose time is the walk's
-- own and at least the line's at the faster of land and swim (guarantee 10); then a rider's remount (3.1)
local function Walked(cost, land, inside, swim, risk, f)
    local real, r = ns.Ground.Price(cost, land, inside, swim, risk), M.Remount(cost, swim, land)
    return (f and f > 1 and max(real / f, (land + inside + swim) / max(cost.vLand, cost.vSwim)) or real) + r
end

local function Leg(kind, from, to, t)
    return {
        kind = kind, from = from, to = to, depart = t, arrive = t, wait = 0, seconds = 0, est = false, tag = false,
        ref = 0, item = 0, hops = false, vessel = 0, call = 0, tt = false, u = 0, off = 0,
        land = 0, inside = 0, swim = 0, risk = 0, trail = false, i = 1, toName = "", begun = false,
    }
end

local function Place(request, G, net, p)
    local at = p == G.START and request.start or p == G.GOAL and request.goal
    if at then
        -- a spot the plan itself turned to (Shore) is neither the start nor the goal: a place of its own; ends: the
        -- regions the plan took there (the spot's one, every candidate when it widened), which the trace takes
        local kind = at.tx and "anchor" or p == G.START and "start" or "goal"
        return { kind = kind, anchor = at.anchor, landmass = at.landmass, x = at.x, y = at.y, ends = at }
    end
    local kind = p <= net.S and "stop" or p <= G.A and "anchor" or "landing"
    return { kind = kind, anchor = p <= G.A and p or 0, landmass = G.mass[p], x = G.x[p], y = G.y[p] }
end

-- Where the ground ends short of an end of the trip (Shore): the swim between the spot and that end (p: G.START or
-- G.GOAL), one straight line, an estimate.
local function Swim(request, G, net, p, t)
    local at, spot = p == G.START and request.start or request.goal, Place(request, G, net, p)
    local far = { kind = p == G.START and "start" or "goal", anchor = 0, landmass = at.landmass, x = at.tx, y = at.ty }
    local leg = Leg("walk", p == G.START and far or spot, p == G.START and spot or far, t)
    leg.swim, leg.est, leg.seconds, leg.arrive = at.swim, true, at.swim / request.cost.vSwim, t + at.swim / request.cost.vSwim
    leg.trail = { n = 2, x = { leg.from.x, leg.to.x }, y = { leg.from.y, leg.to.y }, z = { false, false }, far = { 0, at.swim } }
    return leg
end

-- The measure of the walk of move i, or nil while it is only a bound. Also the search and target of its trail.
local function Measure(request, G, route, i, fwd, bwd, ground)
    local p, q = route.place[i - 1], route.place[i]
    local s, id, _
    if p == G.START then
        s, id = fwd, q == G.GOAL and 0 or q
    elseif q ~= G.GOAL then
        if p <= G.A then
            return ground.Pair(G.mass[p], p, q, request.cost)
        end
        local k = route.link[i - 1]
        local landing = G.kind[k] == 6 and request.casts[G.ref[k]].landing or request.know.portals[-G.ref[k]].to
        local rows = landing.rows
        return rows[4 * q - 3], rows[4 * q - 2], rows[4 * q - 1], rows[4 * q]
    elseif p > G.A then
        local tail = route.tail
        return tail.real[p] and tail.land[p], tail.inside[p], tail.swim[p], tail.risk[p], nil, nil, tail.f and tail.f[p]
    else
        s, id = bwd, p
    end
    if not s then
        -- a side with ground whose search is not made yet: a bound; one without: 0 to its anchor
        local at = p == G.START and request.start or request.goal
        if at.n > 0 and ground.Has(at.landmass) then return nil end
        return 0, 0, 0, 0
    end
    local land, inside, swim, risk, f
    _, _, land, inside, swim, risk, f = ground.Reached(s, id)
    return land, inside, swim, risk, s, id, f
end

function M.FromRoute(request, G, route, fwd, bwd, ground)
    local net, cost, t = request.net or ns.Net, request.cost, request.now
    local legs, n, riskSeconds, estimate, last = {}, 0, 0, false, false
    local st, gl = request.start, request.goal
    if st.swim and route.n > 0 and route.link[1] ~= 0 then     -- a cast first is cast in the water, before the swim
        t, st = t - st.swim / cost.vSwim, setmetatable({ x = st.tx, y = st.ty, tx = false, swim = false }, { __index = st })
        request = setmetatable({ start = st, now = t }, { __index = request })
    end
    if st.swim then
        last = Swim(request, G, net, G.START, t - st.swim / cost.vSwim)
        legs[1], n, estimate = last, 1, true
    end
    for i = 1, route.n do
        local p, q, k = route.place[i - 1], route.place[i], route.link[i]
        local leg
        if k == 0 then
            local land, inside, swim, risk, s, id, f = Measure(request, G, route, i, fwd, bwd, ground)
            leg = Leg("walk", Place(request, G, net, p), Place(request, G, net, q), t)
            if land then
                leg.land, leg.inside, leg.swim, leg.risk = land, inside, swim, risk
                leg.seconds, leg.f = Walked(cost, land, inside, swim, risk, f), f
                if s and land + inside + swim > 0 then
                    leg.trail = { n = 0, x = {}, y = {}, z = {}, far = {} }
                    ground.Trail(s, id, leg.trail)
                end
            else
                -- Not reached yet: the bound stands in, as land yards, so that Retime rescales it.
                leg.seconds, leg.est = route.pad[i] - route.pad[i - 1], true
                leg.land = leg.seconds * cost.vLand
            end
            leg.arrive = t + leg.seconds
            riskSeconds = riskSeconds + leg.risk / cost.vLand
            -- A goal that is the anchor the last ride arrived at needs no walk leg.
            if q == G.GOAL and i > 1 and request.goal.anchor == p and leg.seconds == 0 then
                leg = false
            end
        else
            local kind, ref = G.kind[k], G.ref[k]
            if kind ~= 6 and not (last and last.kind == "walk") then
                n = n + 1
                legs[n] = Leg("walk", Place(request, G, net, p), Place(request, G, net, p), t)
            end
            leg = Leg(RIDE[kind], Place(request, G, net, p), Place(request, G, net, q), t)
            leg.depart, leg.arrive, leg.est = net.Depart(G, k, t), net.Arrive(G, k, t), G.est[k]
            leg.wait, leg.seconds = leg.depart - t, leg.arrive - leg.depart
            if kind == 1 then
                leg.ref, leg.hops = select(7, net.Stop(p)), {}
                if net.Chain(G, p, q, leg.hops) == 0 then
                    leg.hops[1], leg.hops[2] = p, q
                end
            elseif kind == 2 then
                local path, air = net.Vessel(ref)
                leg.kind, leg.ref, leg.vessel, leg.call = air and "zeppelin" or "boat", path, ref, G.call[k]
                local u = G.u[k]
                if net.UAt then u = net.UAt(G, k, t) end       -- the uncertainty reached at the pier
                leg.tt, leg.u, leg.off, leg.est = u and G.tt[k] or false, u or 0, G.off[k], leg.est or not u
                if not u then leg.seconds = G.sec[k] end
                leg.tag = request.know.vessels[ref].runs == "likely" and "unconfirmed" or not leg.tt and "phase"
                    or leg.tt.tier == "about" and "estimate"
            elseif kind == 6 then
                local cast = request.casts[ref]
                leg.kind, leg.ref, leg.item = cast.kind, cast.spell, cast.item
                leg.tag = cast.landing.est and "landing" or false
            elseif kind ~= 3 then
                leg.ref = ref
            end
        end
        if leg then
            n, last, t = n + 1, leg, leg.arrive
            legs[n] = leg
            estimate = estimate or leg.est
        end
    end
    if gl.swim then
        n, estimate = n + 1, true
        legs[n] = Swim(request, G, net, G.GOAL, t)
        t = legs[n].arrive
    end
    return {
        id = 0, dest = false, landmass = st.landmass, planned = request.now - (st.swim or 0) / cost.vSwim, arrive = t,
        proven = route.proven, estimate = estimate, n = n, legs = legs, at = 1, riskSeconds = riskSeconds,
        saves = route.saves or false, moved = gl.moved or false, swim = gl.swim or false, shore = st.swim or false,
        off = 0, bendX = 0, bendY = 0, bendLast = false, ahead = 0, foot = 0,
        doubt = st.n > 1 and n > 0 and legs[1].kind == "walk",
    }
end

-- 4.6.2 step 5a: the request a plan with no way turns to, or nil. wide: the start and the goal with every candidate
-- of their looks (start.all, goal.all, 16.7) when either was planned with fewer. Else the goal becomes the nearest spot of ground a
-- stop's walk leads to, the rest swum where that spot is water, over ground or none. start: the same for a start no
-- walk leads from, only across water, and for one on no ground, to any spot: the plan begins there, after the swim.
function M.Shore(request, ground, pause, start, wide)
    local st, gl, cost = request.start, request.goal, request.cost
    local all = wide and st.n < (st.all or 0) and setmetatable({ n = st.all }, { __index = st })
    local ends = wide and gl.n < (gl.all or 0) and setmetatable({ n = gl.all }, { __index = gl })
    if wide then return (all or ends) and setmetatable({ start = all or nil, goal = ends or nil }, { __index = request }) or nil end
    local at, own = start and st or gl, not start and st.landmass == gl.landmass and st
    if not start and gl.moved then return nil end
    local piece, x, y, yards, swum = ground.Shore(at.landmass, at.x, at.y, cost, pause, own)
    if not (piece and ground.Cut(at.landmass, at.n, at, pause)) or start and not swum and at.n > 0 then return nil end
    local spot = { landmass = at.landmass, x = x, y = y, n = 1, piece, anchor = 0, kind = at.kind, ref = at.ref, moved = true,
        swim = (swum or start) and yards, tx = at.x, ty = at.y }
    return setmetatable(start and { start = spot, now = request.now + yards / cost.vSwim } or { goal = spot }, { __index = request })
end

-- The arrival FromRoute's replay gives a route, without building its legs.
function M.Arrival(request, G, route, fwd, bwd, ground)
    local net, t = request.net or ns.Net, request.now
    for i = 1, route.n do
        local k = route.link[i]
        if k ~= 0 then
            t = net.Arrive(G, k, t)
        else
            local land, inside, swim, risk, _, _, f = Measure(request, G, route, i, fwd, bwd, ground)
            t = t + (land and Walked(request.cost, land, inside, swim, risk, f) or route.pad[i] - route.pad[i - 1])
        end
    end
    return t + (request.goal.swim or 0) / request.cost.vSwim
end

-- Solver.Estimate's figures: the least over the places of their earliest label and the line from there to each
-- point at the fastest speed (and the line from the start), in out[1..n]; false where nothing leads.
local function Line(ax, ay, bx, by, v) return sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by)) / v end
function M.Estimates(request, G, labels, out, pause)
    local st, pts, cost = request.start, request.points, request.cost
    local v = max(cost.vLand, cost.vSwim)
    for i = 1, pts.n do
        local m, x, y, least = pts.mass[i], pts.x[i], pts.y[i], huge
        if (st.n > 0 or st.anchor == 0) and m == st.landmass then least = Line(st.x, st.y, x, y, v) end
        for p = 1, G.W do
            if G.alight[p] and G.mass[p] == m and labels[p] < huge then
                least = min(least, labels[p] - request.now + Line(G.x[p], G.y[p], x, y, v))
            end
        end
        out[i] = least < huge and least
        if i % 8 == 0 then pause() end
    end
    for i = pts.n + 1, #out do out[i] = nil end
    return out
end

-- mode true: the current leg was entered this moment, so a ride's wait begins now, whatever the plan expected
-- (a start that came to nothing included); "begun": its ride began this moment, so it leaves now and its
-- departure is no longer uncertain. Wait, seconds and u stay as planned, for a wait that begins again.
function M.Retime(trip, now, x, y, cost, mode)
    local legs, at, Clock = trip.legs, trip.at, ns.Clock
    local t = now
    for i = at, trip.n do
        local leg = legs[i]
        local ahead = i > at or mode == true
        if i == at and mode and leg.kind ~= "walk" then
            leg.begun = mode == "begun"
            if leg.begun then
                leg.depart, leg.arrive = now, now + leg.seconds - leg.u
            end
        end
        if i == at and leg.begun then
            -- a ride under way keeps its times
        elseif leg.kind == "walk" then
            local real, share, wp = Walked(cost, leg.land, leg.inside, leg.swim, leg.risk, leg.f), 1, leg.trail
            if i > at then
                leg.depart = t
            elseif wp and wp.far[wp.n] > 0 then
                local j, far = min(leg.i + 1, wp.n), wp.far
                local dx, dy = wp.x[j] - x, wp.y[j] - y
                share = min(1, (sqrt(dx * dx + dy * dy) + far[wp.n] - far[j]) / far[wp.n])
            end
            leg.seconds, leg.arrive = real, t + real * share
        elseif leg.tt then
            -- A departure of the current leg stands until it is missed (Driver 5.5.6).
            if ahead or now > leg.depart + leg.u + Clock.MISS then
                leg.depart = Clock.Next(leg.tt, leg.off, t + leg.u)
                leg.wait, leg.arrive = leg.depart - t, leg.depart + leg.seconds
            end
        elseif ahead or leg.vessel > 0 then     -- an untimed vessel's wait does not count down
            leg.depart, leg.arrive = t + leg.wait, t + leg.wait + leg.seconds
        elseif now > leg.depart then
            leg.depart, leg.arrive = now, now + leg.seconds
        end
        t = leg.arrive
    end
    trip.arrive = t
end

-- Squared distance from (x, y) to the segment a-b, where along it (0 to 1) the nearest point lies, and the
-- squared yards from that point to b.
local function Away(ax, ay, bx, by, x, y)
    local dx, dy = bx - ax, by - ay
    local len = dx * dx + dy * dy
    local u = len > 0 and ((x - ax) * dx + (y - ay) * dy) / len or 1
    u = u < 0 and 0 or u > 1 and 1 or u
    dx, dy = ax + u * dx - x, ay + u * dy - y
    return dx * dx + dy * dy, u, (1 - u) * (1 - u) * len
end

-- The stretch of a trail the player's foot point is on, never one before i; how far along it (0 to 1) that point
-- lies; the squared distances to it and to the nearest stretch at hand. A stretch that begins within PASS yards
-- of way from the foot point takes over as soon as it is nearer: the way goes on there. One further on only when
-- it is PASS / 2 nearer than a stretch the player is still beside (a drop onto the switchback below): a trail that
-- passes beside, over or across itself further on is not skipped. A stretch is left for good once the foot point
-- is within END of its end, and where the way turns back there, within BEND_AHEAD and the player's own distance
-- from the way: the turn is not aimed at from nearer, and a kink of the ground's walk holds no one up.
local function Segment(px, py, far, n, i, x, y)
    local pass, at, least, u, e = M.PASS * M.PASS, i, Away(px[i], py[i], px[i + 1], py[i + 1], x, y)
    local stay, off, foot = least <= pass and u < 1, least, far[i] + (far[i + 1] - far[i]) * u + M.PASS
    local near = stay and max(0, sqrt(least) - M.PASS / 2) ^ 2 or huge
    for k = i + 1, min(i + M.WINDOW, n - 1) do
        local d, v, w = Away(px[k], py[k], px[k + 1], py[k + 1], x, y)
        off = min(off, d)
        if d < least and (d < near or far[k] <= foot) then
            at, least, u, e = k, d, v, w
        end
    end
    while at + 1 < n do
        local k = at + 1
        local back = (px[k] - px[at]) * (px[k + 1] - px[k]) + (py[k] - py[at]) * (py[k + 1] - py[k]) < 0
        local reach = back and M.BEND_AHEAD + sqrt(least) or M.END
        if e >= reach * reach then break end
        at = k
        least, u, e = Away(px[k], py[k], px[k + 1], py[k + 1], x, y)
    end
    if at > 1 then
        -- The player may walk back a stretch and still be on the trail.
        off = min(off, least, (Away(px[at - 1], py[at - 1], px[at], py[at], x, y)))
    end
    return at, u, least, off
end

function M.Advance(trip, x, y)
    local leg = trip.legs[trip.at]
    local wp = leg.trail
    if leg.kind ~= "walk" or not wp or wp.n < 2 then     -- a walk without a trail: off its straight line
        local a, b = leg.from, leg.to
        trip.off = leg.kind == "walk" and sqrt((Away(a.x, a.y, b.x, b.y, x, y))) or 0
        return 0
    end
    local px, py, far, n = wp.x, wp.y, wp.far, wp.n
    local i, u, d, off = Segment(px, py, far, n, min(leg.i, n - 1), x, y)      -- an index on the last point: its stretch
    local away = off > M.PASS * M.PASS     -- beside no stretch at hand: at the end, it was reached by a shortcut
    local changed = i ~= leg.i
    leg.i, d = i, sqrt(d)
    -- The aim: the point LOOK yards, and the player's own distance from the way, along the way from the foot
    -- point. A bend sharper than TURN is looked past only from BEND_AHEAD (and that distance) before it, and
    -- then by as much of the look as the foot point has come into that reach: beside a bend the arrow already
    -- leans round it, it cuts no corner from afar, and it never aims at a point nearer than BEND_AHEAD along
    -- the way but the end.
    local at = far[i] + (far[i + 1] - far[i]) * u
    local look, k = M.LOOK + d, i + 1
    while k < n and far[k] - at < look do
        local dot = (px[k] - px[k - 1]) * (px[k + 1] - px[k]) + (py[k] - py[k - 1]) * (py[k + 1] - py[k])
        if dot < M.TURN * (far[k] - far[k - 1]) * (far[k + 1] - far[k]) then
            local s, reach = far[k] - at, M.BEND_AHEAD + d
            look = s >= reach and s or s + (look - s) * (1 - s / reach)
        end
        k = k + 1
    end
    local aim = min(at + look, far[n])
    local len = far[k] - far[k - 1]
    local t = len > 0 and (aim - far[k - 1]) / len or 1
    local bx, by = px[k - 1] + (px[k] - px[k - 1]) * t, py[k - 1] + (py[k] - py[k - 1]) * t
    local last = aim >= far[n] or i == n - 1
    trip.off, trip.bendX, trip.bendY, trip.bendLast, trip.ahead, trip.foot = sqrt(off), bx, by, last, far[n] - aim, far[n] - at
    -- The end counts only once nothing of the trail but the end is ahead, no more than its reach of way is left, or
    -- away from the trail: a trail can pass near its own end.
    local reach = M.EndReach(trip, trip.at)
    if (last or away or trip.foot <= reach) and (px[n] - x) * (px[n] - x) + (py[n] - y) * (py[n] - y) <= reach * reach then
        return 2
    end
    return changed and 1 or 0
end

function M.SetTrail(trip, legIndex, wp)
    local leg = trip.legs[legIndex]
    leg.trail, leg.i = wp, 1
end

function M.Uses(trip, kind, ref)
    for i = trip.at, trip.n do
        local leg = trip.legs[i]
        if leg.kind == kind and (ref == 0 or leg.ref == ref) then return true end
    end
    return false
end

-- A ride from the leg at hand on: a leg that is neither a walk nor a lift.
function M.RideAhead(trip)
    for i = trip.at, trip.n do
        local kind = trip.legs[i].kind
        if kind ~= "walk" and kind ~= "lift" then return true end
    end
    return false
end

function M.EndReach(trip, legIndex)
    local nxt = trip.legs[legIndex + 1]
    local kind = nxt and nxt.kind
    return kind == "flight" and 12 or (kind == "boat" or kind == "zeppelin") and 30 or 10
end
