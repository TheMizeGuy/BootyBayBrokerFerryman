local ADDON, ns = ...

-- What a spread reached: the walk's measure, its points, and the shipped anchor table.
local Tr = {}
ns.GroundTrail = Tr

local C, Gr, Sp = ns.GroundCodes, ns.GroundGrid, ns.GroundSpread
local byte, floor, sqrt, abs, max, min = string.byte, math.floor, math.sqrt, math.abs, math.max, math.min
local PS, NONE24 = C.PS, C.NONE24
local nodeRec, nodeUV, stOf, hGet = C.nodeRec, C.nodeUV, Sp.stOf, Sp.hGet
local SQ2 = sqrt(2) - 1

-- the cheapest pair between nodes u and v of s's landmass under s's cost: land, inside, swim, its component. A
-- node is in a component once, an own node by its number, a foreign one in the component's short list.
local bk, bl, bi, bs, bc
local function pairsOf(s, c, lu, row, col, want)
    local L = s.L
    local d = L.d
    local f1, f2, own, fr, m1, m2, m3, fl = byte(d.comps, c * 9 + 1, c * 9 + 9)
    local ownFirst, foff = f1 + f2 * 256, m1 + m2 * 256 + m3 * 65536
    if not lu then lu = s.u - ownFirst end
    local moff, k, mx, cost = foff + 2 * fr, own + fr, d.matrix, s.cost
    local j = want - ownFirst
    if j < 0 or j >= own then
        j = nil
        for f = 0, fr - 1 do
            local x1, x2 = byte(mx, foff + f * 2 + 1, foff + f * 2 + 2)
            if x1 + x2 * 256 == want then j = own + f; break end
        end
    end
    if not j or j == lu then return end
    local a, b = lu, j
    if a > b then a, b = b, a end
    local idx = a * k - a * (a + 1) / 2 + (b - a - 1)
    local code = byte(mx, moff + idx + 1)
    if code == 255 then return end
    local r1, r2, c1, c2 = byte(d.nodes, want * 11 + 1, want * 11 + 4)
    local dr, dc = abs(r1 + r2 * 256 - row), abs(c1 + c2 * 256 - col)
    local base = dr > dc and dr + SQ2 * dc or dc + SQ2 * dr
    if base < 1 then base = 1 end
    local cst, kind, land, inside, swim = base * L.cell * L.step[code], fl % 4
    if fl >= 4 then land, inside, swim = Sp.shareSplit(mx, moff + k * (k - 1) / 2 + 1, idx, fl, cst, L.SF)
    elseif kind == 0 then land, inside, swim = cst, 0, 0
    elseif kind == 1 then land, inside, swim = 0, cst, 0
    else land, inside, swim = 0, 0, cst / L.SF end
    -- the spread's own key: padded for risk, so the pair is the one Advance took
    local key = land / cost.vLand + inside / cost.vInside + swim / cost.vSwim
    if cost.factor ~= 1 and s.risky[byte(d.comps, c * 9 + 9)] then key = key + (cost.factor - 1) * (land + inside + swim) / cost.vLand end
    if not bk or key < bk then bk, bl, bi, bs, bc = key, land, inside, swim, c end
end
local function pairMeasure(s, u, v)
    local row, col, owner, cb, ib = nodeRec(s.L, u)
    bk, s.u = nil, u
    pairsOf(s, owner, nil, row, col, v)
    if cb then pairsOf(s, cb, ib, row, col, v) end
    return bl, bi, bs, bc
end
Tr.pairMeasure = pairMeasure

