local ADDON, ns = ...

-- The side trail (INTERFACES 5.5.15): a walk from the player to one nearby point another addon hands over, drawn
-- beside the trip and never part of it. Its record is the snapshot's side (3.10); its walk is a chore (5.5.3).
local M = {}
ns.Side = M

M.REACH, M.FAR, M.STRAY, M.AGAIN, M.GAIN, M.HOLD, M.WALK, M.STALE = 300, 400, 15, 2, 2, 10, 3, 600

local sqrt, min, max, huge = math.sqrt, math.min, math.max, math.huge
local Env, Lead, Request = ns.Env, ns.Lead, ns.Request
local snap = Lead.snap
local walk = { kind = "walk", trail = false, i = 1 }
-- The session's one record: the one-leg stand-in of a trip that Trip.Advance follows.
local side = { source = "", uiMap = 0, mx = 0, my = 0, landmass = 0, x = 0, y = 0, rev = 0, walk = walk, at = 1, n = 1,
    legs = { walk }, foot = 0, off = 0, ahead = 0, bendX = 0, bendY = 0, bendLast = false, held = false }
-- The list shown and the one a job writes: they swap on delivery, so a cancelled job never leaves a half-written one.
local shown, spare = { n = 0, x = {}, y = {}, z = {}, far = {} }, { n = 0, x = {}, y = {}, z = {}, far = {} }
local point = { kind = "point", ref = 0, source = "", landmass = 0, x = 0, y = 0, uiMap = 0 }
local cost = { vLand = 7, vInside = 7, vSwim = 4.72, factor = 1, faction = 1, level = 1 }
local gen, want, askedAt, setAt, least, gained = 0, false, 0, 0, false, false     -- least: the foot at the last gain
local holdTo, holdM, atM, atX, atY, atT = 0, false, false, 0, 0, 0    -- after an arrival: the hold's end; where and when

local function Seen()
    local o = snap.options
    return o.miniTrail or o.mapTrail or false
end

-- Arrived: at its point, the trip's rules wait while the player stays there, HOLD seconds at most. finishing: the side
-- job's own delivery, whose end asks the needs and publishes; any other end cancels that job, once nothing of the
-- record would start it again, and leaves the needs to the fact, tick or call that ended it, after its own rows.
local function End(arrived, finishing)
    if not snap.side then return end
    local now = Env.now.now
    want, walk.trail, side.held, least, gained, gen = false, false, false, false, false, gen + 1
    snap.side, side.rev = false, side.rev + 1
    holdTo = arrived and Seen() and now + M.HOLD or 0
    if holdTo > 0 then holdM, atM, atX, atY, atT = side.landmass, side.landmass, side.x, side.y, now end
    Lead.Mark("tick")
    if snap.state == "idle" and not Lead.watching then Lead.Watch(false) end
    if not finishing then Lead.Quit(M.OnSide, true) end
end
M.End = End
-- An arrival's hold lasts while the player stays within STRAY yards of its point, gathering; leaving it ends it.
local function Stay(env)
    if holdTo > 0 and not (env.ok and env.landmass == holdM
        and (env.x - atX) ^ 2 + (env.y - atY) ^ 2 <= M.STRAY * M.STRAY) then holdTo = 0 end
end

-- The trip's off-the-way count and declined step wait while the player gains on a side trail (5.5.6).
function M.Held(now) return snap.side and side.held or now < holdTo end
-- The yards a wait counts the player gone: none past the decline while held; after an arrival in this wait, from
-- the straight way between the wait's place and the arrival's, until the player is back within the decline of the
-- wait's: walking back is no decline, a stray past the point or to one side still is.
function M.Gone(env, gone)
    local decline, w = ns.Driver.DECLINE_YARDS, Lead.wait
    if env.ok and gone <= decline then atM = false end
    if gone < huge and M.Held(env.now) then return min(gone, decline) end
    if atM and env.ok and atM == env.landmass and atM == w.landmass and atT >= w.at then
        local vx, vy, px, py = atX - w.x, atY - w.y, env.x - w.x, env.y - w.y
        local l2 = vx * vx + vy * vy
        local u = l2 > 0 and max(0, min(1, (px * vx + py * vy) / l2)) or 0
        return min(gone, sqrt((px - u * vx) ^ 2 + (py - u * vy) ^ 2))
    end
    return gone
