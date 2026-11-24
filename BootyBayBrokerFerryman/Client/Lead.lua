local ADDON, ns = ...

-- The trip on screen: the snapshot the UI draws (INTERFACES 3.10), the two ticks, the jobs (one at a time),
-- the procedures the Driver's table uses (5.5.2), trails (5.5.8) and notices (5.5.5).
local M = {}
ns.Lead = M

local sqrt, min, floor = math.sqrt, math.min, math.floor
local snap = { rev = 0, state = "idle", arrived = false, reason = false, dest = false, trip = false, leg = false,
    busy = false, estimate = false, left = 0, yards = 0, count = false, countWhat = false, waited = 0, broken = false,
    guideArrow = false, docks = { n = 0 }, notices = {}, nNotices = 0, declined = {}, nDeclined = 0, combat = false,
    options = {}, pinDriven = false, flyTo = false, flyLeft = false, flyKind = false, side = false, loop = false, arrow = false }
M.snap = snap
M.reports = { n = 0 }       -- what the plan job said about unread flight points (4.6.2 "unread")
M.safer = false             -- seconds the safest way would add, when the job said so
M.hearth = false            -- real seconds of the trip with the Hearthstone offered on a followed trip (5.5.10 G14)
M.openFlights = false       -- waiting at the flight master of a "go there first" trip
M.noShow = false            -- nothing has left for longer than the crossing's period
M.watching = false          -- the dock watch ticks in idle (5.5.12)
M.landed = false            -- the flight master the trip's own planned flight last landed at, until another ride (5.5.7)

local subs, due, publishing = {}, false, false
local spreader, cursor = false, 0
local RANK = { tick = 1, notice = 2, option = 3, leg = 4, state = 5 }
local slow, fast, Tick = false, false, false
local plan, chore, choreArg, choreSink, needs = false, false, false, false, {}
local req, base, nextId = false, {}, 0              -- the request the trip on screen was planned from
local legT, legPlan = 0, 0
local tried, detail = {}, {}
local fm, hearthFor, hearthMin = { kind = "stop", anchor = 0 }, false, false    -- hearthFor: when the trip told about the stone was given
local groundFor, unreadFor, quiet = false, false, false       -- the same for missing walking data, unread flights;
-- quiet: the trip follows RestedXP, and only the notices KEPT are put (5.5.5)
local KEPT = { N_REPLAN = true, N_UNREAD_SAVE = true, N_NEAREST_FM = true, N_NO_SHOW = true, N_AFTER_FIGHT = true,
    N_NO_GROUND = true, N_HEARTH = true }
M.wait = { landmass = false, x = 0, y = 0, at = 0 }    -- where and when the present wait began

local function Guard(fn, a, b, c)
    local ok, err = pcall(fn, a, b, c)
    if not ok then geterrorhandler()(err) end
end

