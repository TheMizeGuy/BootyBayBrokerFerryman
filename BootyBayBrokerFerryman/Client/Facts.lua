local ADDON, ns = ...

-- The facts of Senses, by state (INTERFACES 5.5.4): Facts[fact][state] is the row Driver.Row takes. A missing
-- cell is "-": the fact is ignored in that state.
local M = {}
ns.Facts = M

local min = math.min
local Env, Ledger, Lead, Pin, D = ns.Env, ns.Ledger, ns.Lead, ns.Pin, ns.Driver
local snap = Lead.snap
local taxi = {}
local FLIGHT, RIDES = { flight = true }, { boat = true, zeppelin = true, tram = true, lift = true }
local CASTS = { hearth = true, spell = true }
local THROUGH = { tram = true, portal = true, hearth = true, spell = true }    -- legs a loading screen carries out

local function Row(fact, states, fn)
    local row = M[fact] or {}
    M[fact] = row
    for _, state in ipairs(type(states) == "table" and states or { states }) do row[state] = fn end
end
local LED, ACTIVE = { "walking", "waiting" }, { "planning", "walking", "waiting", "riding", "suspended" }
local BUSY = { "planning", "walking", "waiting", "riding", "suspended", "dead", "failed" }
local ANY = { "idle", unpack(BUSY) }

-- A ride the trip expects begins: the leg at hand or the one after it. Its times start from now. Taking the
-- trip's own ride mends a trip broken off the trail; a plan that runs is then due again on the ground.
local function Ride(env, i, ago)
    local mended = snap.broken and not D.Unwanted(snap.trip.legs[i])
    if mended or D.stale then D.due = D.due or Lead.Planning() end
    if mended then snap.broken = false end
    D.rideT = env.now
    Lead.Ride(env, i)
    ns.Trip.Retime(snap.trip, env.now - (snap.leg.vessel > 0 and ago or 0), env.x, env.y, Lead.Cost(),
        THROUGH[snap.leg.kind] and not CASTS[snap.leg.kind] or "begun")
    snap.left = snap.trip.arrive - env.now
    return true
end
local function Board(env, anchor, kinds, ago)
    local trip = snap.trip
    for i = trip.at, min(trip.at + 1, trip.n) do
        local leg = trip.legs[i]
        if kinds[leg.kind] and leg.from.anchor == anchor then return Ride(env, i, ago) end
    end
end
local function Astray(env, reason)
    if snap.trip then snap.broken = true end
    D.Suspend(env, reason)
end
-- With no trip, a look for a dock to watch (5.5.12); Tick loads after this file.
local function DockNow(env) ns.Tick.Dock(env) D.Corpse(env) end
-- A loading screen cancels jobs; a replan it cancels is due again (5.5.4, RESUME).
local function Hold()
    D.due = D.due or Lead.Planning()
    Lead.Cancel()
end

Row("loaded", "idle", function() Ledger.Load() end)
Row("login", "idle", D.Login)

Row("tookOff", { "planning", "riding" }, function(env) Astray(env, "air") end)
Row("tookOff", LED, function(env, anchor) return Board(env, anchor, FLIGHT) or Astray(env, "air") end)
Row("tookOff", "suspended", function() Lead.State("suspended", "air") end)
Row("landed", "riding", function(env, anchor)
    local leg = snap.leg
    if leg.kind == "flight" and leg.to.anchor == anchor then return Lead.Next(env) end
    Lead.landed = false
    D.Relocate(env)
end)
-- A ride of the player's own ends: the next plan is a fresh one (5.5.7).
local function Own(env) Lead.landed = false; D.Resume(env) end
Row("landed", "suspended", Own)
Row("carried", "planning", function(env) Astray(env, "carried") end)
Row("carried", LED, function(env, anchor, ago) return Board(env, anchor, RIDES, ago) or Astray(env, "carried") end)
Row("carried", "suspended", function() Lead.State("suspended", "carried") end)
Row("dropped", "riding", function(env)
    local leg, Net = snap.leg, ns.Net
    Lead.landed = false
    if Lead.Near(env, leg.to, D.RIDE_REACH) then return Lead.Next(env) end
    if Lead.Near(env, leg.from, D.RIDE_REACH) then return Lead.Enter(env) end
    for c = 1, leg.vessel > 0 and select(5, Net.Vessel(leg.vessel)) or 0 do
        local m, x, y = Net.Anchor((Net.Call(leg.vessel, c)))
        if env.landmass == m and (env.x - x) ^ 2 + (env.y - y) ^ 2 <= D.RIDE_REACH ^ 2 then
            local a = D.ashore      -- the tick ends the ride if the player stays ashore there (Tick)
            a.leg, a.landmass, a.x, a.y, a.at = leg, m, x, y, env.now
            return
        end
    end
    if leg.kind ~= "tram" then D.Relocate(env) end
end)
Row("dropped", "suspended", Own)

