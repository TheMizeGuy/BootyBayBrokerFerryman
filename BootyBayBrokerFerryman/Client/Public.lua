local ADDON, ns = ...

-- The global table other addons call (DESIGN section 9, INTERFACES 5.6): sixteen functions, every argument checked,
-- calls applied once a frame, a trip the player set never replaced, Lookup's answers where a trainer or a creature
-- stands, and Marks' places drawn on the maps.
local M = {}
ns.Public = M

local Env, Driver, Lookup, Marks = ns.Env, ns.Driver, ns.Lookup, ns.Marks
local OWN = { hand = true, pin = true, restore = true, corpse = true }     -- the player's, and the run to their body
local TAKEN = { hand = true, pin = true, restore = true, corpse = true, guide = true }     -- and RestedXP's, followed
local LEADING = { walking = true, waiting = true, riding = true }
local pending, queued, listeners = false, false, {}
local last = {}         -- per source, the last call the Driver took: the same one again changes nothing
local trip, lastDest, lastId, lastState, lastAt = nil, false, 0, "idle", 0
-- The side trail's own (5.5.15): the set and the stop waiting for the next frame, and per source the last call taken.
local sideCall, sideStop, sideQueued, sideLast, WHOLE = false, false, false, {}, 2 ^ 31 - 1
-- The loop's (5.5.16), on the same timer: its call and stop waiting, per source the last call taken, the one standing.
local loopCall, loopStop, loopLast, loopOn = false, false, {}, false
-- The arrow's (5.5.17), on the same timer: its call and stop waiting; the call's record, written again each time, and
-- a second that takes its turn when a frame's calls are applied, so a call made while they are is never the one read.
local arrowCall, arrowStop = false, false
local arrowWait, arrowSpare = { uiMap = 0, x = 0, y = 0, source = "" }, { uiMap = 0, x = 0, y = 0, source = "" }

-- A secret value raises at a compare, a sum or as a key: a call holding one is refused before any of it is read.
local Secret = issecretvalue or function() return false end
local function Hidden(a, b, c, d, e) return Secret(a) or Secret(b) or Secret(c) or Secret(d) or Secret(e) end

local function Frozen(t)
    return setmetatable({}, { __index = t, __metatable = false,
        __newindex = function() error("Ferryman: read-only", 2) end })
end
local function Mine()
    local dest = Driver.Snapshot().dest
    return dest and OWN[dest.source] or false
end

local function Same(a, uiMap, x, y, title)
    return a and a.uiMap == uiMap and a.x == x and a.y == y and a.title == title
end
-- The last call of a frame is the one applied; the player's own trip is checked again at that moment.
local function Apply()
    local call = pending
    pending, queued = false, false
    if call.stop then
        last[call.source] = nil
        Driver.Stop(call.source)
    elseif not Mine() and not Same(last[call.source], call.uiMap, call.x, call.y, call.title) then
        local held = Driver.Snapshot().dest and Driver.Snapshot().dest.source     -- another source's trip replaced: its
        local ok, why = Driver.Go("point", 0, call.uiMap, call.x, call.y, call.title, call.source)
        if ok and held and held ~= call.source then last[held] = nil end           -- next Go is a fresh request (141)
        if ok or why ~= "E_NOPLACE" then last[call.source] = call end
    end
end
local function Queue(call)
    pending = call
    if not queued then
        queued = true
        Env.After(0, Apply)
    end
end