local function planar(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return sqrt(dx * dx + dy * dy)
end

local function firstSource(s)
    for k = 1, s.nsrc do if s.srcP[k] then return s.srcX[k], s.srcY[k], s.srcP[k] end end
end

-- The point's near anchors (INTERFACES 4.6.3 d): as a source walks straight to the anchors near it that its own join
-- did not reach (GroundSpread), so does each piece of the point, to its Sp.NEAR_ANCHORS nearest within Sp.NEAR clusters,
-- so a walk to the point is no longer than the walk to such an anchor and on by the point's own walk to it. Near
-- notes a piece's anchors as its join jl is added.
local nA, nD = {}, {}
function Tr.Near(s, i, jl)
    local L, bit, n = s.L, 2 ^ (23 + i), 0
    local near = Sp.NEAR * L.CL * L.cell
    for k = 1, jl.n do
        local h = Sp.hFind(s, jl.node[k])
        if s.hb[h] % (2 * bit) < bit then s.hb[h] = s.hb[h] + bit end
    end
    for a, nd in pairs(L.anchorNode) do
        local h = Sp.hFind(s, nd)
        local ax, ay = Sp.anchorPos(L, a)
        local dd = (h < 0 or s.hb[h] % (2 * bit) < bit) and planar(s.ptX, s.ptY, ax, ay)
        if dd and dd <= near then      -- kept nearest first, ties by anchor
            local j = n
            while j >= 1 and (nD[j] > dd or (nD[j] == dd and nA[j] > a)) do nA[j + 1], nD[j + 1], j = nA[j], nD[j], j - 1 end
            nA[j + 1], nD[j + 1], n = a, dd, min(n + 1, Sp.NEAR_ANCHORS)
        end
    end
    for q = 1, n do s.pn = s.pn + 1; s.pnA[s.pn], s.pnI[s.pn], s.pnD[s.pn] = nA[q], i, nD[q] end
end
-- The spread has settled node u, an anchor's: the point's walks to it wait among the sources' (GroundSpread, a piece
-- as -i) until the frontier reaches the least they can make the point's time, and one that cannot lower it is left out.
function Tr.NearDue(s, u)
    local L, cost, T = s.L, s.cost, s.T
    local cur, closed = stOf(s, T)
    if closed then return end
    local pace = min(L.factor[0], L.factor[31]) * (1 - 1e-9) * min(1 / max(cost.vLand, cost.vInside), 1 / (L.SF * cost.vSwim))
    for q = 1, s.pn do
        local lb = s.g[u] + s.pnD[q] * pace
        if L.anchorNode[s.pnA[q]] == u and not (cur and s.g[T] <= lb) then
            local m = s.nearN + 1
            while m > s.nearAt and s.nearLb[m - 1] > lb do
                s.nearA[m], s.nearK[m], s.nearLb[m], m = s.nearA[m - 1], s.nearK[m - 1], s.nearLb[m - 1], m - 1
            end
            s.nearN, s.nearA[m], s.nearK[m], s.nearLb[m] = s.nearN + 1, s.pnA[q], -s.pnI[q], lb
        end
    end
end
-- The walk of piece i of the point to anchor a, whose node the spread has settled: where it is the least join of the
-- point there, its index among the point's joins, the point's time by it and the node. Its src is -1: Trail draws it
-- as the direct walk went, which no cluster holds.
function Tr.NearWalk(s, i, a)
    local L, tj, u = s.L, s.tj, s.L.anchorNode[a]
    if select(2, stOf(s, s.T)) then return end
    local ax, ay, ap = Sp.anchorPos(L, a, true)
    local c, l, ins, sw = Gr.direct(L, s.ptR[i], s.ptX, s.ptY, ap, ax, ay)
    if not c then return end
    c = ns.Ground.Price(s.cost, l, ins, sw, 0)
    local j = hGet(s, u, "ht")
    if not j then tj.n = tj.n + 1; j = tj.n; Sp.hSet(s, u, "ht", j); tj.node[j], tj.cost[j] = u, math.huge end
    if c >= tj.cost[j] then return end
    tj.cost[j], tj.land[j], tj.inside[j], tj.swim[j], tj.src[j], tj.of[j] = c, l, ins, sw, -1, i
    return j, s.g[u] + c, u
end

