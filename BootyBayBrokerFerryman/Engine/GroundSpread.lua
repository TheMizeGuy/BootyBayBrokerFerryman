local ADDON, ns = ...

-- The spread over the long-range graph (FORMAT.md, "Component blocks") from sources standing on pieces, and the
-- waypoints of a walk it reached. A search object keeps two numbers a node: g and st (below).
local Sp = {}
ns.GroundSpread = Sp

local Ground, C, Gr = ns.Ground, ns.GroundCodes, ns.GroundGrid
local byte, floor, sqrt, huge, max, min = string.byte, math.floor, math.sqrt, math.huge, math.max, math.min
local NONE16, nodeRec = C.NONE16, C.nodeRec
Sp.NEAR, Sp.NEAR_ANCHORS, Sp.LEVEL_MARGIN, Sp.PAIRS = 2, 2, 6, 6
local S16, S32, SQ2, NODE_REC, COMP_REC = 65536, 65536 * 65536, sqrt(2) - 1, 11, 9

-- a join list; src[j]: the source whose direct walk gave the entry (0: a join; -1: the point's walk from a near
-- anchor); of[j]: the source, or the piece of the point, whose join or walk it is
local function List() return { node = {}, cost = {}, land = {}, inside = {}, swim = {}, src = {}, of = {}, n = 0 } end
local jl = List()

-- A search object. Arrays grow to the largest landmass it has searched and stay.
function Sp.New()
    return { g = {}, st = {}, heap = {}, size = -1, stamp = 0, heapSize = 0, sj = List(), tj = List(),
        hk = {}, hs = {}, ht = {}, hb = {}, hm = {}, hNow = 0, srcP = {}, srcX = {}, srcY = {}, ptR = {}, hit = {}, hits = 0,
        nsrc = 0, npt = 0, front = 0, started = false, chain = {}, risky = {}, pn = 0, pnA = {}, pnI = {}, pnD = {},
        nearA = {}, nearK = {}, nearLb = {}, dp = { n = -1, x = {}, y = {} }, dq = { n = -1, x = {}, y = {} },
        dc = { n = -1, P = {}, A1 = {}, A2 = {}, B1 = {}, B2 = {} } }
end

-- Fills a search object's arrays up to the size of landmass L, a pause every 512 slots.
local function grow(s, L, pause)
    local n = L.N + 2
    for i = s.size + 1, n do
        s.g[i], s.st[i] = huge, 0
        if i % 512 == 0 and pause then pause() end
    end
    if n > s.size then s.size = n end
end
Sp.grow = grow

-- The object's own small hash of the nodes its joins reached: per node its index in sj and in tj (0: none).
local HN = 512
local function hFind(s, nd)
    local h = nd % HN
    local hk, hm, now = s.hk, s.hm, s.hNow
    while hm[h] == now do
        if hk[h] == nd then return h end
        h = (h + 1) % HN
    end
    return -1 - h
end
local function hSet(s, nd, field, j)
    local h = hFind(s, nd)
    if h < 0 then
        h = -1 - h
        -- the node sides the joins of one search's two ends reach: about 200 at the shipped data's heaviest corners
        assert(s.sj.n + s.tj.n < HN / 2, "Ferryman: walking.joins")
        s.hk[h], s.hm[h], s.hs[h], s.ht[h], s.hb[h] = nd, s.hNow, 0, 0, 0
    end
    s[field][h] = j
end
local function hGet(s, nd, field)
    local h = hFind(s, nd)
    local j = h >= 0 and s[field][h] or 0
    return j > 0 and j or nil
end
Sp.hGet, Sp.hSet, Sp.hFind = hGet, hSet, hFind

local function setRisk(L, cost, risky)
    local d, s = L.d, L.d.classes
    local enemy = cost.faction == 1 and 2 or 1
    for c = 0, d.classCount - 1 do
        local level, held = byte(s, c * 2 + 1, c * 2 + 2)
        risky[c] = (held % 4 == enemy) or (level > 0 and level >= cost.level + Sp.LEVEL_MARGIN)
    end
end
Sp.setRisk = setRisk

local function weighSplit(cost, land, inside, swim) return (Ground.Price(cost, land, inside, swim, 0)) end

