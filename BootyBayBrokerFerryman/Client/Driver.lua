local ADDON, ns = ...

-- The state machine of DESIGN section 6, as INTERFACES 5.5.4 tabulates it: what a destination and each
-- emission of the plan job does in each state. The rows of Senses' facts are in Facts, the tick's in Tick, the
-- procedures in Lead, the request in Request, the game's map pin in Pin.
local M = {}
ns.Driver = M

M.OFF_YARDS, M.OFF_INDOORS, M.OFF_SECONDS, M.REPLAN_GAP, M.BETTER_SECONDS, M.BETTER_SHARE = 40, 10, 3, 5, 30, 0.05
M.DECLINE_YARDS, M.RETRY_YARDS, M.RETRY_SECONDS, M.SLOW_TICK, M.FAST_TICK, M.FAST_STOP = 60, 30, 2, 1, 0.2, 2
M.RIDE_REACH, M.PARTY_MOVE, M.BOARD_NEAR, M.GOAL_ANCHOR, M.RIDE_LOST, M.DOOR_REACH = 60, 100, 30, 15, 20, 15

local huge = math.huge
local Env, Ledger, Lead, Request, Pin = ns.Env, ns.Ledger, ns.Lead, ns.Request, ns.Pin
local snap = Lead.snap
local planAt, planned, fromFirst, shown = -huge, false, false, false    -- of the plan job: when, its request,
-- its first trip, and the trip of it that is on screen
local PLAN_KEYS, SLIDERS = { caution = true, hearth = true, spells = true, splitFlights = true }, { hearthMinSave = true, splitMinSave = true }
local autoKind, autoTrip = false, false     -- the kind the tick declined last, and the trip's id it declined it on
-- Ferryman's own trips: the player's, the run to the body and RestedXP's, followed. With the planner off none is set.
local SELF = { hand = true, pin = true, restore = true, corpse = true, guide = true }
M.ready = false         -- the login work is done
M.due = false           -- a replan waits for the running job to end and for REPLAN_GAP (5.5.2)
M.stale = false         -- the next proven plan replaces the trip on screen even when it is no better
M.held = false          -- the last plan left a cast out for a fight
M.loading = false       -- a loading screen is open
M.rideT = 0             -- when the present ride began, or its last loading screen ended
M.retry = { landmass = false, x = 0, y = 0, at = 0 }    -- where and when the position was last tried
M.ashore = { leg = false, landmass = 0, x = 0, y = 0, at = 0 }    -- the ride's vessel set down at another call

-- LOCATE, PLAN, REPLAN (5.5.2)
local OnPlan
-- What a reload gives back: a detour to a flight master saves the destination it resumes; the run to the body,
-- what that saves of the one it set aside; a trip that failed, nothing (FAIL clears it and keeps the destination
-- for a new try in this session only).
local function Save(d) if d and d.kind == "corpse" then d = d.resume end Ledger.SaveTrip(d and (d.resume or d) or nil) end
function M.Suspend(env, reason)
    local r = M.retry
    M.due = M.due or (snap.trip and Lead.Planning()) or false
    Lead.Cancel()
    r.landmass, r.x, r.y, r.at = env.ok and env.landmass, env.x, env.y, env.now
    if snap.state ~= "suspended" or snap.reason ~= reason then Lead.State("suspended", reason) end
end
function M.Dead()
    Lead.Cancel()
    Lead.Drop()
    Lead.State("dead")
end
-- LOCATE when the ground there is still being read (16.7): a plan job makes the looks with its pause, and LOCATE
-- goes on with its answers (never asking again, whatever the cache holds by then).
local function Read(job, pause, emit) emit("read", Request.Read(job.env, job.dest, pause)) end
local read
local function OnRead(what, value)
    if what == "read" then read = value
    elseif what == "end" or what == "error" then
        Lead.Planned()
        if what == "error" or not read then return Lead.Fail("error") end
        local got = read
        read = false
        M.Locate(Env.Read(), got)
    end