-- The walk between the sources and target id (0: the point) once reached: padded, real, land, inside, swim, risk.
-- Risk is the yards of the long-range links whose component lies on risky ground, as the spread priced them.
-- a unit of work every 16 steps along chains of predecessors (a call is two)
local hops = 0
function Tr.Reached(s, id)
    local L = s.L
    local v = id == 0 and s.T or L.anchorNode[id]
    if not v then return nil end
    local cur, closed = stOf(s, v)
    if not cur or not closed then return nil end
    local land, inside, swim, risk = 0, 0, 0, 0
    local x = v
    if v == s.T then
        local _, _, pr = stOf(s, v)
        if pr == -2 then
            land, inside, swim, x = s.dl, s.di, s.ds, nil
        else
            local j, tj = hGet(s, pr, "ht"), s.tj
            land, inside, swim = tj.land[j], tj.inside[j], tj.swim[j]
            x = pr
        end
    end
    local risky, comps = s.risky, L.d.comps
    hops = hops + 2
    while x do
        hops = hops + 1
        if hops >= 16 then hops = 0; C.spend(1) end
        local _, _, pr = stOf(s, x)
        if pr == -1 then
            local j, sj = hGet(s, x, "hs"), s.sj
            land, inside, swim = land + sj.land[j], inside + sj.inside[j], swim + sj.swim[j]
            break
        end
        local l, i, w, c = pairMeasure(s, pr, x)
        land, inside, swim = land + l, inside + i, swim + w
        if risky[byte(comps, c * 9 + 9)] then risk = risk + l + i + w end
        x = pr
    end
    local cost, f = s.cost, 1
    local real = land / cost.vLand + inside / cost.vInside + swim / cost.vSwim
    local padded, x1, y1 = real + (cost.factor - 1) * risk / cost.vLand, firstSource(s)
    if x1 then
        local x2, y2 = s.ptX, s.ptY
        local pl
        if id ~= 0 then
            x2, y2 = Sp.anchorPos(L, id)
            pl = planar(x1, y1, x2, y2)
            if L.ax[id] then pl = max(pl, planar(x1, y1, L.ax[id], L.ay[id])) end
        else
            pl = planar(x1, y1, x2, y2)
        end
        local yd = land + inside + swim
        -- guarantee 10: the yards scaled up to the line, the time floored at the line at the faster of land and swim
        if yd < pl then
            f = pl / yd
            if yd <= 0 then land = pl else land, inside, swim, risk = land * f, inside * f, swim * f, risk * f end
            local c = pl / max(cost.vLand, cost.vSwim)
            real, padded = max(real, c), max(padded, c)
        end
    end
    return max(padded, s.g[v]), real, land, inside, swim, risk, f
end

-- The points of the walk to target id, from the source (direction 1) or towards it (-1): the sources, the
-- entrances it passes and its target (a direct walk, which passes none, gets its corners on the grid). Into wx, wy.
local function sideIn(L, nd, c)
    local _, _, owner = nodeRec(L, nd)
    return owner == c and 0 or 1
end
-- The grid's own walk from p1 at (u1, v1) to p2 at (u2, v2), straightened, appended to (wx, wy) after n, with two
-- points half a fine cell either side of every cluster border a stretch of it crosses, so consecutive points stay
-- in one cluster or one step apart (guarantee 6).
local gx, gy, ts = {}, {}, {}
local function leg(L, wx, wy, n, p1, u1, v1, p2, u2, v2, limit, dc)
    local cell, CL, add = L.cell, L.CL, Gr.addPoint
    gx[1], gy[1] = L.x0 - u1 * cell, L.y0 - v1 * cell
    local m = Gr.leg(L, gx, gy, 1, p1, u1, v1, p2, u2, v2, limit, true, dc)
    for i = 2, m do
        local ua, va = (L.x0 - gx[i - 1]) / cell, (L.y0 - gy[i - 1]) / cell
        local ub, vb = (L.x0 - gx[i]) / cell, (L.y0 - gy[i]) / cell
        local len, nt = sqrt((ub - ua) ^ 2 + (vb - va) ^ 2), 0
        for axis = 1, 2 do
            local a, b = axis == 1 and ua or va, axis == 1 and ub or vb
            for k = min(floor(a / CL), floor(b / CL)) + 1, max(floor(a / CL), floor(b / CL)) do
                nt = nt + 1
                ts[nt] = (k * CL - a) / (b - a)
            end
        end
        table.sort(ts)
        for j = 1, nt do
            for e = -1, 1, 2 do
                local t = max(0, min(1, ts[j] + e * 0.5 / len))
                n = add(L, wx, wy, n, ua + (ub - ua) * t, va + (vb - va) * t)
            end
        end
        for j = 1, nt do ts[j] = nil end
        n = add(L, wx, wy, n, ub, vb)
    end
    return n
end