end

-- The walk, one job: the looks with its pause, the ground's walk at the base speeds within the limit, then as the
-- ground walks it. Nothing is drawn before; no walk ends the side trail.
local function Run(job, pause, emit)
    local G, wp, m = ns.Ground, job.wp, job.m
    Request.pause = pause
    local start = Request.Start(job.env)
    local goal = start and start.landmass == m and start.n > 0 and Request.Goal(point)
    Request.pause = false
    local found = goal and goal.n > 0
        and G.Route(m, start.x, start.y, start, point.x, point.y, goal, cost, wp, pause, M.WALK * M.REACH / ns.Net.BASE_RUN) ~= nil
    if found and wp.raw then G.Detail(m, wp, nil, pause) end
    emit("trail", found or false)
end
function M.OnSide(what, found, job)
    if what ~= "trail" or job.gen ~= gen then return end
    if not found then return End(false, true) end
    -- the walk's whole length until a read follows it; its gains marked afresh, a walk again from here being longer
    walk.trail, walk.i, spare, shown, side.foot = job.wp, 1, shown, job.wp, job.wp.far[job.wp.n]
    want, askedAt, side.rev, least = false, Env.now.now, side.rev + 1, false
    local env = Env.now
    -- a walk no longer than the arrival's reach ends as it comes
    if env.ok and env.landmass == side.landmass and ns.Trip.Advance(side, env.x, env.y) == 2 then return End(true, true) end
    Lead.Mark("tick")
end
Lead.Need(function(env)
    if not (snap.side and want) or ns.Driver.loading then return false end
    return Lead.Chore("side", Run, { env = env, gen = gen, wp = spare, m = side.landmass }, M.OnSide)
end)

-- The tick's row, on the tick's read: no Ground call, nothing allocated. A gain is the foot point's way left falling
-- GAIN yards below where it stood at the last one; the first reading only marks it.
local function Follow(env)
    local dx, dy = env.x - side.x, env.y - side.y
    if Request.Away(env) or env.dead or ns.Driver.loading or env.landmass ~= side.landmass
        or dx * dx + dy * dy > M.FAR * M.FAR or env.now - (gained or setAt) >= M.STALE then return End() end
    if not walk.trail then return end
    if ns.Trip.Advance(side, env.x, env.y) == 2 then return End(true) end
    if not least then least = side.foot
    elseif side.foot <= least - M.GAIN then least, gained = side.foot, env.now end
    side.held = gained and env.now - gained <= M.HOLD and Seen() or false
    if side.off > M.STRAY and not want and env.now - askedAt >= M.AGAIN then want, askedAt = true, env.now end
    Lead.Mark("tick")
end
-- A fault here ends the side trail and never the trip's tick.
function M.Tick(env)
    Stay(env)
    if not snap.side then return end
    local ok, err = pcall(Follow, env)
    if not ok then
        geterrorhandler()(err)
        End()
    end
end
local ENDS = { loadStart = true, tookOff = true, carried = true, died = true }
function M.Fact(fact, on)
    -- A zoom lays the loop's dots on the minimap again; a loading screen's end finds whether they and the arrow can
    -- show where the player came out.
    local dots, o = snap.loop and snap.options.miniTrail, snap.options
    if fact == "minimap" and dots or fact == "loadEnd" and (dots or snap.arrow and o.arrow) then Lead.Mark("tick") end
    if not snap.side then return end
    if ENDS[fact] then return End() end
    if fact == "minimap" then Lead.Mark("tick") elseif fact == "moved" and on then Lead.Fast(true) end
end

