local ADDON, ns = ...

local M = {}
ns.MapPath = M

M.DOCK_REACH = 500

local ceil, sqrt, abs = math.ceil, math.sqrt, math.abs

-- The trip as polylines in canvas units, in flat arrays reused by every build: point i at x[i], y[i]; polyline
-- p from point first[p] to point last[p], of the leg kind kind[p]; n polylines, then the side trail's, of kind
-- "side", up to polyline m.
local px, py, pStart, pEnd, pKind, nPts, nPoly, tripPts = {}, {}, {}, {}, {}, 0, 0, 0
M.x, M.y, M.first, M.last, M.kind, M.n, M.m = px, py, pStart, pEnd, pKind, 0, 0
local shape = { map = {}, first = {}, count = {}, x = {}, y = {} }
local curMap, rLand, rTop, rLeft, rBottom, rRight, cw, ch = 0, false, 0, 0, 0, 0, 0, 0

-- The client's UiMapAssignment: a map with a rectangle shows that one landmass; the one without (Azeroth) shows
-- each landmass as a rectangle of its own, which three conversions 1,000 yd apart give once (else: point by point).
local fits = {}
local function Fit(landmass, x, y)
    local per = fits[curMap] or {}
    fits[curMap] = per
    if per[landmass] ~= nil then return per[landmass] end
    local W = ns.Env.WorldToMap
    local u, v = W(curMap, landmass, x, y)
    if not u then return nil end
    local dx, dy = v < 0.5 and -1000 or 1000, u < 0.5 and -1000 or 1000
    local u2, v2 = W(curMap, landmass, x + dx, y + dy)
    local u3, v3 = W(curMap, landmass, x + dx, y)
    local b, d = u2 and (u2 - u) / dy, v2 and (v2 - v) / dx
    per[landmass] = u2 and u3 and b ~= 0 and d ~= 0 and abs(u3 - u) < 1e-6 and abs(v3 - v2) < 1e-6
        and { u - b * y, b, v - d * x, d } or false
    return per[landmass]
end

-- Whether the shown map places the points of landmass by arithmetic: by its rectangle, or by the one Fit gives from
-- the point (x, y). A miss is remembered for the map and landmass, so asking again calls nothing.
local missed = {}
function M.Arith(landmass, x, y)
    if rLand then return rLand == landmass end
    local per, miss = fits[curMap], missed[curMap]
    if per and per[landmass] ~= nil then return per[landmass] ~= false end
    if miss and miss[landmass] then return false end
    if Fit(landmass, x, y) then return true end
    if fits[curMap][landmass] == nil then
        miss = miss or {}
        missed[curMap], miss[landmass] = miss, true
    end
    return false
end

local function ToCanvas(landmass, x, y)
    local mx, my
    if landmass == rLand then
        mx, my = (rLeft - y) / (rLeft - rRight), (rTop - x) / (rTop - rBottom)
    elseif rLand then
        return nil
    else
        local f = Fit(landmass, x, y)
        if f then
            mx, my = f[1] + f[2] * y, f[3] + f[4] * x
            if mx < 0 or mx > 1 or my < 0 or my > 1 then return nil end
        elseif f == false then
            mx, my = ns.Env.WorldToMap(curMap, landmass, x, y)
        end
        if not mx then return nil end
    end
    return mx * cw, my * ch
end
M.ToCanvas = ToCanvas

local function Begin(kind)
    nPoly = nPoly + 1
    pStart[nPoly], pEnd[nPoly], pKind[nPoly] = nPts + 1, nPts, kind
end

local function Close()
    if nPoly == 0 then return end
    pEnd[nPoly] = nPts
    if nPts - pStart[nPoly] < 1 then
        nPts, nPoly = pStart[nPoly] - 1, nPoly - 1
    end
end

-- A point the shown map cannot place breaks the polyline.
local function Add(landmass, x, y)
    local cx, cy = ToCanvas(landmass, x, y)
    if not cx then
        local kind = pKind[nPoly]
        Close()
        Begin(kind)
        return
    end
    nPts = nPts + 1
    px[nPts], py[nPts] = cx, cy
end

local function Pair(kind, la, xa, ya, lb, xb, yb)
    if la == lb and xa == xb and ya == yb then return end
    Begin(kind)
    Add(la, xa, ya)
    Add(lb, xb, yb)
    Close()
end

local function Straight(kind, a, b) Pair(kind, a.landmass, a.x, a.y, b.landmass, b.x, b.y) end

local function RunEnd(r) return shape.first[r] + shape.count[r] - 1 end