-- On to (ub, vb) on piece pb from (ua, va) on pa, the last point: straight within one cluster, else the grid's walk
local function toward(L, wx, wy, n, pa, ua, va, pb, ub, vb)
    local CL = L.CL
    if floor(ua / CL) == floor(ub / CL) and floor(va / CL) == floor(vb / CL) then return Gr.addPoint(L, wx, wy, n, ub, vb) end
    return leg(L, wx, wy, n, pa, ua, va, pb, ub, vb, floor(pa / PS))
end

-- wr (optional): for the line from point k to point k + 1, wr[2k - 1] and wr[2k]: what its two ends stand on where
-- it is a walk inside one cluster, which the ground may bend (Ground.Detail walks it), else false: a piece, or for
-- an entrance -(2 node + side) - 1, whose piece Detail looks up (the plan decodes no cluster for it). Returns the
-- points and the number of such lines.
function Tr.Trail(s, id, wx, wy, wr)
    local L = s.L
    local v = id == 0 and s.T or L.anchorNode[id]
    if not v then return 0, 0 end
    local cur, closed = stOf(s, v)
    if not cur or not closed then return 0, 0 end
    local chain, m = s.chain, 0
    local _, _, pr = stOf(s, v)
    local tail = nil
    if v == s.T then
        tail = pr
        v = pr >= 0 and pr or nil
    end
    while v do
        m = m + 1
        chain[m] = v
        local _, _, p = stOf(s, v)
        if p < 0 then break end
        v = p
    end
    local n, add, x0, y0, cell, nodePoint, at, lines = 0, Gr.addPoint, L.x0, L.y0, L.cell, C.nodePoint, 0, 0
    for k = 1, wr and #wr or 0 do wr[k] = false end
    local sx, sy, sp = firstSource(s)
    if tail == -2 then
        local k = s.directSrc
        sx, sy, sp = s.srcX[k], s.srcY[k], s.srcP[k]
        local u1, v1 = (x0 - sx) / cell, (y0 - sy) / cell
        n = add(L, wx, wy, n, u1, v1)
        -- drawn again from the chain the spread kept (its points are as priced, before the pass)
        n = leg(L, wx, wy, n, sp, u1, v1, s.directPt, (x0 - s.ptX) / cell, (y0 - s.ptY) / cell, nil, s.dc.n >= 0 and s.dc)
    else
        local first = chain[m]
        local j = hGet(s, first, "hs")
        local k = j and s.sj.src[j] or 0
        if k > 0 then
            -- the walk from a source to a near anchor: the grid's own corners, as the direct walk went
            local u1, v1 = (x0 - s.srcX[k]) / cell, (y0 - s.srcY[k]) / cell
            local u2, v2, p2 = nodePoint(L, first, 0)
            n = add(L, wx, wy, n, u1, v1)
            n = leg(L, wx, wy, n, s.srcP[k], u1, v1, p2, u2, v2)
        elseif sp then
            -- the source whose join reached the first node
            local _, _, ca = nodeUV(L, first, 0)
            local _, _, cb = nodeUV(L, first, 1)
            k = s.sj.of[j]
            sx, sy, sp = s.srcX[k], s.srcY[k], s.srcP[k]
            local su, sv = (x0 - sx) / cell, (y0 - sy) / cell
            n = add(L, wx, wy, n, su, sv)
            local scl, b = floor(sp / PS), 0
            if cb == scl and ca ~= scl then b = 1 end
            local u2, v2, p2 = nodePoint(L, first, b)
            n, at = toward(L, wx, wy, n, sp, su, sv, p2, u2, v2), n
            if wr and n == at + 1 and floor(p2 / PS) == scl then wr[2 * n - 3], wr[2 * n - 2], lines = sp, p2, lines + 1 end
        else
            n = add(L, wx, wy, n, nodeUV(L, first, 0))
        end
        for k = m, 2, -1 do
            if k % 8 == 0 then C.spend(1) end
            local a, b = chain[k], chain[k - 1]
            local _, _, _, c = pairMeasure(s, a, b)
            local sa, sb = sideIn(L, a, c), sideIn(L, b, c)
            n = add(L, wx, wy, n, nodeUV(L, a, sa))
            -- out through an entrance and back through it: the walk stayed on this side
            if n > 2 and wx[n] == wx[n - 2] and wy[n] == wy[n - 2] then n = n - 2 end
            n, at = add(L, wx, wy, n, nodeUV(L, b, sb)), n
            if wr and n > at then wr[2 * n - 3], wr[2 * n - 2], lines = -2 * a - sa - 1, -2 * b - sb - 1, lines + 1 end
            n = add(L, wx, wy, n, nodeUV(L, b, 0))
        end
        if id == 0 then
            -- the piece of the point whose join, or walk from a near anchor, reached the last node
            local last = chain[1]
            local jt = hGet(s, last, "ht")
            local tp, ut, vt = s.ptR[s.tj.of[jt]], (x0 - s.ptX) / cell, (y0 - s.ptY) / cell
            if s.tj.src[jt] == -1 then
                -- a near anchor's walk to the point: the grid's own corners from the anchor's point, as the direct walk went
                local u1, v1, p1 = nodePoint(L, last, 0)
                n = add(L, wx, wy, n, u1, v1)
                n = leg(L, wx, wy, n, p1, u1, v1, tp, ut, vt)
            else
                local _, _, ca = nodeUV(L, last, 0)
                local _, _, cb = nodeUV(L, last, 1)
                local tcl, b = floor(tp / PS), 0
                if cb == tcl and ca ~= tcl then b = 1 end
                local u1, v1, p1 = nodePoint(L, last, b)
                n = add(L, wx, wy, n, u1, v1)
                n, at = toward(L, wx, wy, n, p1, u1, v1, tp, ut, vt), n
                if wr and n == at + 1 and floor(p1 / PS) == tcl then wr[2 * n - 3], wr[2 * n - 2], lines = p1, tp, lines + 1 end
            end
        end
    end
    for k = 1, wr and 2 * n - 2 or 0 do wr[k] = wr[k] or false end
    if s.dir == -1 then
        for k = 1, floor(n / 2) do
            wx[k], wx[n + 1 - k] = wx[n + 1 - k], wx[k]
            wy[k], wy[n + 1 - k] = wy[n + 1 - k], wy[k]
        end
        for k = 1, wr and n - 1 or 0 do wr[k], wr[2 * n - 1 - k] = wr[2 * n - 1 - k], wr[k] end
    end
    return n, lines