function Sp.Begin(s, L, direction, cost)
    if L.N + 2 > s.size then grow(s, L, C.pause) end
    if s.hNow > 1e6 then s.hNow = 0; for h = 0, HN - 1 do s.hm[h] = -1 end end
    s.stamp = s.stamp + 1
    if s.stamp >= S16 then
        s.stamp = 1
        for i = 0, s.size do s.st[i] = 0 end
    end
    s.L, s.heapSize, s.cost, s.dir = L, 0, cost, direction or 1
    setRisk(L, cost, s.risky)
    s.hNow = s.hNow + 1
    s.sj.n, s.tj.n, s.nsrc, s.npt, s.hits, s.front, s.pops, s.dp.n, s.dq.n, s.dc.n = 0, 0, 0, 0, 0, 0, 0, -1, -1, -1
    s.started, s.directSrc, s.T, s.nearN, s.nearAt, s.pn = false, nil, L.N, 0, 1, 0
end

local function addJoins(s, list, into, field, of)
    for k = 1, list.n do
        local nd = list.node[k]
        local j = hGet(s, nd, field)
        if not j then into.n = into.n + 1; j = into.n; hSet(s, nd, field, j); into.node[j], into.cost[j] = nd, huge end
        local w = weighSplit(s.cost, list.land[k], list.inside[k], list.swim[k])     -- the least time, not grid cost
        if w < into.cost[j] then
            into.cost[j], into.land[j], into.inside[j], into.swim[j], into.src[j], into.of[j] = w, list.land[k],
                list.inside[k], list.swim[k], 0, of
        end
    end
end

function Sp.AddSource(s, piece, x, y)
    s.nsrc = s.nsrc + 1
    s.srcP[s.nsrc], s.srcX[s.nsrc], s.srcY[s.nsrc] = piece, x, y
    Gr.joins(s.L, piece, x, y, jl)
    addJoins(s, jl, s.sj, "hs", s.nsrc)
    -- which sources' joins reached a node: a near anchor is walked to from every source whose join did not
    local bit = 2 ^ (s.nsrc - 1)
    for k = 1, jl.n do
        local h = hFind(s, jl.node[k])
        if s.hb[h] % (2 * bit) < bit then s.hb[h] = s.hb[h] + bit end
    end
end

function Sp.AddAnchorSource(s, a)
    local nd = s.L.anchorNode[a]
    s.nsrc = s.nsrc + 1
    s.srcP[s.nsrc] = false
    local sj, j = s.sj, hGet(s, nd, "hs")
    if not j then sj.n = sj.n + 1; j = sj.n; hSet(s, nd, "hs", j); sj.node[j] = nd end
    sj.cost[j], sj.land[j], sj.inside[j], sj.swim[j], sj.src[j] = 0, 0, 0, 0, 0
end

function Sp.SetPoint(s, n, pieces, x, y)
    s.npt = n
    for i = 1, n do s.ptR[i] = pieces[i] end
    s.ptX, s.ptY = x, y
end

local function siftUp(s, i)
    local heap, g, st = s.heap, s.g, s.st
    local v = heap[i]
    local k = g[v]
    while i > 1 do
        local p = (i - i % 2) / 2
        local u = heap[p]
        if g[u] <= k then break end
        heap[i] = u
        local su = st[u]
        st[u] = su - su % S16 + i
        i = p
    end
    heap[i] = v
    local sv = st[v]
    st[v] = sv - sv % S16 + i
end

local function pop(s)
    local heap, g, st, n = s.heap, s.g, s.st, s.heapSize - 1
    local top, last = heap[1], heap[n + 1]
    s.heapSize = n
    if n > 0 then
        local i, k = 1, g[last]
        while true do
            local c = 2 * i
            if c > n then break end
            local hc = heap[c]
            if c < n then
                local hc1 = heap[c + 1]
                if g[hc1] < g[hc] then c = c + 1; hc = hc1 end
            end
            if g[hc] >= k then break end
            heap[i] = hc
            local sc = st[hc]
            st[hc] = sc - sc % S16 + i
            i = c
        end
        heap[i] = last
        local sl = st[last]
        st[last] = sl - sl % S16 + i
    end
    return top
end

-- st[v] = ((stamp * 2 + closed) * 65536 + pred + 3) * 65536 + heap position; pred -1 a source join, -2 the
-- direct walk, -3 none
local function stOf(s, v)
    local x = s.st[v]
    local hi = floor(x / S32)
    if floor(hi / 2) ~= s.stamp then return false, false, -3 end
    return true, hi % 2 == 1, floor(x / S16) % S16 - 3
end
Sp.stOf = stOf