local function Go(uiMapID, x, y, title, source)
    if Hidden(uiMapID, x, y, title, source) then return false end
    local numbers = type(x) == "number" and type(y) == "number" and x >= 0 and x <= 1 and y >= 0 and y <= 1
    if not numbers or type(uiMapID) ~= "number" then return false end
    if title ~= nil and type(title) ~= "string" then return false end
    if type(source) ~= "string" or source == "" or #source > 32 or TAKEN[source] then return false end
    title = title ~= "" and title and Driver.Title(title) or nil
    if Mine() then return false end
    -- The same call again (an addon that asks every frame, or after its trip ended) is the trip it had.
    if not (pending and pending.source == source) and Same(last[source], uiMapID, x, y, title) then return true end
    if not C_Map.GetMapInfo(uiMapID) or not Env.MapToWorld(uiMapID, x, y) then return false end
    Queue({ uiMap = uiMapID, x = x, y = y, title = title, source = source })
    return true
end
local function Stop(source)
    if Secret(source) then return false end
    local dest = Driver.Snapshot().dest
    local theirs = (dest and dest.source == source) or (pending and not pending.stop and pending.source == source)
        or last[source]
    if type(source) ~= "string" or TAKEN[source] or not theirs then return false end
    Queue({ stop = true, source = source })
    return true
end

-- A map a whole number from 1 to 2^31 - 1, and a source another addon may give: judged before any client call.
local function Theirs(uiMapID, source)
    return type(uiMapID) == "number" and uiMapID >= 1 and uiMapID <= WHOLE and uiMapID % 1 == 0
        and type(source) == "string" and source ~= "" and #source <= 32 and not TAKEN[source]
end
-- A loop's points: a plain array of 6 to 4,000 numbers from 0 to 1, an even count and no hole, read raw; one that
-- raises (a secret value in it) is refused.
local function Judge(p)
    local n, count = type(p) == "table" and #p or 0, 0
    if n < 6 or n > 4000 or n % 2 == 1 then return false end
    for k, v in pairs(p) do
        count = count + 1
        if not (type(k) == "number" and k % 1 == 0 and k >= 1 and k <= n and type(v) == "number" and v >= 0
            and v <= 1) then return false end
    end
    return count == n
end
local function Points(p) local ok, good = pcall(Judge, p); return ok and good end

-- The stops waiting are applied before a set of the same frame, and a side trail's before a loop's: SideStop and Side
-- together try that call again. Each is applied on its own: one that raises is reported and the rest still are.
local function LoopStop(source) if Driver.LoopStop(source) then loopOn = false end end
local function SideSet(call)
    if Same(sideLast[call.source], call.uiMap, call.x, call.y) then return end
    local ok, why = Driver.Side(call.uiMap, call.x, call.y, call.source)
    call.nodata = why == "nodata"
    if ok or why ~= "E_NOPLACE" then sideLast[call.source] = call end
end
local function LoopSet(call)
    if not Points(call.points) then return end      -- judged again: its caller may have changed it since
    local ok, why = Driver.Loop(call.uiMap, call.points, call.source)
    if ok then loopOn = call end
    if ok or why ~= "E_NOPLACE" then loopLast[call.source] = call end
end
-- The arrow's, last: a set replaces what stands, so its frame's stop is applied only where no set is taken, and the
-- arrow is never off between the two.
local function ArrowApply(stop, call)
    if not (call and Driver.Arrow(call.uiMap, call.x, call.y, call.source)) and stop then Driver.ArrowStop(stop) end
end
local function Guard(fn, a, b) local ok, err = pcall(fn, a, b); if not ok then geterrorhandler()(err) end end
local function SideApply()
    local stop, call, lstop, lcall, astop, acall = sideStop, sideCall, loopStop, loopCall, arrowStop, arrowCall
    sideStop, sideCall, loopStop, loopCall, arrowStop, arrowCall, sideQueued = false, false, false, false, false, false, false
    if acall then arrowWait, arrowSpare = arrowSpare, arrowWait end
    if stop then Guard(Driver.SideStop, stop) end
    if lstop then Guard(LoopStop, lstop) end
    if call then Guard(SideSet, call) end
    if lcall then Guard(LoopSet, lcall) end
    if astop or acall then Guard(ArrowApply, astop, acall) end