-- Driver.Side: true, or false and why. Every refusal is judged before what stands is replaced; the same source's
-- point within a yard of the one that stands is the same call.
function M.Set(uiMap, mx, my, source)
    local Driver = ns.Driver
    if not Driver.ready then return false, "E_NOPLACE" end
    local m, x, y
    uiMap, mx, my, m, x, y = Request.Point("point", 0, uiMap, mx, my)
    if not uiMap then return false, mx end
    if snap.side and side.source == source and m == side.landmass and (x - side.x) ^ 2 + (y - side.y) ^ 2 <= 1 then
        side.uiMap, side.mx, side.my = uiMap, mx, my
        return true
    end
    local env = Env.Read()
    if env.jump and snap.trip then ns.Tick.Rows(env) end      -- the jump this read took from the tick
    Stay(env)
    local dx, dy = env.x - x, env.y - y
    local why = (Request.Away(env) or env.dead or Driver.loading or env.landmass ~= m
        or dx * dx + dy * dy > M.REACH * M.REACH) and "away" or not ns.Ground.Has(m) and "nodata"
    if not why then
        local Net = ns.Net
        side.source, side.uiMap, side.mx, side.my, side.landmass, side.x, side.y = source, uiMap, mx, my, m, x, y
        walk.trail, walk.i, side.held, side.rev, snap.side = false, 1, false, side.rev + 1, side
        point.landmass, point.x, point.y, point.uiMap = m, x, y, uiMap
        cost.vLand, cost.vInside, cost.vSwim = Net.BASE_RUN, Net.BASE_RUN, Net.BASE_SWIM
        cost.faction, cost.level = select(3, Env.Character())
        want, askedAt, setAt, least, gained, gen = true, env.now, env.now, false, false, gen + 1
        Lead.Watch(Lead.watching)
        Lead.Quit(M.OnSide, true)     -- the walk of a point replaced
        Lead.Chores(env)
        Lead.Mark("tick")
    end
    Lead.Flush()
    if why then return false, why end
    return true
end
-- Driver.SideStop: only the side trail of that source.
function M.Clear(source)
    if not (snap.side and side.source == source) then return false end
    End()
    Lead.Chores(Env.now)
    Lead.Flush()
    return true
end

-- The loop (5.5.16): one closed way another addon hands over, drawn whole on the world map and the minimap and never
-- followed; no end of the side trail or the trip reaches it. Its record is the snapshot's loop (3.10), its points in
-- yards its own.
local loop = { source = "", uiMap = 0, landmass = 0, n = 0, x = {}, y = {}, rev = 0 }
local function Publish(record, key, on)
    record.rev, snap[key] = record.rev + 1, on and record
    Lead.Mark("tick")
    Lead.Flush()
end
-- Driver.Loop: true, or false and why. pts holds the fractions x1, y1, x2, y2, ... of uiMap, as Public judged them;
-- the map's rectangle turns them into yards by arithmetic.
function M.Loop(uiMap, pts, source)
    if not ns.Driver.ready then return false, "E_NOPLACE" end
    local m, top, left, bottom, right = Env.MapRect(uiMap)
    if not m then return false, "E_NOWORLD" end
    local x, y, n = loop.x, loop.y, #pts / 2
    for i = 1, n do x[i], y[i] = top + (bottom - top) * pts[2 * i], left + (right - left) * pts[2 * i - 1] end
    for i = n + 1, loop.n do x[i], y[i] = nil, nil end
    loop.source, loop.uiMap, loop.landmass, loop.n = source, uiMap, m, n
    Publish(loop, "loop", true)
    return true
end
-- Driver.LoopStop: only the loop of that source; its arrays go with it.
function M.LoopStop(source)
    if not (snap.loop and loop.source == source) then return false end
    loop.n, loop.x, loop.y = 0, {}, {}
    Publish(loop, "loop", false)
    return true
end

-- The arrow (5.5.17): one point another addon hands over for Ferryman's arrow to aim at, straight from the player,
-- while no trip leads. Nothing follows it, and no end of the side trail, the loop or the trip reaches it. Its record
-- is the snapshot's arrow (3.10).
local arrow = { source = "", uiMap = 0, mx = 0, my = 0, landmass = 0, x = 0, y = 0, rev = 0 }
-- Driver.Arrow: true, or false and why. An accepted point replaces the one that stands, whoever set it.
function M.Arrow(uiMap, mx, my, source)
    if not ns.Driver.ready then return false, "E_NOPLACE" end
    local m, x, y
    uiMap, mx, my, m, x, y = Request.Point("point", 0, uiMap, mx, my)
    if not uiMap then return false, mx end
    arrow.source, arrow.uiMap, arrow.mx, arrow.my, arrow.landmass, arrow.x, arrow.y = source, uiMap, mx, my, m, x, y
    Publish(arrow, "arrow", true)
    return true
end
-- Driver.ArrowStop: only the arrow of that source.
function M.ArrowStop(source)
    if not (snap.arrow and arrow.source == source) then return false end
    Publish(arrow, "arrow", false)
    return true
end