end
function M.Locate(env, got)
    if env.dead and not (env.ghost and Lead.Corpse()) then return M.Dead() end
    local start, reason, goal, why
    if got then
        start, reason, goal, why = got[1], got[2], got[3], got[4]
    else
        start, reason = Request.Start(env)
        if not start and reason ~= "busy" then return M.Suspend(env, reason) end
        goal, why = Request.Goal(snap.dest)
        if reason == "busy" or why == "busy" then
            read = false
            Lead.Plan({ env = env, dest = snap.dest }, OnRead, Read)
            if not snap.trip then Lead.State("planning") end
            return
        end
    end
    if not start then return M.Suspend(env, reason) end
    if not goal then return Lead.Fail(why) end
    planned = Request.Build(env.now, start, goal, snap.declined, snap.nDeclined, Lead.landed)
    M.held = planned.held
    Lead.Plan(planned, OnPlan)
    planAt, M.due, fromFirst, shown = env.now, false, false, false
    if not snap.trip then
        snap.estimate, M.stale = false, false
        Lead.State("planning")
    end
    Lead.Mark("notice")
end
-- "Drop trip, LOCATE" and "restart PLAN": nothing of the old plan stays.
function M.Relocate(env)
    if snap.trip then Lead.Mark("state") end
    Lead.Cancel()
    Lead.Drop()
    M.Locate(env)
end
-- broken: the trip on screen is impossible, the arrow rests. stale: a later leg is no longer wanted, or "off" the
-- way (a plan that finds none then leaves the trip); the walk at hand leads, and the next plan replaces the trip,
-- better or not. now: the player asked, so neither a running plan nor the gap holds it back.
function M.Replan(env, broken, stale, now)
    M.stale = M.stale == true or stale == true or stale or M.stale or false
    if broken and not snap.broken then
        snap.broken = true
        Lead.Mark("state")
    end
    if not now and (Lead.Planning() or env.now - planAt < M.REPLAN_GAP) then
        M.due = true
    else
        M.Locate(env)
    end
end
-- A leg the player declined, or one of a kind the options have just switched off.
local function Unwanted(leg)
    local options = snap.options
    for i = 1, snap.nDeclined do
        local d = snap.declined[i]
        if d.kind == leg.kind and (d.ref == 0 or d.ref == leg.ref) then return true end
    end
    return (leg.kind == "hearth" and not options.hearth) or (leg.kind == "spell" and not options.spells)
end
M.Unwanted = Unwanted
-- The row "option of the plan changed; Decline; Restore; rows surveyed". now: the player's own change, which
-- may make the trip slower, so the next plan replaces it, and at once.
local function PlanChanged(env, now)
    local state, trip, stale = snap.state, snap.trip, now or false
    if state == "failed" then Save(snap.dest) end
    if state == "planning" or state == "failed" then return M.Relocate(env) end
    if not trip or state == "dead" then return end
    for i = trip.at + 1, trip.n do stale = stale or Unwanted(trip.legs[i]) end
    if state == "walking" or state == "waiting" then return M.Replan(env, Unwanted(snap.leg), stale, now) end
    -- Riding or suspended: planned once the trip leads again; a stone that may no longer be used breaks it.
    M.stale, M.due = M.stale or stale, true
    if state == "suspended" and Unwanted(snap.leg) then snap.broken = true end
end
M.PlanChanged = PlanChanged
-- RESUME: back onto the trip when the player still stands on it, else a new plan from here.
function M.Resume(env)
    local trip, leg = snap.trip, snap.leg
    if trip and not snap.broken and env.landmass == leg.from.landmass then
        local on = Lead.Near(env, leg.from, M.BOARD_NEAR)
        if leg.kind == "walk" and leg.trail then
            ns.Trip.Advance(trip, env.x, env.y)
            on = trip.off <= M.OFF_YARDS
        end
        if on then return Lead.Enter(env) end
    end
    M.Relocate(env)
end

local function Find(kind, ref)
    for i = 1, snap.nDeclined do
        local d = snap.declined[i]
        if d.kind == kind and d.ref == ref then return i end
    end
end
local function Unlist(i)
    local list = snap.declined
    list[i], list[snap.nDeclined] = list[snap.nDeclined], list[i]
    snap.nDeclined = snap.nDeclined - 1
    Lead.Mark("notice")
end

-- The plan job's rows
-- The swap of 5.5.4: the proven trip of a job takes over from its first trip where the player is, when the
-- two agree up to the leg at hand. Returns that leg's number, or false.
local function Prefix(old, new)
    for i = 1, old.at do
        local a, b = old.legs[i], new.legs[i]
        if not (b and a.kind == b.kind and a.to.kind == b.to.kind and a.to.anchor == b.to.anchor
            and a.to.x == b.to.x and a.to.y == b.to.y) then return false end
    end
    return old.at