end
local function SideQueue() if not sideQueued then sideQueued = true; Env.After(0, SideApply) end end
local function Side(uiMapID, x, y, source)
    if Hidden(uiMapID, x, y, source) then return false end
    local numbers = type(x) == "number" and type(y) == "number" and x >= 0 and x <= 1 and y >= 0 and y <= 1
    if not (numbers and Theirs(uiMapID, source)) then return false end
    -- The same call again costs nothing, drops a call of that source waiting and tells whether its side trail still
    -- stands; one refused for no walking data is tried again once its landmass has some.
    local l = sideLast[source]
    if l and l.nodata and ns.Ground.Has(l.m) then sideLast[source], l = nil, nil end
    if Same(l, uiMapID, x, y) then
        if sideCall and sideCall.source == source then sideCall = false end
        local s = Driver.Snapshot().side
        return s and s.source == source and s.uiMap == uiMapID and s.mx == x and s.my == y or false
    end
    local m = C_Map.GetMapInfo(uiMapID) and Env.MapToWorld(uiMapID, x, y)
    if not m then return false end
    sideCall = { uiMap = uiMapID, x = x, y = y, source = source, m = m, nodata = false }
    SideQueue()
    return true
end
-- That source's side trail and its arrow, standing or waiting; loop true: its loop too, standing, waiting or
-- remembered.
local function SideStop(source, loop)
    if Hidden(source, loop) or type(source) ~= "string" or TAKEN[source] then return false end
    local snap, mine = Driver.Snapshot(), sideCall and sideCall.source == source
    local stands = snap.side and snap.side.source == source
    local aims, points = arrowCall and arrowCall.source == source, snap.arrow and snap.arrow.source == source
    local found = stands or mine or sideLast[source] or aims or points
    sideLast[source] = nil
    if mine then sideCall = false end
    if stands then sideStop = source; SideQueue() end
    if aims then arrowCall = false end
    if points then arrowStop = source; SideQueue() end
    if loop == true then
        local waits, held = loopCall and loopCall.source == source, snap.loop and snap.loop.source == source
        found = found or waits or held or loopLast[source]
        loopLast[source] = nil
        if waits then loopCall = false end
        if held then loopStop = source; SideQueue() end
    end
    return found and true or false
end
-- One closed way of that map's fractions x1, y1, x2, y2, ..., the last point joined to the first.
local function SideLoop(uiMapID, points, source)
    if Hidden(uiMapID, points, source) or not (Theirs(uiMapID, source) and type(points) == "table") then return false end
    -- The same call again (that source, map and table) costs nothing: as the call waiting, true; as the one taken,
    -- it drops another of that source waiting and tells whether its loop still stands.
    local w, l = loopCall and loopCall.source == source and loopCall, loopLast[source]
    if w and w.uiMap == uiMapID and w.points == points then return true end
    if l and l.uiMap == uiMapID and l.points == points then
        if w then loopCall = false end
        return Driver.Snapshot().loop and loopOn == l or false
    end
    if not (Driver.ready and Points(points) and C_Map.GetMapInfo(uiMapID) and Env.MapRect(uiMapID)) then return false end
    loopCall = { uiMap = uiMapID, points = points, source = source }
    SideQueue()
    return true