local function relax(s, v, key, pred)
    local x = s.st[v]
    local hi = floor(x / S32)
    local cur = floor(hi / 2) == s.stamp
    if cur and hi % 2 == 1 then return end
    if not cur then s.g[v] = huge end
    if key < s.g[v] then
        local fresh = s.g[v] == huge
        s.g[v] = key
        local pos = cur and x % S16 or 0
        s.st[v] = ((s.stamp * 2) * S16 + pred + 3) * S16 + pos
        if fresh then
            s.heapSize = s.heapSize + 1
            s.heap[s.heapSize] = v
            siftUp(s, s.heapSize)
        else
            siftUp(s, pos)
        end
    end
end

local function planar(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return sqrt(dx * dx + dy * dy)
end

-- anchor a's node: x, y, the piece it stands on (looked up once: the node's cluster is decoded then)
local function anchorPos(L, a, withPiece)
    local nd = L.anchorNode[a]
    if not nd then return nil end
    local row, col, _, _, _, _, pa = nodeRec(L, nd)
    local x, y, p = L.x0 - (row + 0.5) * L.cell, L.y0 - (col + 0.5) * L.cell, L.piece[a]
    if withPiece and not p then
        local _, _, _, first = C.cellAt(L, floor(row / L.G), floor(col / L.G))
        p = first + pa
        L.piece[a] = p
    end
    return x, y, p
end
Sp.anchorPos = anchorPos

-- Anchors near a point source that its join did not reach, the nearest first: a direct grid walk to each. A walk
-- is at least its line at the lowest factor and the fastest pace, so one to a node no join reached waits until the
-- frontier reaches that least (Sp.Advance; in order of it, one anchor's walks in their sources' order).
local nearList, nearDist, touched = {}, {}, {}
local function relaxJoin(s, j)
    local sj = s.sj; relax(s, sj.node[j], (weighSplit(s.cost, sj.land[j], sj.inside[j], sj.swim[j])), -1)
end
local function nearWalk(s, k, a)
    if k < 0 then local j, c, u = ns.GroundTrail.NearWalk(s, -k, a); if j then relax(s, s.T, c, u) end return end
    local L, sj, nd = s.L, s.sj, s.L.anchorNode[a]
    local ax, ay, ap = anchorPos(L, a, true)
    local c, l, ins, sw = Gr.direct(L, s.srcP[k], s.srcX[k], s.srcY[k], ap, ax, ay)
    if not c then return end
    c = weighSplit(s.cost, l, ins, sw)
    local j = hGet(s, nd, "hs")
    if not j then sj.n = sj.n + 1; j = sj.n; hSet(s, nd, "hs", j); sj.node[j], sj.cost[j] = nd, huge end
    if c < sj.cost[j] then sj.cost[j], sj.land[j], sj.inside[j], sj.swim[j], sj.src[j] = c, l, ins, sw, k end
    return j
end
local function nearAnchors(s)
    local L, cost = s.L, s.cost
    local near, f0 = Sp.NEAR * L.CL * L.cell, min(L.factor[0], L.factor[31]) * (1 - 1e-9)
    local pace = f0 * min(1 / max(cost.vLand, cost.vInside), 1 / (L.SF * cost.vSwim))
    for k = 1, s.nsrc do
        local p1, x1, y1, bit, n, seen = s.srcP[k], s.srcX[k], s.srcY[k], 2 ^ (k - 1), 0, 0
        if p1 then
            for a, nd in pairs(L.anchorNode) do
                seen = seen + 1
                if seen % 32 == 0 then C.spend(1) end
                local h = hFind(s, nd)
                local ax, ay = anchorPos(L, a)
                local dd = (h < 0 or s.hb[h] % (2 * bit) < bit) and planar(x1, y1, ax, ay)
                if dd and dd <= near then      -- kept nearest first, ties by anchor
                    local j = n
                    while j >= 1 and (nearDist[j] > dd or (nearDist[j] == dd and nearList[j] > a)) do
                        nearList[j + 1], nearDist[j + 1], j = nearList[j], nearDist[j], j - 1
                    end
                    nearList[j + 1], nearDist[j + 1], n = a, dd, min(n + 1, Sp.NEAR_ANCHORS)
                end
            end
            for i = 1, n do
                local a, dd = nearList[i], nearDist[i]
                local j = hGet(s, L.anchorNode[a], "hs")
                if not j then
                    local m, lb = s.nearN + 1, dd * pace
                    while m > s.nearAt and s.nearLb[m - 1] > lb do
                        s.nearA[m], s.nearK[m], s.nearLb[m], m = s.nearA[m - 1], s.nearK[m - 1], s.nearLb[m - 1], m - 1
                    end
                    s.nearN, s.nearA[m], s.nearK[m], s.nearLb[m] = s.nearN + 1, a, k, lb
                else
                    nearWalk(s, k, a)
                end
            end
        end
    end