end
local function Better(new, old, env)
    ns.Trip.Retime(old, env.now, env.x, env.y, Lead.Cost())
    local gain = old.arrive - new.arrive
    return gain >= M.BETTER_SECONDS or (gain > 0 and gain >= M.BETTER_SHARE * (old.arrive - env.now))
end
OnPlan = function(what, value)
    local state, env, old = snap.state, Env.now, snap.trip
    local leading = state == "walking" or state == "waiting" or state == "riding"
    if what == "end" or what == "error" then
        Lead.Planned()
        if what == "error" and (leading or state == "planning") then Lead.Fail("error") end
        planned, fromFirst, shown = false, false, false     -- the job's trips are not kept past it
        Lead.Mark("notice")
    elseif not (leading or state == "planning") then
        return
    elseif what == "estimate" then
        if state == "planning" then
            snap.estimate = value
            Lead.Mark("tick")
        end
    elseif what == "first" then
        if not old or snap.broken then
            fromFirst, shown, M.stale = value, value, false
            Lead.Adopt(value, planned, env)
        end
    elseif what == "done" then
        Lead.hearth = false     -- worked out anew for the trip kept or taken (5.5.10 G14)
        local better = old and old ~= fromFirst and state ~= "riding" and (M.stale or Better(value, old, env))
        if not old or snap.broken or better then
            shown, M.stale = value, false
            Lead.Adopt(value, planned, env)
        elseif old == fromFirst then
            shown = value
            Lead.Adopt(value, planned, env, Prefix(old, value))
        elseif M.stale then M.due = true     -- riding: planned again once the trip leads on the ground
        end
    elseif what == "hearth" then
        Lead.hearth = value
        Lead.Mark("notice")
    elseif what == "none" then
        local i = old and autoTrip == old.id and Find(autoKind, 0)
        autoTrip = false
        if i and state == "waiting" then
            -- The ride walked away from was the only way: it is taken back, and the new trip leads to it.
            Unlist(i)
            M.Relocate(env)
        elseif state == "planning" or ((snap.broken or M.stale == true or old == fromFirst) and state ~= "riding") then
            if value == "lost" then M.Suspend(env, "lost") else Lead.Fail(value == "cap" and "error" or value) end
        elseif M.stale == "off" then M.stale = false     -- off the way and no way from there: the trip stays (5.5.6)
        end
    elseif shown and shown == snap.trip then
        if what == "unread" then
            local r = Lead.reports
            r.n = r.n + 1
            r[r.n] = value
        elseif what == "safer" then
            Lead.safer = value
        end
        Lead.Mark("notice")
    end
    Lead.Chores(env)
    Lead.Flush()
end
local function OnSurvey(what, job)
    if what ~= "rows" then return end
    Ledger.SetRows(job.key, ns.Ground.Caps(job.landmass).digest, job.level, job.rows, job.landmass, job.x, job.y)
    PlanChanged(Env.now)
    Lead.Flush()    -- the plan it starts cancels the survey, whose end would have published
end

-- What the player and the UI ask (5.5.1)
function M.Subscribe(fn) Lead.Subscribe(fn) end
function M.Snapshot() return snap end
-- A title of at most 60 characters, never cut inside one (UTF-8).
local SIXTY = "^[\128-\191]*" .. ("[^\128-\191][\128-\191]*"):rep(60)
function M.Title(text) return #text > 60 and text:match(SIXTY) or text end
-- A destination that cannot be reached is refused rather than replace one that can (FAIL shows it otherwise,
-- and for a pin trip whose pin the player moved).
local function Set(kind, ref, uiMap, mx, my, title, source, at, resume)
    if not M.ready then return false, "E_NOPLACE" end
    if SELF[source or "hand"] and not snap.options.planner then return false end
    local m, x, y
    uiMap, mx, my, m, x, y, ref = Request.Point(kind, ref or 0, uiMap, mx, my)
    if not uiMap then return false, mx end
    local old = snap.dest
    if type(title) ~= "string" or title == "" then title = Env.MapName(uiMap) or "?" end
    local dest = { kind = kind, uiMap = uiMap, mx = mx, my = my, landmass = m, x = x, y = y, ref = ref,
        title = M.Title(title), source = source or "hand", at = at or Env.Now(), resume = false,
        who = kind == "party" and Env.Party(ref) or false }
    if kind == "stop" or kind == "corpse" then     -- what a detour resumes; what the run to the body set aside
        dest.resume = old and (old.kind == kind and old.resume or old.kind ~= "corpse" and old) or resume or false
    end
    if old and snap.state ~= "failed" and not (kind == "pin" and old.kind == "pin") then
        local goal, why = Request.Goal(dest)
        if not goal and why ~= "busy" then
            Pin.offer = Pin.offer and kind ~= "pin"     -- the pin offered is refused: the offer goes
            Lead.Mark("notice")
            Lead.Flush()
            return false, "F_" .. why:upper()
        end
    end
    Lead.Cancel()
    Lead.Drop()
    Pin.End()
    snap.dest, snap.nDeclined, snap.estimate, Lead.landed = dest, 0, false, false
    Save(dest)
    Lead.Mark("state")
    M.Locate(Env.Read())
    Lead.Flush()
    return true
