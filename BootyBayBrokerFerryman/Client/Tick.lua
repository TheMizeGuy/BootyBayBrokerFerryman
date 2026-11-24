local ADDON, ns = ...

-- The tick's rows of INTERFACES 5.5.4: what one look at the player does in each state (5.5.3, 5.5.6).
local M = {}
ns.Tick = M

M.running = false       -- Senses is being fed: its facts use the tick's read

local sqrt, max, floor, huge = math.sqrt, math.max, math.floor, math.huge
local Env, Ledger, Lead, Driver, Side = ns.Env, ns.Ledger, ns.Lead, ns.Driver, ns.Side
local snap = Lead.snap
local EPS, FLIGHT_REACH = 0.001, 100
local FM, CASTS = { [1] = true }, { hearth = true, spell = true }
local THROUGH = { tram = true, portal = true, hearth = true, spell = true }
local COOL, LANDED = 2, 3       -- seconds: longer than a global cooldown; a cast's landing is known
local fastRan, offT, offFar, offId, offAt, airTicks, second = false, false, false, 0, 0, 0, 0    -- offId, offAt: no trip is kept
local coolT = false             -- since when the cast leg at hand has read not ready

local function Figures(env)
    Lead.Figures(env)
    Lead.Mark("tick")
end

-- What comes next at call c of vessel v (5.5.11): its seconds and "arrives" or "leaves", counted from the realm's
-- timetable of the vessel ("aboutArrives" or "aboutLeaves" when it is an estimate, only the departure when its doubt is
-- half the stay or more); the period and "every" when there is none usable. A departure passed up to hold ago (a
-- waited leg's miss rule), else its u (an estimate's at most MISS), is kept.
local NEAR, KEEP, PLATFORM = 60, 90, { [3] = true }
local view = {}
local function Due(v, c, env, hold)
    local kv, Net, now = Ledger.Knowledge().vessels[v], ns.Net, env.now
    local tt = Ledger.Timetable(v, now, view)
    if not tt then return kv.period, "every" end
    local about = tt.tier == "about"
    local left = ns.Clock.Next(tt, Net.Offset(v, c), now - (hold or about and math.min(tt.u, ns.Clock.MISS) or tt.u)) - now
    local stay = select(2, Net.Call(v, c))
    if left > stay and not (about and tt.u >= stay / 2) then return left - stay, about and "aboutArrives" or "arrives" end
    return max(0, left), about and "aboutLeaves" or "leaves"
end

-- The dock list (5.5.12): running calls of the player's faction within NEAR yards, kept to KEEP.
local place = { kind = "stop", anchor = 0, landmass = 0, x = 0, y = 0 }
function M.Docks(env)
    local docks, Net, know, Senses, n, was = snap.docks, ns.Net, Ledger.Knowledge(), ns.Senses, 0, snap.docks.n
    local v1, c1, v2, c2 = was > 0 and docks[1].v, was > 0 and docks[1].c, was > 1 and docks[2].v, was > 1 and docks[2].c
    local faction = select(3, Env.Character())
    local can = env.ok and not (env.dead or env.taxi or env.instance and env.landmass ~= Net.TramMap or Senses.carried or Driver.loading)
    for v = 1, can and Net.VesselCount or 0 do
        local kv, _, air, _, _, calls = know.vessels[v], Net.Vessel(v)
        for c = 1, kv.runs ~= "no" and select(2, Net.Service(v)) % (2 * faction) >= faction and calls or 0 do
            local a = Net.Call(v, c)
            local m, x, y = Net.Anchor(a)
            local r = (v == v1 and c == c1 or v == v2 and c == c2) and KEEP or NEAR
            if n < 2 and m == env.landmass and (x - env.x) ^ 2 + (y - env.y) ^ 2 <= r * r then
                n = n + 1
                local e = docks[n] or {}
                if n > was or e.v ~= v or e.c ~= c then
                    place.anchor = Net.Call(v, c % calls + 1)
                    place.landmass, place.x, place.y = Net.Anchor(place.anchor)
                    e.kind, e.name, e.v, e.c, e.a = air and "zeppelin" or "boat", Env.PlaceName(place), v, c, a
                    Lead.Mark("state")
                end
                docks[n] = e
                e.count, e.what = Due(v, c, env)
            end
        end
    end
    -- On the tram's own map, at the player's own pace: the nearer platform's one way, its phase not known (W11). A
    -- read of no time (another read this frame, the first after a reload) says nothing of the pace: the list stands.
    if can and n == 0 and env.landmass == Net.TramMap and (env.dt > 0 and env.moved <= 1.5 * max(know.vLand, know.vSwim,
        env.run or 0) * env.dt or env.dt == 0 and was == 1 and docks[1].kind == "tram") then
        local eA, eB, pA = Net.TramStops()
        local a, e = Net.Nearest(env.landmass, env.x, env.y, PLATFORM, huge), docks[1] or {}
        if was ~= 1 or e.a ~= a then
            place.anchor = a == pA and eB or eA
            place.landmass, place.x, place.y = Net.Anchor(place.anchor)
            e.kind, e.name, e.v, e.c, e.a = "tram", Env.PlaceName(place), 0, 0, a
            Lead.Mark("state")
        end
        docks[1], e.count, e.what, n = e, Net.TramPeriod() / 2, "every", 1
    end
    if n ~= was then Lead.Mark("state") end
    docks.n = n
    return n