---------------------------------------------------------------------------------------------------
-- Publishing: one publish per event, named after its most important change
---------------------------------------------------------------------------------------------------
local Notices
function M.Subscribe(fn) subs[#subs + 1] = fn end
function M.Mark(what)
    if not due or RANK[what] > RANK[due] then due = what end
end
-- A tick's publish is spread, one subscriber a frame, so that no frame carries the tick and every redraw
-- (DESIGN 3, "Leading"). Anything else is told to everyone at once, after the subscribers a tick still owes.
local function Spread()
    local i = cursor
    cursor = i < #subs and i + 1 or 0
    if cursor == 0 then spreader:SetScript("OnUpdate", nil) end
    Guard(subs[i], snap, "tick")
end
function M.Flush()
    if publishing then return end
    publishing = true
    while due do
        local what = due
        due = false
        while cursor > 0 do Spread() end
        snap.rev, snap.pinDriven = snap.rev + 1, ns.Pin.driving
        if what == "tick" and #subs > 0 then
            spreader = spreader or CreateFrame("Frame")
            cursor = 1
            spreader:SetScript("OnUpdate", Spread)
        else
            Guard(Notices)
            for i = 1, #subs do Guard(subs[i], snap, what) end
            snap.arrived = false
        end
    end
    publishing = false
end

---------------------------------------------------------------------------------------------------
-- Ticks (5.5.3): none in idle but the dock watch's, a slow one otherwise, a fast one while the position changes
---------------------------------------------------------------------------------------------------
local function Slow() Guard(Tick, false) end
local function Fast() Guard(Tick, true) end
function M.Wire(tick) Tick = tick end
function M.Fast(on)
    if on and slow and not fast then
        fast = C_Timer.NewTicker(ns.Driver.FAST_TICK, Fast)
    elseif not on and fast then
        fast:Cancel()
        fast = false
    end
end
-- On, or a side trail standing: the slow ticker, when none runs. Off: every ticker stops (the dock watch, 5.5.12,
-- turns it off in idle only).
function M.Watch(on)
    if (on or snap.side) and not slow then
        slow = C_Timer.NewTicker(ns.Driver.SLOW_TICK, Slow)
    elseif not (on or snap.side) then
        M.Fast(false)
        if slow then slow:Cancel() end
        slow = false
    end
    M.watching = on
end
function M.State(state, reason)
    M.Watch(state ~= "idle")
    M.watching = false
    if state ~= "idle" and state ~= "walking" then snap.docks.n = 0 end
    snap.state, snap.reason = state, reason or false
    M.Mark("state")
end

---------------------------------------------------------------------------------------------------
-- Jobs. The plan job and at most one other run at a time: they share the Solver's and the Ground's arrays,
-- so a plan cancels whatever else runs, and the rest is started again by need when nothing runs.
---------------------------------------------------------------------------------------------------
function M.Cancel()
    local Work = ns.Work
    if plan then Work.Cancel(plan) end
    if chore then Work.Cancel(chore) end
    plan, chore, snap.busy = false, false, false
end
function M.Plan(request, sink, fn)
    M.Cancel()
    plan, snap.busy = ns.Work.Start("plan", fn or ns.Solver.Plan, request, sink, not fn and ns.Solver.Abandon), true
end
function M.Planned() plan, snap.busy = false, false end
function M.Planning() return plan ~= false end
local function ChoreSink(what, value)
    if what ~= "end" and what ~= "error" then return choreSink(what, value, choreArg) end
    chore = false
    if what == "error" and choreSink == ns.Side.OnSide then ns.Side.End()      -- the side trail's, never the trip's
    elseif what == "error" and (snap.trip or snap.state == "planning") then M.Fail("error") end
    M.Chores(ns.Env.now)
    M.Flush()
end
function M.Chore(kind, fn, arg, sink, cleanup)
    choreArg, choreSink = arg, sink
    chore = ns.Work.Start(kind, fn, arg, ChoreSink, cleanup)
    return true
end
-- The chore that runs, when it was started with that sink, is cancelled and the next need asked (unless wait: the
-- caller asks once its own rows ran): the finder's way to drop its own job and nothing else.
function M.Quit(sink, wait)
    if not chore or choreSink ~= sink then return end
    ns.Work.Cancel(chore)
    chore = false
    if not wait then M.Chores(ns.Env.now) end
end
function M.Need(fn) needs[#needs + 1] = fn end
function M.Chores(env)
    if plan or chore then return end
    for i = 1, #needs do
        if needs[i](env) then return end
    end
end

---------------------------------------------------------------------------------------------------
-- Procedures (5.5.2)
---------------------------------------------------------------------------------------------------
function M.Near(env, place, yards)
    return env.ok and env.landmass == place.landmass
        and (env.x - place.x) * (env.x - place.x) + (env.y - place.y) * (env.y - place.y) <= yards * yards
end
function M.Request() return req end
-- The speeds Trip.Retime prices with: the Ledger's now, whatever the plan was made with.
local cost = { know = false, vLand = 7, vInside = 7, vSwim = 4.72, factor = 1, faction = 1, level = 1, remount = 0 }
function M.Corpse() return snap.dest and snap.dest.kind == "corpse" end    -- the run back to the body (5.5.14)
function M.Cost()
    local c, r = req and req.cost, ns.Env.now.run
    if M.Corpse() and c then c.vLand, c.vInside, c.vSwim = r or c.vLand, r or c.vLand, r or c.vLand return c end   -- a ghost's, live
    local know = ns.Ledger.Knowledge()
    if know ~= cost.know then
        cost.know, cost.vLand, cost.vSwim, cost.vInside, cost.remount = know, know.vLand, know.vSwim, ns.Net.BASE_RUN, know.remount
    end
    return cost
end
-- What the screen shows of the trip at hand: the time left and, on a walk, the yards to its end past the bend.
-- advance: find the bend first, for a walk just entered or traced, so nothing is drawn from another's.
-- What the offered Hearthstone saves now, while that is at least the minimum: the stone's trip is as long from anywhere.
local function Hearth()
    local save = M.hearth and req and snap.left - M.hearth
    return save and save >= req.hearthMinSave and save
end
function M.Figures(env, advance)
    local trip, leg = snap.trip, snap.leg
    if snap.state == "walking" and env.ok and env.landmass == leg.from.landmass then
        local x, y, ahead = leg.to.x, leg.to.y, 0
        if leg.trail then
            if advance then ns.Trip.Advance(trip, env.x, env.y) end
            x, y, ahead = trip.bendX, trip.bendY, trip.ahead
        end
        snap.yards = sqrt((x - env.x) ^ 2 + (y - env.y) ^ 2) + ahead
    end
    ns.Trip.Retime(trip, env.now, env.x, env.y, M.Cost())
    snap.left = trip.arrive - env.now
    local save = Hearth()
    save = save and floor(save / 60 + 0.5)
    if save ~= hearthMin then hearthMin = save; M.Mark("notice") end
end

function M.Drop()
    snap.trip, snap.leg, snap.broken, snap.count, snap.countWhat, snap.left, snap.yards = false, false, false, false, false, 0, 0
    snap.waited = 0
    req, M.reports.n, M.safer, M.hearth, M.openFlights, M.noShow = false, 0, false, false, false, false
    detail.trip, detail.leg, detail.wp, choreArg, ns.Driver.ashore.leg = false, false, false, false, false   -- nothing of the trip is kept
    for leg in pairs(tried) do tried[leg] = nil end
end
function M.Clear(arrived)
    local followed = snap.dest and snap.dest.source == "guide"
    M.Cancel()
    M.Drop()
    ns.Pin.End()
    if snap.dest then ns.Ledger.SaveTrip(nil) end
    snap.dest, snap.nDeclined, snap.estimate, M.landed = false, 0, false, false
    M.State("idle")
    snap.arrived = arrived and not followed
    ns.Tick.Dock(ns.Env.now)
end
function M.Fail(reason)
    M.Cancel()
    M.Drop()
    ns.Pin.End()
    if not M.Corpse() then ns.Ledger.SaveTrip(nil) end     -- a run to the body keeps the trip it set aside saved
    M.State("failed", reason)
end

-- The wait of a ride begins where the player stands, now: reached early, it may leave earlier than planned.
local function Wait(env)
    local w = M.wait
    w.landmass, w.x, w.y, w.at = env.ok and env.landmass, env.x, env.y, env.now
    snap.waited, snap.count, snap.countWhat, M.noShow = 0, false, false, false
    ns.Trip.Retime(snap.trip, env.now, env.x, env.y, M.Cost(), true)
    snap.left = snap.trip.arrive - env.now
    M.State("waiting")
end
local function Arrive(env)
    local dest = snap.dest
    if dest.kind == "stop" and dest.resume then
        M.openFlights = true
        return Wait(env)
    end
    M.Clear(true)
end
-- ENTER: a walk leads; anything else waits where the player stands. A walk that is already at its end is
-- passed at once, except the last: only arrival (5.5.6) ends a trip to a point.
function M.Enter(env)
    local trip = snap.trip
    local leg = trip.legs[trip.at]
    snap.leg, legT, legPlan = leg, env.now, leg.wait + leg.seconds
    M.Mark("leg")
    ns.Pin.Enter(leg)
    if leg.kind ~= "walk" then return Wait(env) end
    local last = trip.at == trip.n and snap.dest.kind ~= "stop"
    if not last and M.Near(env, leg.to, ns.Trip.EndReach(trip, trip.at))
        and not (leg.trail and ns.Trip.Advance(trip, env.x, env.y) ~= 2) then return M.Next(env) end
    M.State("walking")
    M.Figures(env, true)
end
function M.Next(env)
    local trip, leg = snap.trip, snap.leg
    if legPlan > 0 then ns.Ledger.LegTimed(leg.kind, legPlan, env.now - legT) end
    if leg.kind ~= "walk" then M.landed = leg.kind == "flight" and leg.to.anchor end
    if trip.at >= trip.n then return Arrive(env) end
    trip.at = trip.at + 1
    M.Enter(env)
end
-- A ride begins without a wait at its start (a flight taken, a deck that moves, a loading screen).
function M.Ride(env, i)
    local trip = snap.trip
    if i ~= trip.at then legT, legPlan = env.now, trip.legs[i].seconds end
    trip.at, snap.leg = i, trip.legs[i]
    M.State("riding")
end
-- ADOPT: the trip goes on screen. With keep (a leg number) it takes over from the first trip of the same job
-- (the swap of 5.5.4): that leg stays current, the state stands, and the walk keeps its progress.
function M.Adopt(trip, request, env, keep)
    local dest, Net, old = snap.dest, ns.Net, snap.leg
    nextId = nextId + 1
    trip.id, trip.dest, trip.at = nextId, dest, keep or 1
    for i = 1, trip.n do trip.legs[i].toName = ns.Env.PlaceName(trip.legs[i].to, dest.title) end
    snap.trip, snap.broken, snap.estimate, req = trip, false, false, request
    M.reports.n, M.safer, M.hearth, M.openFlights, M.noShow = 0, false, false, false, false
    base.vLand, base.vInside, base.vSwim, base.factor = Net.BASE_RUN, Net.BASE_RUN, Net.BASE_SWIM, 1
    base.faction, base.level = request.cost.faction, request.cost.level
    for leg in pairs(tried) do tried[leg] = nil end
    ns.Pin.Adopt(dest)
    M.Mark("state")
    if keep then
        local leg = trip.legs[keep]
        if leg.trail and old.trail and leg.trail.n == old.trail.n then leg.i = old.i end
        -- a ride under way keeps the times it has; the legs after it follow them
        if snap.state == "riding" then leg.begun, leg.depart, leg.arrive = old.begun, old.depart, old.arrive end
        snap.leg = leg
        if snap.state ~= "riding" or leg.begun then M.Figures(env, true) end
        return
    end
    M.Enter(env)
end

---------------------------------------------------------------------------------------------------
-- Trails (5.5.8): a trace for every walk leg the plan left without one; each trail as the ground walks it
---------------------------------------------------------------------------------------------------
-- what a walk's end stands on as the plan took it: an anchor's region, else every piece of the end (the least walk)
local function Region(place)
    local G, R, list = ns.Ground, ns.Request, { n = 0 }
    R.busy = false
    if place.ends and place.ends.n > 0 then return place.ends end
    if place.anchor > 0 then return R.Ground(G.AnchorRegion, place.anchor) end
    list.n = R.Ground(G.Locate, place.landmass, place.x, place.y) or 0
    for i = 1, list.n do list[i] = G.found[i] end
    return list.n > 0 and list or nil
end
local function RunTrace(job, pause, emit)
    local a, b = job.leg.from, job.leg.to
    emit("trail", ns.Ground.Route(a.landmass, a.x, a.y, job.r1, b.x, b.y, job.r2, job.cost, job.wp, pause) ~= nil)
end
local function OnTrace(_, found, job)
    tried[job.leg] = true
    if found and snap.trip == job.trip then
        ns.Trip.SetTrail(job.trip, job.i, job.wp)
        if job.leg == snap.leg and snap.state == "walking" then M.Figures(ns.Env.now, true) end
        M.Mark("leg")
    end
end
local function Trace()
    local trip = snap.trip
    for i = trip and trip.at or 1, trip and not snap.broken and trip.n or 0 do
        local leg = trip.legs[i]
        if leg.kind == "walk" and not (leg.trail or leg.est or tried[leg]) and leg.land + leg.inside + leg.swim > 0
            and ns.Ground.Has(leg.from.landmass) then
            local r1 = Region(leg.from)
            local busy = ns.Request.busy
            local r2 = Region(leg.to)
            if busy or ns.Request.busy then return end      -- read on at the next tick
            if r1 and r2 then
                -- The plan priced a walk between two fixed places at the base speeds; one to the goal as asked.
                return M.Chore("trace", RunTrace, { trip = trip, leg = leg, i = i, r1 = r1, r2 = r2,
                    cost = (leg.to.kind == "goal" or leg.from.kind == "start") and req.cost or base,
                    wp = { n = 0, x = {}, y = {}, z = {}, far = {} } }, OnTrace)
            end
            tried[leg] = true
        end
    end
end
-- The trail of the walk at hand as the ground walks it (Ground.Detail), once: until then it runs straight between
-- the entrances it passes, and the minimap shows none of it (6.5). Told twice: walked, then its entrances crossed.
local told
local function Drawn() told("detail", detail) end
local function RunDetail(job, pause, emit)
    told = emit
    ns.Ground.Detail(job.leg.from.landmass, job.wp, job.leg, pause, Drawn)
end
local function OnDetail(_, _, job)
    local leg = job.leg
    if snap.trip ~= job.trip or snap.leg ~= leg then return end
    local i
    -- the foot point, on the new points
    while snap.state == "walking" and i ~= leg.i do i = leg.i; M.Figures(ns.Env.now, true) end
    M.Mark("leg")
end
local function Detail()
    local trip, leg = snap.trip, snap.leg
    if trip and not snap.broken and snap.state == "walking" and leg.trail and leg.trail.raw then
        detail.trip, detail.leg, detail.wp = trip, leg, leg.trail
        return M.Chore("detail", RunDetail, detail, OnDetail)
    end
end
-- A tick whose looks spent its bound (16.7): where the player stands is read on in a job, and the tick runs again.
local function ReadOn(env, pause, emit) ns.Request.pause = pause; ns.Request.Regions(env); ns.Request.pause = false; emit("read") end
local function Read(env) return ns.Request.share == 0 and env.ok and M.Chore("read", ReadOn, env, function() Fast() end) end
needs[1], needs[2], needs[3] = Read, Detail, Trace

---------------------------------------------------------------------------------------------------
-- Notices (5.5.5), rebuilt before every publish that is more than a tick
---------------------------------------------------------------------------------------------------
local function Put(key, a, b, act)
    if quiet and not KEPT[key] then return end
    local n = snap.nNotices + 1
    local r = snap.notices[n] or {}
    snap.notices[n], snap.nNotices = r, n
    r.key, r.a, r.b, r.c, r.act = key, a or false, b or false, false, act or false
end
local function NoHearth()
    local Net, E, options = ns.Net, ns.Env, snap.options
    if not options.hearth or ns.Ledger.Knowledge().bind then return false end
    for k = 1, Net.SpellCount do
        local spell = Net.Spell(k)
        if Net.IsBindSpell(spell.spell) and E.CastReady(spell) then return true end
    end
    return false
end
Notices = function()
    local trip, leg, E, state = snap.trip, snap.leg, ns.Env, snap.state
    snap.nNotices = 0
    if state == "idle" or M.Corpse() then return end     -- the run back to the body tells nothing
    quiet = snap.dest.source == "guide"
    local hearth = trip and not snap.broken and Hearth()
    if hearth then Put("N_HEARTH", hearth) end
    if snap.broken and snap.busy then Put("N_REPLAN") end
    if trip and trip.moved and not trip.swim then Put("N_CLOSEST") end
    -- A report stands while its flight points are unread, and never on the detour it offered.
    local reports, unread, n = M.reports, ns.Ledger.Knowledge().unread, 0
    for i = 1, snap.dest.kind ~= "stop" and reports.n or 0 do
        local r = reports[i]
        if unread[r.landmass] then
            n = n + 1
            reports[n] = r
            if not quiet or r.saves > 0 and (unreadFor or snap.dest.at) == snap.dest.at then
                unreadFor = quiet and snap.dest.at or unreadFor
                local name = E.LandmassName(r.landmass) or ""
                if r.saves > 0 then Put("N_UNREAD_SAVE", name, r.saves) else Put("N_UNREAD", name) end
                if r.stop > 0 then
                    fm.anchor = r.stop
                    Put("N_NEAREST_FM", E.PlaceName(fm), r.walk, snap.options.planner and "goFirst")
                end
            end
        end
    end
    reports.n = n
    if M.openFlights then Put("N_OPEN_FLIGHTS") end
    if ns.Pin.offer then Put("N_NEW_PIN", nil, nil, "pin") end
    if trip and trip.riskSeconds > 0 and snap.options.caution ~= 0 then Put("N_RISK") end
    if trip and M.safer then Put("N_SAFER", M.safer) end
    if trip and trip.saves and trip.at == 1 then Put("N_SAVES", trip.saves) end
    if state == "waiting" and M.noShow then Put("N_NO_SHOW") end
    local cast = state == "waiting" and (leg.kind == "hearth" or leg.kind == "spell")
    if cast and snap.combat then Put("N_AFTER_FIGHT") end
    -- Told on one trip a session: the stone's landing is learned the next time it is used anyway.
    if not quiet and (hearthFor or snap.dest.at) == snap.dest.at and NoHearth() then
        hearthFor = snap.dest.at
        Put("N_NO_HEARTH")
    end
    local gm = req and (E.GroundRefused(req.start.landmass) and req.start.landmass
        or req.goal and E.GroundRefused(req.goal.landmass) and req.goal.landmass)
    if gm and (groundFor or snap.dest.at) == snap.dest.at then
        groundFor = snap.dest.at
        Put("N_NO_GROUND", E.LandmassName(gm) or "")
    end
    if state == "failed" then Put("N_STOP", nil, nil, "stop") end
end