end
M.Go = Set     -- arguments 8 and 9 are for Facts' restoring only: when it was first given, what it resumes
M.Side, M.SideStop, M.Loop, M.LoopStop = ns.Side.Set, ns.Side.Clear, ns.Side.Loop, ns.Side.LoopStop  -- 5.5.15, 5.5.16
M.Arrow, M.ArrowStop = ns.Side.Arrow, ns.Side.ArrowStop     -- 5.5.17
function M.Stop(source)
    local dest = snap.dest
    if not dest or (source and source ~= "hand" and dest.source ~= source) then return false end
    planned, fromFirst, shown = false, false, false
    if source == "hand" and dest.kind ~= "corpse" then ns.Guide.Stopped() end
    if dest.kind == "corpse" then M.Died(false); M.Back() else Lead.Clear(false) end    -- led again at the next death
    Lead.Flush()
    return true
end
-- A slider sends every value of a drag: a minimum is planned once, for the value it ends on.
local sliding = false
local function Slid()
    sliding = false
    PlanChanged(Env.Read(), true)
    Lead.Flush()
end
function M.SetOption(key, value)
    if not (M.ready and Ledger.SetOption(key, value)) then return false end
    Lead.Mark("option")
    if SLIDERS[key] and not sliding then Env.After(0.3, Slid) end
    sliding = sliding or SLIDERS[key]
    if PLAN_KEYS[key] then PlanChanged(Env.Read(), true) end
    if key == "drivePin" and not value and Pin.driving then Pin.End() end
    if key == "corpseRun" and value then M.Corpse(Env.Read()) elseif key == "corpseRun" and Lead.Corpse() then M.Back() end
    -- The planner off ends a trip of Ferryman's own and gives back what it set aside where that is another addon's
    -- (Set refuses an own one), the option published first; on, a ghost is led to the body again.
    if key == "planner" and value then M.Corpse(Env.Read()) elseif key == "planner" and snap.dest and SELF[snap.dest.source] then Lead.Flush(); M.Back() end
    if key == "drivePin" and value and snap.trip then
        Pin.Adopt(snap.dest)
        Pin.Enter(snap.leg)
    end
    Lead.Flush()
    return true
end
function M.Without(env, kind, ref, now)
    if not snap.dest or Find(kind, ref or 0) then return end
    local n = snap.nDeclined + 1
    local d = snap.declined[n] or {}
    snap.declined[n], snap.nDeclined, d.kind, d.ref = d, n, kind, ref or 0
    autoKind, autoTrip = kind, not now and snap.trip and snap.trip.id
    Lead.Mark("notice")
    PlanChanged(env, now)
end
function M.Decline(kind, ref)
    M.Without(Env.Read(), kind, ref, true)
    Lead.Flush()
end
function M.Restore(kind, ref)
    local i = Find(kind, ref or 0)
    if not i then return end
    Unlist(i)
    PlanChanged(Env.Read(), true)
    Lead.Flush()
end
-- On to the destination a detour resumes; when it is gone (a pin taken away), the trip ends. The player's own
-- pin is put back before it is read; a member is found by name, else is where last seen (ref 0), as the tick does.
function M.Resumed()
    local r = snap.dest.resume
    Pin.End()
    if r.who and Env.Party(r.ref) ~= r.who then
        r.ref = 4
        while r.ref > 0 and Env.Party(r.ref) ~= r.who do r.ref = r.ref - 1 end
    end
    if not Set(r.kind, r.ref, r.uiMap, r.mx, r.my, r.title, r.source, nil, r.resume) then Lead.Clear(false) end