end
function M.Dock(env)    -- the event entry: with no trip, a dock, a timed flight, a ride under way or the tram starts the watch
    if Driver.ready and snap.state == "idle" and not Lead.watching
        and (snap.flyTo or M.Docks(env) > 0 or ns.Senses.carried or env.ok and env.landmass == ns.Net.TramMap) then
        Lead.Watch(true)
    end
end

-- The flight timer (5.5.13): where the flight lands, chosen in the window or the trip's own, and when; else the
-- deck's next call. over: the tick saw the landing (off the taxi, a flight record is one no event told), or a death.
local flyAt, tramTo, tramAt = false, false, 0     -- the train under way (R4): its far door, and when it left
function M.Fly(env, over, from, ago)
    local f, Net, know, leg, r = not over and env.taxi and Ledger.Flight(), ns.Net, Ledger.Knowledge(), snap.leg, not over and Ledger.Ride()
    local eA, eB, pA, pB = Net.TramStops()
    if from then        -- the far end of the platform left, a trip's own ride and the way back alike
        tramTo = from == pA and eB or from == pB and eA
        tramAt = env.now - (ago or 0)
    end
    tramTo = not over and ns.Senses.carried and tramTo
    local to = f and (f.to or snap.state == "riding" and leg.kind == "flight" and leg.to.anchor)
    local ch, yards = to and know.chains[f.from * 1024 + to], 0
    for i = 1, ch and #ch - 1 or 0 do     -- priced as Net prices a chain read from the window (16.6)
        local y = Net.FlightYards(ch[i], ch[i + 1])
        yards = y and yards and yards + (i > 1 and max(y - Net.JoinYards(ch[i - 1], ch[i], ch[i + 1]), 1) or y)
    end
    flyAt = ch and yards and f.t + yards / know.vFly + (#ch - 2) * know.hopFlight or false
    local kind = to and "flight"
    if not f and r then     -- a deck under way: at rest at its next call after the table's ride
        to, flyAt = (Net.Call(r.v, r.to)), r.start + Net.Ride(r.v, r.call)
        kind = select(2, Net.Vessel(r.v)) and "zeppelin" or "boat"
    elseif not f and tramTo then
        to, flyAt, kind = tramTo, tramAt + Net.TramRide(), "tram"
    end
    if to then place.anchor, place.landmass, place.x, place.y = to, Net.Anchor(to) end
    snap.flyTo, snap.flyKind = to and Env.PlaceName(place) or false, kind
    snap.flyLeft = flyAt and max(0, flyAt - env.now)
    Lead.Mark("state")
    M.Dock(env)
end

-- The position can be trusted (5.5.6): at rest for half a second, or running and this read in step with the
-- previous one, so a player who keeps moving after a loading screen is not left without a trip.
local function Settled(env)
    if env.still >= 0.5 then return true end
    local know, was = Ledger.Knowledge(), Driver.was
    return was.ok and was.landmass == env.landmass and not env.jump and (env.speed or 0) > 0
        and env.moved <= 1.5 * max(know.vLand, know.vSwim) * env.dt
end

-- Arrival (5.5.6 b): walking within the arrival distance of where the trip ends, on its level, whichever
-- leg is at hand: a player who got there their own way has arrived.
local function Arrived(env)
    local G = ns.Ground
    -- a body: CORPSE_IN_RANGE ends the run; one inside an instance, its entrance's place, as a trip there (decision 125)
    if snap.dest.kind == "stop" or Lead.Corpse() and snap.dest.ref == 0 then return false end
    local goal, trip = Lead.Request().goal, snap.trip
    -- a trip that ends where the ground does (trip.moved) arrives where its last step ends, on any level
    local at = trip.moved and trip.legs[trip.n].to or goal
    if not Lead.Near(env, at, snap.options.arriveYards) then return false end
    if at ~= goal or goal.n == 0 then return true end
    for i = 1, (ns.Request.Regions(env)) do
        for j = 1, goal.all or goal.n do
            if ns.Request.Ground(G.Near, goal.landmass, G.found[i], goal[j]) then return true end
        end
    end
    return false
end

-- A party member who is the destination has moved on: the destination follows. The member is known by name:
-- when the group changes they are found again, or the destination stays where they were last seen.
local function PartyMoved()
    local dest = snap.dest
    if dest.kind ~= "party" then return false end
    local who, m, x, y = Env.Party(dest.ref)
    for i = 1, dest.who and who ~= dest.who and 4 or 0 do
        who, m, x, y = Env.Party(i)
        if who == dest.who then
            dest.ref = i
            break
        end
        m = nil
    end
    local near = m == dest.landmass and (x - dest.x) ^ 2 + (y - dest.y) ^ 2 < Driver.PARTY_MOVE ^ 2
    if not m or near then return false end
    local uiMap, mx, my = ns.Request.Point("party", dest.ref)
    if not uiMap then return false end
    dest.uiMap, dest.mx, dest.my, dest.landmass, dest.x, dest.y = uiMap, mx, my, m, x, y
    return true
end

-- The player stands on a piece the data has as indoors: a plan from here leads out by its doors (5.5.6).
local function Inside(env)
    local R, G = ns.Request, ns.Ground
    return G.Has(env.landmass) and R.Regions(env) > 0 and R.Ground(G.Indoors, env.landmass, G.found[1]) == true
end

local TICK = {}
function TICK.planning() end
function TICK.idle(env)     -- the dock watch's: it ends when nothing is listed, timed in the air, carried or loading
    local keep = M.Docks(env) > 0 or snap.flyTo or ns.Senses.carried or Driver.loading
        or env.ok and env.landmass == ns.Net.TramMap       -- a train not yet sensed moves fast (W11)
    if keep then Lead.Mark("tick") else Lead.Watch(false) end
end
function TICK.walking(env)
    local trip, leg = snap.trip, snap.leg
    if offId ~= trip.id or offAt ~= trip.at then offT, offId, offAt = false, trip.id, trip.at end
    if Arrived(env) then return (Lead.Corpse() and Driver.Ended or Lead.Clear)(true) end
    if env.jump or env.landmass ~= leg.from.landmass then return Driver.Replan(env, true) end
    local last = trip.at == trip.n and snap.dest.kind ~= "stop"
    local progress = ns.Trip.Advance(trip, env.x, env.y)
    if not last and (progress == 2 or not leg.trail and Lead.Near(env, leg.to, ns.Trip.EndReach(trip, trip.at))) then
        return Lead.Next(env)
    end
    -- Off the way (5.5.6), on walking data: the fast tick keeps running so the three seconds are measured finely.
    -- The trip leads on (the arrow and the beads lead back to the way ahead) until the way from here takes its
    -- place. Indoors, at rest, it counts from OFF_INDOORS, when a look puts the player on an indoors piece. Not
    -- while the player gains on a side trail (5.5.15).
    offFar = trip.off > Driver.OFF_YARDS
    if (offFar or env.indoors and env.still > 0 and trip.off > Driver.OFF_INDOORS)
        and not (snap.broken or Driver.stale or Side.Held(env.now))
        and not (last and trip.swim) and (leg.trail or ns.Ground.Has(env.landmass)) then
        offT = offT or env.now
        if offFar then Lead.Fast(true) end
        if env.now - offT >= Driver.OFF_SECONDS - EPS then
            local inside = offFar or Inside(env)
            offT = not inside and ns.Request.busy and offT      -- a look cut short is read on (Lead's read need)
            if inside then
                Driver.Replan(env, false, "off")
                if snap.trip ~= trip or snap.state ~= "walking" then return end
            end
        end
    else
        offT = false
    end
    -- A start on several regions is settled by walking the trail away from it (INTERFACES 16.8).
    local s = trip.doubt and trip.at == 1 and Lead.Request().start
    if s and trip.off <= Driver.OFF_YARDS and (env.x - s.x) ^ 2 + (env.y - s.y) ^ 2 > ns.Request.HISTORY_YARDS ^ 2 then
        trip.doubt = false
    end
    if snap.dest.source == "guide" then M.Docks(env) end
    Figures(env)
end
function TICK.waiting(env)
    local leg, w, Clock = snap.leg, Lead.wait, ns.Clock
    local kind, gone = leg.kind, 0
    snap.waited = env.now - w.at
    if w.landmass and env.ok then
        gone = env.landmass == w.landmass and sqrt((env.x - w.x) ^ 2 + (env.y - w.y) ^ 2) or huge
    end
    gone = Side.Gone(env, gone)
    if Lead.openFlights then
        if gone > Driver.DECLINE_YARDS then return Driver.Resumed() end
        return Figures(env)
    end
    -- Standing at the leg's far end, however the player got there, is having taken it (a lift, a portal).
    if gone > ns.Trip.PASS and Lead.Near(env, leg.to, Driver.RIDE_REACH) then return Lead.Next(env) end
    if gone > Driver.DECLINE_YARDS then
        if leg.ref < 0 then Ledger.Strike(Lead.Request().know.portals[-leg.ref].key) end
        return Driver.Without(env, kind, 0)
    elseif leg.vessel > 0 then
        local period = Lead.Request().know.vessels[leg.vessel].period
        if Lead.noShow then snap.count, snap.countWhat = false, false
        else snap.count, snap.countWhat = Due(leg.vessel, leg.call, env, leg.tt and leg.u + Clock.MISS) end
        -- the trip is timed as the pier line is: on the realm's timetable, counted or estimated, else not (5.2.1)
        local tt, was = snap.countWhat and snap.countWhat ~= "every" and Ledger.Timetable(leg.vessel, env.now, view), leg.tt
        local moved = (tt and tt.phase or false) ~= (was and was.phase or false)
        if (moved or tt and was and tt.tier ~= was.tier) and (tt or snap.countWhat) then
            -- a change of tier alone keeps the departure; its ride keeps the leg's u in its seconds
            tt = tt and Ledger.Timetable(leg.vessel, env.now)
            local u = tt and tt.u or 0
            leg.tt, leg.seconds, leg.u, leg.wait = tt, leg.seconds - leg.u + u, u, period / 2
            leg.arrive = leg.depart + leg.seconds
            leg.tag = leg.tag == "unconfirmed" and leg.tag or not tt and "phase" or tt.tier == "about" and "estimate" or false
            leg.est = leg.tag and true or false
            local trip, e = snap.trip, snap.trip.swim and true or false
            for i = 1, trip.n do e = e or trip.legs[i].est end
            trip.estimate = e
            ns.Trip.Retime(snap.trip, env.now, env.x, env.y, Lead.Cost(), moved); Lead.Mark("leg")
        end
        if leg.tt and env.now > leg.depart + leg.u + Clock.MISS then   -- missed; an estimate that failed is untimed (P5)
            if leg.tt.tier == "about" then Ledger.Missed(leg.ref, true) end
            Driver.Replan(env, false)
        end
        if not (leg.tt or Lead.noShow) and snap.waited > period * (1 + Clock.SIGMA_DEFAULT) then
            Lead.noShow, snap.count, snap.countWhat = true, false, false
            if leg.tag == "phase" then leg.tag = false end      -- "every N min, not timed yet" no longer holds
            Lead.Mark("notice")
        end
    elseif CASTS[kind] and not env.combat then
        coolT = not Env.CastReady(ns.Net.Spell(ns.Net.SpellByID(leg.ref))) and (coolT or env.now)
        if coolT and env.now - coolT >= COOL then
            coolT = false
            Driver.Replan(env, true)
        end
    end
    if snap.state == "waiting" then Figures(env) end
end
function TICK.riding(env)
    local trip, leg, kind = snap.trip, snap.leg, snap.leg.kind
    if kind == "flight" then
        airTicks = env.taxi and 0 or airTicks + 1
        if airTicks >= 2 and env.still >= 0.5 then
            airTicks = 0
            M.Fly(env, true)
            return Driver.Row("landed", env, ns.Net.Nearest(env.landmass, env.x, env.y, FM, FLIGHT_REACH) or 0)
        end
    elseif THROUGH[kind] and not Driver.loading and env.ok and not ns.Senses.carried
        and (env.still >= 0.5 or kind ~= "tram" and Settled(env)) then
        if Lead.Near(env, leg.to, Driver.RIDE_REACH) then return Lead.Next(env) end
        -- The ride did not end where the plan said (5.5.4): the Ledger has seen where; plan from there. A cast
        -- has landed a moment after it or after its loading screen; a tram or portal may still be on its way.
        local lost = env.now - Driver.rideT >= (CASTS[kind] and LANDED or Driver.RIDE_LOST)
        if lost and ns.Ground.Has(env.landmass) then return Driver.Relocate(env) end
    elseif Driver.ashore.leg == leg and env.ok and not ns.Senses.carried then
        -- Set down at another call: walked away from it, or left behind for a whole period of the vessel.
        local a, period = Driver.ashore, Lead.Request().know.vessels[leg.vessel].period
        if not Lead.Near(env, a, Driver.RIDE_REACH) or env.now - a.at > period then return Driver.Relocate(env) end
    end
    if floor(env.now) ~= second then
        -- A ride that runs over its time ends no earlier than now: the legs after it move with it.
        local late = env.now - leg.arrive
        for i = trip.at, late > 0 and trip.n or 0 do
            local l = trip.legs[i]
            l.depart, l.arrive = i > trip.at and l.depart + late or l.depart, l.arrive + late
        end
        if late > 0 then trip.arrive = trip.arrive + late end
        second, snap.left = floor(env.now), trip.arrive - env.now
        Lead.Mark("tick")
    end
end
function TICK.suspended(env)
    local r = Driver.retry
    if snap.reason == "tram" then M.Docks(env) end      -- waiting to leave the tram: its platform is shown (W11)
    if env.taxi and not ns.Senses.held then
        if snap.reason ~= "air" then Lead.State("suspended", "air") end
        return
    end
    if Driver.loading or not env.ok or env.instance or ns.Senses.carried or not Settled(env) then return end
    local far = env.landmass ~= r.landmass or (env.x - r.x) ^ 2 + (env.y - r.y) ^ 2 >= Driver.RETRY_YARDS ^ 2
    if far or env.now - r.at >= Driver.RETRY_SECONDS - EPS then Driver.Resume(env) end
end

function M.Rows(env)
    local state = snap.state
    if snap.flyKind == "tram" and not (env.ok and env.landmass == ns.Net.TramMap) then M.Fly(env, true) end
    if snap.flyTo and flyAt then snap.flyLeft = max(0, flyAt - env.now); Lead.Mark("tick") end
    if state ~= "walking" then offT = false end
    if state ~= "waiting" then coolT = false end
    if state == "idle" and Lead.watching then return TICK.idle(env) end
    if state == "idle" or state == "dead" or state == "failed" then return end
    if env.dead and not (env.ghost and Lead.Corpse()) then return Driver.Dead(env) end
    if Lead.Corpse() and not env.dead then return Driver.Back() end     -- alive, and no event told it
    if state == "suspended" then return TICK.suspended(env) end
    if state ~= "riding" then
        if env.instance or not env.ok then return Driver.Suspend(env, env.instance and "instance" or "lost") end
        if Driver.due and Driver.stale == "off" and Side.Held(env.now) then Driver.due, Driver.stale = false, false end
        if PartyMoved() then
            if state == "planning" then return Driver.Relocate(env) end
            Driver.Replan(env, false, true)
        elseif Driver.due and state ~= "planning" then
            Driver.Replan(env, false)
        end
        if snap.state ~= state then return end
    end
    TICK[state](env)
end

-- 5.5.3: one read, then the Ledger and Senses, then the rows. The slow tick stands back in a second in
-- which a fast one acted.
function M.Run(isFast)
    if isFast then
        fastRan = true
    elseif fastRan then
        fastRan = false
        return
    end
    local env, know, was = Env.Read(), Ledger.Knowledge(), Driver.was
    Ledger.Tick(env)
    M.running = true
    ns.Senses.Feed(env, max(know.vLand, know.vSwim))
    M.running = false
    if env.moved > 0.5 and not env.taxi then
        Lead.Fast(true)
    elseif isFast and (env.taxi or env.still >= Driver.FAST_STOP) and not (offT and offFar) then
        Lead.Fast(false)
    end
    Side.Tick(env)
    ns.Request.share = ns.Ground.BOUND      -- one bound for all of a tick's looks (16.7)
    M.Rows(env)
    was.ok, was.landmass, was.x, was.y = env.ok, env.landmass, env.x, env.y
    Lead.Chores(env)
    ns.Request.share = false
    Lead.Flush()
end
Lead.Wire(M.Run)