Row("loadStart", "planning", function(env) D.Suspend(env, "loading") end)
Row("loadStart", "walking", function(env)
    local trip, was, dest, r = snap.trip, D.was, snap.dest, snap.options.arriveYards + D.DOOR_REACH
    local leg, to = trip.legs[trip.at + 1], trip.legs[trip.n].to
    -- On the last walk, its end within reach of where the loading screen began: arrived, as no tick can see it now.
    if not (leg or dest.kind == "stop" or dest.kind == "entrance" or Lead.Corpse())
        and (Lead.Near(was, to, r) or Lead.Near(env, to, r)) then return Lead.Clear(true) end
    Hold()
    if leg and (leg.kind == "tram" or leg.kind == "portal")
        and (Lead.Near(was, leg.from, D.BOARD_NEAR) or Lead.Near(env, leg.from, D.BOARD_NEAR)) then
        return Ride(env, trip.at + 1)
    end
    D.Suspend(env, "loading")
end)
Row("loadStart", "waiting", function(env)
    Hold()
    if not THROUGH[snap.leg.kind] then return D.Suspend(env, "loading") end
    Ride(env, snap.trip.at)
end)
Row("loadStart", "riding", Hold)
Row("loadStart", "suspended", function() Lead.State("suspended", "loading") end)
Row("loadEnd", ANY, function(env, isLogin, isReload)
    local dest, state = snap.dest, snap.state
    D.loading, D.rideT, Lead.landed = false, env.now, false
    if dest and dest.kind == "entrance" and env.instance and env.instanceMap == dest.ref then
        if state ~= "dead" then Lead.Clear(state ~= "failed") end
    elseif state == "idle" then
        local t = (isLogin or isReload) and D.ready and Ledger.SavedTrip()
        if t then D.Go(t.kind, t.ref, t.uiMap, t.mx, t.my, t.title, t.source, t.at, t.resume) else DockNow(env) end
    elseif state == "suspended" then
        Lead.State("suspended", env.instance and "instance" or "lost")
    elseif state == "riding" and env.instance and THROUGH[snap.leg.kind] and snap.leg.kind ~= "tram" then
        Astray(env, "instance")     -- a dungeon door, not the cast or portal waited on
    end
    D.Corpse(env)       -- a ghost after a reload, or the destination it restored set aside
end)

Row("cast", "waiting", function(env, spell)
    local leg = snap.leg
    if CASTS[leg.kind] and leg.ref == spell then Ride(env, snap.trip.at) end
end)
Row("bound", "planning", D.Relocate)
Row("bound", LED, function(env) D.Replan(env, snap.leg.kind == "hearth") end)
local function Died(env)     -- where, for the run back to the body; a flight's timer ends with the flight (5.5.13)
    D.Died(env.instance and env.instanceMap or 0)
    if snap.flyTo then ns.Tick.Fly(env, true) end
end
Row("died", ANY, Died)
Row("died", ACTIVE, function(env) Died(env) D.Dead() end)
Row("alive", { "planning", "walking", "suspended", "dead", "failed" }, function(env)
    D.Died(0)
    if Lead.Corpse() then D.Back() elseif snap.state == "dead" then D.Locate(env) end
end)
Row("ghost", { "idle", "dead", "failed" }, D.Corpse)
Row("corpseNear", { "planning", "walking" }, function() if Lead.Corpse() then D.Dead() end end)
Row("corpseFar", "dead", function(env) if Lead.Corpse() and env.ghost then D.Locate(env) end end)
Row("combat", ANY, function(env, on)
    snap.combat = on == true
    ns.Work.SetCombat(snap.combat)
    Lead.Mark("option")
    -- A plan made in the fight left a cast out (plan again at the next tick when leading, at once when planning)
    -- or could not load the walking data (at once).
    if snap.combat or not snap.dest then return end
    local retry = Env.GroundRetry()
    if not (D.held or retry) then return end
    D.held = false
    if snap.state == "planning" then D.Relocate(env) elseif retry and snap.trip then D.Replan(env, false, false, true)
    elseif snap.trip then D.due = true end
end)
-- "Flight points read" (5.5.4): the window's nodes go to the Ledger; the row is chosen by what changed.
local function Flights(env)
    local n, uiMap = Env.ReadTaxi(taxi)
    local _, changed = Ledger.Taxi(taxi, n, uiMap)
    local state, dest = snap.state, snap.dest
    if state == "waiting" and dest.resume and (changed or Lead.openFlights) then return D.Resumed() end
    if not changed then return end
    if state == "planning" then D.Relocate(env) elseif state == "walking" or state == "waiting" then D.Replan(env, false) end
end
Row("taxiOpen", ANY, Flights)
Row("taxiNodes", ANY, Flights)
Row("pin", ANY, function()
    local act = D.ready and Pin.Changed(snap.dest)
    if act == "go" then
        D.Go("pin", 0, nil, nil, nil, nil, "pin")
    elseif act == "clear" then
        Lead.Clear(false)
    elseif act then
        Lead.Mark("notice")
    end
end)
-- Before a reload or logout the player's own pin goes back: the trip restored after it drives the pin again.
Row("logout", ANY, function() Pin.End() end)
Row("quest", BUSY, function(_, id, accepted)
    local dest = snap.dest
    if not accepted and dest.kind == "quest" and dest.ref == id then Lead.Clear(false) end
end)
local function TickNow(env) ns.Tick.Rows(env) end
Row("zone", ACTIVE, TickNow)
Row("zone", "idle", DockNow)
Row("moved", "idle", DockNow)
Row("zone", { "dead", "failed" }, D.Corpse)       -- the body the client did not give at the release
Row("moved", { "dead", "failed" }, D.Corpse)
Row("moved", ACTIVE, function(env, on)
    if on then Lead.Fast(true) end
    TickNow(env)
end)
Row("level", { "planning", "walking", "waiting" }, function(env)
    if snap.options.caution ~= 0 then D.PlanChanged(env) end
end)
Row("scale", ANY, function() Lead.Mark("option") end)
Row("minimap", "walking", function() Lead.Mark("tick") end)     -- only the walk drawn on it changes