local function Run(kind, r, from, to)
    local lm = shape.map[r]
    Begin(kind)
    for j = from, to or RunEnd(r) do Add(lm, shape.x[j], shape.y[j]) end
    Close()
end

local function Flight(leg)
    local hops, Net = leg.hops, ns.Net
    if not hops then return Straight("flight", leg.from, leg.to) end
    for k = 1, #hops - 1 do
        local runs = Net.FlightShape(hops[k], hops[k + 1], shape) or Net.FlightShape(hops[k + 1], hops[k], shape)
        if runs then
            for r = 1, runs do Run("flight", r, shape.first[r]) end
        else
            local _, la, xa, ya = Net.Stop(hops[k])
            local _, lb, xb, yb = Net.Stop(hops[k + 1])
            Pair("flight", la, xa, ya, lb, xb, yb)
        end
    end
end

local function Nearest(runs, place)
    local best, bj, br = math.huge, 0, 0
    for r = 1, runs do
        if shape.map[r] == place.landmass then
            for j = shape.first[r], RunEnd(r) do
                local dx, dy = shape.x[j] - place.x, shape.y[j] - place.y
                local d = dx * dx + dy * dy
                if d < best then best, bj, br = d, j, r end
            end
        end
    end
    return sqrt(best), bj, br
end

-- The vessel's own stretch from one dock to the other, in sailing order; the whole route when a dock is off it.
local function Vessel(leg)
    local kind = leg.kind
    local runs = (leg.vessel or 0) > 0 and ns.Net.VesselShape(leg.vessel, shape)
    if not runs or runs < 1 then return Straight(kind, leg.from, leg.to) end
    local da, ja, ra = Nearest(runs, leg.from)
    local db, jb, rb = Nearest(runs, leg.to)
    if da > M.DOCK_REACH or db > M.DOCK_REACH or ja == jb then
        for r = 1, runs do Run(kind, r, shape.first[r]) end
        return
    end
    local r, j = ra, ja
    for _ = 1, runs + 1 do
        local stop = (r == rb and jb >= j) and jb or RunEnd(r)
        Run(kind, r, j, stop)
        if r == rb and stop == jb then return end
        r, j = r % runs + 1, shape.first[r % runs + 1]
    end
end

local function Walk(leg)
    local trail = leg.trail
    if not (trail and trail.n >= 2) then return Straight("walk", leg.from, leg.to) end
    local lm = leg.from.landmass
    Begin("walk")
    for i = 1, trail.n do Add(lm, trail.x[i], trail.y[i]) end
    Close()
end

local DRAW = { walk = Walk, flight = Flight, boat = Vessel, zeppelin = Vessel }

local function Segments(stride)
    local total = 0
    for p = 1, nPoly do total = total + ceil((pEnd[p] - pStart[p]) / stride) end
    return total
end

-- The smallest stride that thins every polyline alike, each keeping its last point, to at most max segments in
-- all; with max polylines or more no stride can, and the caller stops at max.
function M.Stride(max)
    local stride, total = 1, Segments(1)
    if total > max then
        stride = ceil(total / max)
        while nPoly < max and Segments(stride) > max do stride = stride + 1 end
    end
    return stride
end

-- The side trail's way (3.10's side, or false for none) after the trip's polylines, on the map of the last build;
-- Stride thins the trip's alone.
function M.Side(side)
    nPts, nPoly = tripPts, M.n
    local trail = side and side.walk.trail
    if trail and trail.n >= 2 then
        Begin("side")
        for i = 1, trail.n do Add(side.landmass, trail.x[i], trail.y[i]) end
        Close()
    end
    M.m, nPoly = nPoly, M.n
end

-- The polylines of legs trip.at to trip.n (none for a trip of false) on map uiMap, whose canvas is w by h units,
-- then the side trail's.
function M.Build(trip, uiMap, w, h, side)
    curMap, cw, ch = uiMap, w, h
    local lm, top, left, bottom, right = ns.Env.MapRect(uiMap)
    rLand = (lm and top ~= bottom and left ~= right) and lm or false
    rTop, rLeft, rBottom, rRight = top, left, bottom, right
    nPts, nPoly = 0, 0
    for i = trip and trip.at or 1, trip and trip.n or 0 do
        local leg = trip.legs[i]
        local draw = DRAW[leg.kind]
        if draw then draw(leg) else Straight(leg.kind, leg.from, leg.to) end
    end
    M.n, tripPts = nPoly, nPts
    M.Side(side)
end