end
-- the waiting walks whose least time is at most `upTo`, each node then relaxed with the least of its walks
local function nearDue(s, upTo)
    local n = 0
    while s.nearAt <= s.nearN and s.nearLb[s.nearAt] <= upTo do
        local j = nearWalk(s, s.nearK[s.nearAt], s.nearA[s.nearAt])
        if j then n = n + 1; touched[n] = j end
        s.nearAt = s.nearAt + 1
    end
    for i = 1, n do relaxJoin(s, touched[i]) end
end

local dw = {}
local function start(s)
    assert(s.nsrc > 0, "Ferryman: walking.source")
    s.started = true
    local L, cost, sj = s.L, s.cost, s.sj
    if s.npt > 0 then
        for i = 1, s.npt do
            Gr.joins(L, s.ptR[i], s.ptX, s.ptY, jl)
            addJoins(s, jl, s.tj, "ht", i)
            ns.GroundTrail.Near(s, i, jl)     -- the point's near anchors: walked once the spread has settled them
        end
        -- the least direct walk by time over every source and piece of the point; with sights (format 5) each one is
        -- measured, and weighed, as it is drawn, its points in s.dq, kept in s.dp when it is the least so far
        local best, near, cell = nil, Sp.NEAR * L.CL * L.cell, L.cell
        for k = 1, s.nsrc do
            local p1 = s.srcP[k]
            if p1 and planar(s.srcX[k], s.srcY[k], s.ptX, s.ptY) <= near then
                Gr.directs(L, p1, s.srcX[k], s.srcY[k], s.npt, s.ptR, s.ptX, s.ptY, dw)
                for i = 1, s.npt do
                    local c, l, ins, sw = dw[4 * i - 3], dw[4 * i - 2], dw[4 * i - 1], dw[4 * i]
                    local dq, u1, v1, d, dl, di, ds = s.dq, (L.x0 - s.srcX[k]) / cell, (L.y0 - s.srcY[k]) / cell
                    if c and L.d.format == 5 then
                        dq.n, d, dl, di, ds = Gr.leg(L, dq.x, dq.y, Gr.addPoint(L, dq.x, dq.y, 0, u1, v1), p1, u1, v1, s.ptR[i],
                            (L.x0 - s.ptX) / cell, (L.y0 - s.ptY) / cell)
                        if d then l, ins, sw = dl, di, ds end
                    end
                    local w = c and weighSplit(cost, l, ins, sw)
                    if w and (not best or w < best) then
                        best, s.dl, s.di, s.ds, s.directSrc, s.directPt, s.dp, s.dq = w, l, ins, sw, k, s.ptR[i], dq, s.dp
                        Gr.keep(s.dc, d)    -- its chain, which the trail draws again with no search (GroundTrail)
                    end
                end
            end
        end
        if best then relax(s, s.T, best, -2) end
    end
    -- near anchors with or without a point (the reference reader runs them after the point's own work too)
    nearAnchors(s)
    for k = 1, sj.n do relaxJoin(s, k) end
end

-- the land, inside and swum yards of a pair of cost cst in a mixed component (flags fl): its share nibble at
-- index idx of the nibbles starting at byte offset off (1-based) of matrix string s
local function shareSplit(s, off, idx, fl, cst, SF)
    local h = idx % 2
    local b = byte(s, off + (idx - h) / 2)
    local nib = h == 1 and floor(b / 16) or b % 16
    local mode = floor(fl / 8) % 4
    local si, sw
    if mode == 0 then si, sw = nib / 15, 0
    elseif mode == 1 then si, sw = 0, nib / 15
    elseif mode == 2 then si, sw = 1 - nib / 15, nib / 15
    else si, sw = floor(nib / 4) / 5, nib % 4 / 5 end
    return cst * (1 - si - sw), cst * si, cst * sw / SF
end
Sp.shareSplit = shareSplit

-- Settles places until units of work are spent (a place is one, and every PAIRS pairs its expansion reads one
-- more, so a call stays inside a stretch): false when the spread is exhausted. Reached targets go to s.hit.
function Sp.Advance(s, units)
    if not s.started then
        start(s)
        C.spend(C.CHUNK)
    end
    local L, g, st, heap, cost = s.L, s.g, s.st, s.heap, s.cost
    local nodes, comps, matrix = L.d.nodes, L.d.comps, L.d.matrix
    local vL, vI, vS, fac = cost.vLand, cost.vInside, cost.vSwim, cost.factor
    local SF, cell, steps, risky = L.SF, L.cell, L.step, s.risky
    local T, nodeAnchor, hit, tj, stamp2, PAIRS = s.T, L.nodeAnchor, s.hit, s.tj, s.stamp * 2, Sp.PAIRS
    local spent, settled = 0, 0
    while spent < units do
        local top = s.nearAt <= s.nearN and (s.heapSize > 0 and g[heap[1]] or huge)
        if top and top >= s.nearLb[s.nearAt] then nearDue(s, top) end
        if s.heapSize == 0 then s.front = huge; Ground.settled = Ground.settled + settled; return false end
        local u = pop(s)
        local gu, read = g[u], 0
        st[u], s.front, s.pops, settled = st[u] + S32, gu, s.pops + 1, settled + 1
        if u == T then
            s.hits = s.hits + 1
            hit[s.hits] = 0
        else
            local a = nodeAnchor[u]
            if a then s.hits = s.hits + 1; hit[s.hits] = a; if s.pn > 0 then ns.GroundTrail.NearDue(s, u) end end
            local q = u * NODE_REC + 1
            local r1, r2, c1, c2, o1, o2, b1, b2, ib = byte(nodes, q, q + 8)
            local row, col = r1 + r2 * 256, c1 + c2 * 256
            for part = 1, 2 do
                local c, lu
                if part == 1 then c = o1 + o2 * 256 else c = b1 + b2 * 256; lu = ib end
                if c ~= NONE16 then
                    local p = c * COMP_REC + 1
                    local f1, f2, own, fr, m1, m2, m3, fl, ar = byte(comps, p, p + 8)
                    local ownFirst, k, boff = f1 + f2 * 256, own + fr, m1 + m2 * 256 + m3 * 65536
                    if part == 1 then lu = u - ownFirst end
                    read = read + k
                    local moff, foff, kind, mixed = boff + 2 * fr + 1, boff - own * 2 + 1, fl % 4, fl >= 4
                    local np, rk = k * (k - 1) / 2, fac ~= 1 and risky[ar]
                    local mul
                    if kind == 0 then mul = 1 / vL elseif kind == 1 then mul = 1 / vI else mul = 1 / (SF * vS) end
                    if rk then mul = mul + (fac - 1) / vL * (kind == 2 and 1 / SF or 1) end
                    local cellmul, rowbase, cs = cell * mul, lu * k - lu * (lu + 1) / 2 - lu - 1, -1
                    for j = 0, k - 1 do
                        if j ~= lu then
                            local idx = j < lu and cs + lu or rowbase + j
                            local code = byte(matrix, moff + idx)
                            if code ~= 255 then
                                local v
                                if j < own then v = ownFirst + j
                                else local x1, x2 = byte(matrix, foff + j * 2, foff + j * 2 + 1); v = x1 + x2 * 256 end
                                local q2 = v * NODE_REC + 1
                                local a1, a2, e1, e2 = byte(nodes, q2, q2 + 3)
                                local dr, dc = a1 + a2 * 256 - row, e1 + e2 * 256 - col
                                if dr < 0 then dr = -dr end
                                if dc < 0 then dc = -dc end
                                local base = dr > dc and dr + SQ2 * dc or dc + SQ2 * dr
                                if base < 1 then base = 1 end
                                local key
                                if mixed then
                                    local land, inside, swim = shareSplit(matrix, moff + np, idx, fl,
                                        base * cell * steps[code], SF)
                                    key = land / vL + inside / vI + swim / vS
                                    if rk then key = key + (fac - 1) * (land + inside + swim) / vL end
                                else
                                    key = base * steps[code] * cellmul
                                end
                                local nk = gu + key
                                local sv = st[v]
                                local hi = (sv - sv % S32) / S32
                                if hi == stamp2 then
                                    if nk < g[v] then
                                        local pos = sv % S16
                                        g[v], st[v] = nk, (stamp2 * S16 + u + 3) * S16 + pos
                                        siftUp(s, pos)
                                    end
                                elseif hi ~= stamp2 + 1 then
                                    local n = s.heapSize + 1
                                    s.heapSize, heap[n], g[v], st[v] = n, v, nk, (stamp2 * S16 + u + 3) * S16 + n
                                    siftUp(s, n)
                                end
                            end
                        end
                        cs = cs + k - j - 2
                    end
                end
            end
            local j = tj.n > 0 and hGet(s, u, "ht")
            if j then relax(s, T, gu + (weighSplit(cost, tj.land[j], tj.inside[j], tj.swim[j])), u) end
        end
        spent = spent + 1 + read / PAIRS
    end
    Ground.settled, C.work = Ground.settled + settled, C.work + spent
    return true
end