end

-- the shipped walk between two anchors of landmass L, with risk for cost's faction and level
function Tr.Pair(L, a, b, cost)
    if a == b then return 0, 0, 0, 0 end
    local x, y = L.onIndex[a], L.onIndex[b]
    if not x or not y then return nil end
    if x > y then x, y = y, x end
    local n = L.nOn
    local p = (x * n - x * (x + 1) / 2 + (y - x - 1)) * 3 + 1
    local d = L.d
    local o1, o2, o3 = byte(d.pairIndex, p, p + 2)
    local off = o1 + o2 * 256 + o3 * 65536
    if off == NONE24 then return nil end
    local s = d.pairData
    p = off + 1
    local a1, a2, a3, i1, i2, i3, w1, w2, w3, nc = byte(s, p, p + 9)
    local land, inside, swim = (a1 + a2 * 256 + a3 * 65536) / 4, (i1 + i2 * 256 + i3 * 65536) / 4, (w1 + w2 * 256 + w3 * 65536) / 4
    if L.riskF ~= cost.faction or L.riskL ~= cost.level then
        L.riskF, L.riskL = cost.faction, cost.level
        Sp.setRisk(L, cost, L.risky)
    end
    local risk, risky = 0, L.risky
    p = p + 10
    for _ = 1, nc do
        local c, y1, y2 = byte(s, p, p + 2)
        if risky[c] then risk = risk + y1 + y2 * 256 end
        p = p + 3
    end
    -- never shorter than the line between the two points the network gives (guarantee 10)
    local yd, pl = land + inside + swim, L.ax[a] and L.ax[b] and planar(L.ax[a], L.ay[a], L.ax[b], L.ay[b]) or 0
    if yd <= 0 then land = pl
    elseif yd < pl then
        local f = pl / yd
        land, inside, swim, risk = land * f, inside * f, swim * f, risk * f
    end
    return land, inside, swim, risk
end