end
-- Ferryman's arrow aimed straight at that map position while no trip leads; the three all nil: that source's arrow
-- taken away. The same call again, as the one waiting or the one that stands, costs nothing.
local function SideArrow(uiMapID, x, y, source)
    if Hidden(uiMapID, x, y, source) or type(source) ~= "string" or source == "" or #source > 32 or TAKEN[source] then return false end
    local a = Driver.Snapshot().arrow
    local stands, w = a and a.source == source, arrowCall and arrowCall.source == source and arrowCall
    if uiMapID == nil and x == nil and y == nil then
        if w then arrowCall = false end
        if stands then arrowStop = source; SideQueue() end
        return (stands or w) and true or false
    end
    local numbers = type(x) == "number" and type(y) == "number" and x >= 0 and x <= 1 and y >= 0 and y <= 1
    if not (numbers and Theirs(uiMapID, source)) then return false end
    if w and w.uiMap == uiMapID and w.x == x and w.y == y then return true end
    -- Its own standing point again: the frame's last call, so a call of any source waiting is dropped.
    if stands and arrowStop ~= source and a.uiMap == uiMapID and a.mx == x and a.my == y then
        arrowCall = false
        return true
    end
    if not (Driver.ready and C_Map.GetMapInfo(uiMapID) and Env.MapToWorld(uiMapID, x, y)) then return false end
    arrowWait.uiMap, arrowWait.x, arrowWait.y, arrowWait.source, arrowCall = uiMapID, x, y, source, arrowWait
    SideQueue()
    return true
end
local function SideSource()
    local snap = Driver.Snapshot()
    return snap.side and snap.side.source or nil, snap.loop and snap.loop.source or nil,
        snap.arrow and snap.arrow.source or nil
end

local function Planner() return Driver.ready and Driver.Snapshot().options.planner == true end
local function SetPlanner(on)
    if Secret(on) or type(on) ~= "boolean" or not Driver.ready then return false end
    return Driver.Snapshot().options.planner == on or Driver.SetOption("planner", on)
end

-- The digest of the walking data this Ferryman ships for landmass 0 or 1 (Data/WalkingDigest.lua, written with the
-- companions), whether or not the companion is loaded; nil for any other argument.
local function WalkingDigest(landmass)
    if Secret(landmass) or (landmass ~= 0 and landmass ~= 1) then return nil end
    return ns.WalkingDigest[landmass]
end

local function OnChange(fn)
    if type(fn) ~= "function" then return false end
    listeners[#listeners + 1] = fn
    return true
end

-- The public trip: a frozen copy, made anew when the destination, the trip, the state or the step changes.
local function Copy(snap)
    local dest, t, steps = snap.dest, snap.trip, {}
    for i = 1, t and t.n or 0 do
        local leg = t.legs[i]
        steps[i] = Frozen({ kind = leg.kind, seconds = leg.wait + leg.seconds, name = leg.toName })
    end
    return Frozen({ title = dest.title, source = dest.source, uiMapID = dest.uiMap, x = dest.mx, y = dest.my,
        state = snap.state, arrival = t and LEADING[snap.state] and t.arrive or nil, step = t and t.at or 0,
        steps = steps })
end
function M.OnChange(snap)
    local t = snap.trip
    local id, at = t and t.id or 0, t and t.at or 0
    if snap.dest == lastDest and id == lastId and snap.state == lastState and at == lastAt then return end
    lastDest, lastId, lastState, lastAt = snap.dest, id, snap.state, at
    trip = snap.state ~= "idle" and Copy(snap) or nil
    for i = 1, #listeners do
        local ok, err = pcall(listeners[i])
        if not ok then geterrorhandler()(err) end
    end
end

-- The one entry point of the walking-data companions (INTERFACES 16.7): a landmass's first table is taken, however
-- its companion was loaded; Ground.Load judges it.
ns.WalkData = {}
local function WalkData(m, t)
    if (m == 0 or m == 1) and type(t) == "table" and ns.WalkData[m] == nil then ns.WalkData[m] = t end
end
Ferryman = Frozen({ Go = Go, Stop = Stop, OnChange = OnChange, Trip = function() return trip end, WalkData = WalkData,
    Side = Side, SideStop = SideStop, SideLoop = SideLoop, SideSource = SideSource, SideArrow = SideArrow,
    Trainer = Lookup.Trainer, Creature = Lookup.Creature, Marks = Marks.Set, MarksStop = Marks.Stop, Planner = Planner,
    SetPlanner = SetPlanner, WalkingDigest = WalkingDigest })
Driver.Subscribe(M.OnChange)