end
-- The run back to the body (5.5.14): a ghost is led there by itself, and what led before waits until alive (Back).
M.diedIn = 0    -- the instance map the player died in, else 0; false: the player ended the run, until the next death
function M.Died(map) M.diedIn = map; Ledger.DiedIn(map ~= 0 and map) end     -- saved: a reload as a ghost keeps it (C14)
function M.Ended() M.Died(false) M.Dead() end     -- at the entrance's place: past it nothing leads, a reload too
function M.Corpse(env)
    if not (M.ready and M.diedIn and env.ghost and not env.instance and snap.options.corpseRun and snap.options.planner)
        or Lead.Corpse() and snap.state ~= "failed" then return end
    Set("corpse", M.diedIn, nil, nil, nil, nil, "corpse")
end
function M.Back() if snap.dest.resume then M.Resumed() else Lead.Clear(false) end end
function M.Act(action)
    local r = Lead.reports[1]
    if action == "pin" then
        return Set("pin", 0, nil, nil, nil, nil, "pin")
    elseif action == "goFirst" and r and r.stop > 0 then
        return Set("stop", r.stop, nil, nil, nil, Env.PlaceName({ kind = "stop", anchor = r.stop }), "hand")
    elseif action == "stop" then
        return M.Stop("hand")
    end
end
function M.Entrances(out)
    local env = Env.Read()
    local n = M.ready and Request.Entrances(out, env) or 0
    Lead.Chores(env)
    return n
end
-- The walking data where the player stands when the loading screen did not load it (Senses), loaded in a frame
-- that is long already (the world map opening, the "Where to?" menu being built), never in combat.
function M.Prepare()
    local m = M.ready and not (Env.now.combat or Lead.snap.combat) and Env.Position()
    if m then Env.LoadGround(m) end
end
function M.Bench(report)
    if M.ready then Request.Bench(report) end
    Lead.Chores(Env.Read())
end
function M.Login(env)
    local Net, ok, err = ns.Net, ns.Net.Load(ns.Network, ns.NetworkShapes, ns.Measured)
    if not ok then return geterrorhandler()(err) end
    local _, err = ns.Ground.Attach(ns.WalkData, Net.A, Net.build, Net.UseDrops())
    if err then geterrorhandler()(err) end
    local guid, realm, faction = Env.Character()
    Ledger.Login(guid, realm, faction, Env.Build())
    local d = Ledger.DiedIn()       -- a dead character's instance, else nothing, and anything else goes (C14)
    M.Died(env.dead and type(d) == "number" and Net.EntranceOfMap(d) and d or 0)
    ns.Seen.Load()
    snap.options, snap.combat, M.ready = Ledger.Options(), env.combat, true
    ns.Work.SetCombat(env.combat)
    Pin.Seen()
    ns.Guide.Login()
    Lead.Mark("option")
end

-- A fact's row (Facts) in the present state.
function M.Row(fact, env, a, b)
    local row = ns.Facts[fact]
    local fn = row and row[snap.state]
    if fn then fn(env, a, b) end
end
-- The sink given to Senses. Every fact goes to the Ledger first, with the position read at that moment.
function M.Fact(fact, a, b)
    local inTick, state, trip = ns.Tick.running, snap.state, snap.trip
    local env = inTick and Env.now or Env.Read()
    if fact == "loadStart" then M.loading = true end
    Ledger.Note(fact, env, a, b)
    ns.Side.Fact(fact, a)
    ns.Marks.Fact(fact)
    if fact == "landed" or fact == "dropped" then ns.Tick.Fly(env) end      -- the timer goes before the row can end the trip
    M.Row(fact, env, a, b)
    if fact == "tookOff" or fact == "carried" then ns.Tick.Fly(env, false, fact == "carried" and a, b) end
    if inTick then return end
    -- a jump this read took from the tick, where the row left the state as it was
    if env.jump and snap.state == state and snap.trip == trip and fact ~= "zone" and fact ~= "moved" then ns.Tick.Rows(env) end
    if env.moved > 0.5 and not env.taxi then Lead.Fast(true) end
    M.was.ok, M.was.landmass, M.was.x, M.was.y = env.ok, env.landmass, env.x, env.y
    Lead.Chores(env)
    Lead.Flush()
end
M.was = { ok = false, landmass = 0, x = 0, y = 0 }    -- the position of the previous read

Lead.Need(function()
    local job = Request.SurveyJob()
    return job and Lead.Chore("survey", Request.RunSurvey, job, OnSurvey)
end)
Lead.Need(Request.Estimate)
Lead.Need(Request.BenchJob)
ns.Senses.Start(M.Fact)
