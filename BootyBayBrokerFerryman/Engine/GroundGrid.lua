local ADDON, ns = ...

-- The grid search over pieces (joins, direct walks, the walk between two points of one cluster) and the funnel
-- that pulls a walk taut through its portals. One set of arrays serves every search: the Driver runs one job at
-- a time and a grid search ends before its caller returns, so two never overlap.
local Gr = {}
ns.GroundGrid = Gr

local Ground, C, P = ns.Ground, ns.GroundCodes, ns.GroundPortals
local floor, sqrt, abs, min, huge = math.floor, math.sqrt, math.abs, math.min, math.huge
local PS = C.PS
local pieceAttr, pieceCell, transit, nodePoint, nodeRec = C.pieceAttr, C.pieceCell, P.transit, C.nodePoint, C.nodeRec
local decode, finish, eachPortal = C.decode, C.finish, P.eachPortal
Gr.BUDGET, Gr.DIRECT, Gr.LEG, Gr.DOOR, Gr.MARGIN, Gr.HEAP = 600, 400, 600, 0.75, 1, 4

local B, HASH = 602, 1024
local gPiece, gG, gPred, gEu, gEv, gDone, gA1, gA2, gB1, gB2 = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
local hK, hS, hashK, hashV, hashStamp = {}, {}, {}, {}, {}
local fu1, fv1, fu2, fv2, fp, cu, cv, ci, chain, cm, xu, xv = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
Gr.cu, Gr.cv, Gr.ci, Gr.fp, Gr.chain, Gr.cm, Gr.xu, Gr.xv = cu, cv, ci, fp, chain, cm, xu, xv
Gr.gPiece, Gr.gPred, Gr.gA1, Gr.gA2, Gr.gB1, Gr.gB2 = gPiece, gPred, gA1, gA2, gB1, gB2
local hStamp, gN, hN, nc, made, gates = 0, 0, 0, 0, false, 0
local L, gLimit, gGoalU, gGoalV, door, ucell, ufac = nil, nil, nil, nil, false, 0, 0
Gr.heapFull, Gr.legMisses = 0, 0

local spend = C.spend
local function tick() Ground.settled = Ground.settled + 1; spend(1) end; Gr.tick = tick

local function hashGet(piece)
    local i = piece % PS
    local h = (i * 37 + (piece - i) / PS) % HASH
    while true do
        if hashStamp[h] ~= hStamp then return nil, h end
        if hashK[h] == piece then return hashV[h], h end
        h = (h + 1) % HASH
    end
end

local function hpush(k, s)
    hN = hN + 1
    local n = hN
    while n > 1 do
        local p = floor(n / 2)
        if hK[p] <= k then break end
        hK[n], hS[n] = hK[p], hS[p]
        n = p
    end
    hK[n], hS[n] = k, s
end

local function hpop()
    local tk, ts, lk, ls, i = hK[1], hS[1], hK[hN], hS[hN], 1
    hN = hN - 1
    local n = hN
    while true do
        local c = 2 * i
        if c > n then break end
        if c < n and hK[c + 1] < hK[c] then c = c + 1 end
        if hK[c] >= lk then break end
        hK[i], hS[i] = hK[c], hS[c]
        i = c
    end
    if n > 0 then hK[i], hS[i] = lk, ls end
    return tk, ts
end

local function gState(piece)
    local v, h = hashGet(piece)
    if v then return v end
    if gN >= B - 1 then return nil end
    local i = gN
    gN, hashStamp[h], hashK[h], hashV[h] = i + 1, hStamp, piece, i
    gPiece[i], gG[i], gDone[i] = piece, huge, 0
    return i
end

-- relaxes a portal of the piece being expanded (i, the expanding state)
local function gRelax(i, other, a1, a2, b1, b2)
    if gLimit and floor(other / PS) ~= gLimit then return end
    local j = gState(other)
    if not j or gDone[j] == 1 then return end
    local eu, ev = gEu[i], gEv[i]
    local tu, tv, du, dv, t = gGoalU or eu, gGoalV or ev, b1 - a1, b2 - a2, 0.5
    local len2 = du * du + dv * dv
    if len2 > 0 then
        if gGoalU then
            local ru, rv = tu - eu, tv - ev
            local den = ru * dv - rv * du
            if den ~= 0 then t = ((a1 - eu) * rv - (a2 - ev) * ru) / den else t = 0.5 end
        else
            t = ((eu - a1) * du + (ev - a2) * dv) / len2
        end
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local mu, mv = a1 + du * t, a2 + dv * t
    local g = gG[i] + transit(L, gPiece[i], eu, ev, mu, mv)
    if g < gG[j] then
        gG[j], gPred[j], gEu[j], gEv[j] = g, i, mu, mv
        gA1[j], gA2[j], gB1[j], gB2[j] = a1, a2, b1, b2
        local key = g
        if gGoalU then
            local x, y = gGoalU - mu, gGoalV - mv
            key = g + sqrt(x * x + y * y) * ucell * ufac
        end
        if hN < B * Gr.HEAP then hpush(key, j) else Gr.heapFull = Gr.heapFull + 1 end
    end
end

-- starts a grid search at (u, v) on piece gid of landmass lm; limit: the only cluster it may enter (or nil)
local function gStart(lm, gid, u, v, limit, gu, gv)
    if not made then
        made = true
        for h = 0, HASH - 1 do hashK[h], hashV[h], hashStamp[h] = -1, 0, 0 end
    end
    L, hStamp, gN, hN, gLimit, gGoalU, gGoalV = lm, hStamp + 1, 0, 0, limit, gu, gv
    ucell, ufac, door = lm.cell, lm.factor[0], false    -- a job cancelled inside a door funnel left it set
    local i = gState(gid)
    gG[i], gPred[i], gEu[i], gEv[i] = 0, -1, u, v
    hpush(0, i)
    return i
end
Gr.start = gStart

-- settles states until the budget is spent, the heap is empty or the goal piece is settled: state, settled
local function gRun(budget, goal, onSettle, ctx)
    local settled = 0
    while hN > 0 and settled < budget do
        local k, i = hpop()
        if gDone[i] == 0 then
            local key = gG[i]
            if gGoalU then
                local x, y = gGoalU - gEu[i], gGoalV - gEv[i]
                key = key + sqrt(x * x + y * y) * ucell * ufac
            end
            if k <= key + 1e-9 then
                gDone[i], settled = 1, settled + 1
                tick()
                if onSettle and onSettle(ctx, i) then return i, settled end
                if goal and gPiece[i] == goal then return i, settled end
                eachPortal(L, gPiece[i], gRelax, i)
            end
        end
    end
    return nil, settled
end
Gr.run = gRun

local function triarea2(au, av, bu, bv, xu, xv) return (xu - au) * (bv - av) - (bu - au) * (xv - av) end

-- The walk from the search's start to (eu, ev) on state i's piece, pulled taut through its portals with every
-- centred piece's centre as a point it must pass, priced stretch by stretch on the piece each lies in. Returns
-- run-yards, land, inside, swim; the corners in cu, cv [1..nc], the run-yards to each in cm.
local fm = 0     -- the states the last funnel pulled taut
local function funnel(i, eu, ev)
    local m, j = 0, i
    while j >= 0 do m = m + 1; chain[m] = j; j = gPred[j] end
    fm = m
    local s0 = chain[m]
    local su, sv = gEu[s0], gEv[s0]
    fu1[0], fv1[0], fu2[0], fv2[0], fp[0], xu[0], xv[0] = su, sv, su, sv, gPiece[s0], su, sv
    local np, G, lay = 0, L.G, door and L.d.walks and ns.GroundWalks.Lay    -- format 4 draws by its own points
    local sights = lay and L.d.format == 5
    for k = lay and 0 or m, 1, -1 do
        local st = chain[k]
        local gid = gPiece[st]
        if k < m then -- the portal into this state's piece, ends left then right of the walk
            local a1, a2, b1, b2 = gA1[st], gA2[st], gB1[st], gB2[st]
            local from = gPiece[chain[k + 1]]
            np = np + 1
            if door then a1, a2, b1, b2 = ns.GroundWalks.Free(G, a1, a2, b1, b2) end
            fu1[np], fv1[np], fu2[np], fv2[np], fp[np] = a1, a2, b1, b2, from
        end
        local _, _, c = pieceAttr(L, gid)
        if c >= 0 then
            local R, Cc = pieceCell(L, gid)
            local x, y = R * G + floor(c / G) + 0.5, Cc * G + c % G + 0.5
            np = np + 1
            fu1[np], fv1[np], fu2[np], fv2[np], fp[np] = x, y, x, y, gid
        end
    end
    if lay then np = lay(L, chain, m, gPiece, gA1, gA2, gB1, gB2, fu1, fv1, fu2, fv2, fp, su, sv, eu, ev) end
    np = np + 1
    fu1[np], fv1[np], fu2[np], fv2[np], fp[np] = eu, ev, eu, ev, gPiece[i]
    nc, cu[1], cv[1], ci[1], cm[1] = 1, su, sv, 0, 0
    local au, av, lu, lv, ru, rv, apex, li, ri, k, guard = su, sv, su, sv, su, sv, 0, 0, 0, 1, 0
    while k <= np do
        guard = guard + 1
        if guard > 8 * np + 64 then break end
        local plu, plv, pru, prv = fu1[k], fv1[k], fu2[k], fv2[k]
        local restart = false
        if triarea2(au, av, ru, rv, pru, prv) <= 0 then
            if (au == ru and av == rv) or triarea2(au, av, lu, lv, pru, prv) > 0 then
                ru, rv, ri = pru, prv, k
            else
                nc = nc + 1
                cu[nc], cv[nc], ci[nc] = lu, lv, li
                au, av, apex = lu, lv, li
                lu, lv, ru, rv, li, ri = au, av, au, av, apex, apex
                k = apex + 1
                restart = true
            end
        end
        if not restart then
            if triarea2(au, av, lu, lv, plu, plv) >= 0 then
                if (au == lu and av == lv) or triarea2(au, av, ru, rv, plu, plv) < 0 then
                    lu, lv, li = plu, plv, k
                else
                    nc = nc + 1
                    cu[nc], cv[nc], ci[nc] = ru, rv, ri
                    au, av, apex = ru, rv, ri
                    lu, lv, ru, rv, li, ri = au, av, au, av, apex, apex
                    k = apex + 1
                    restart = true
                end
            end
        end
        if not restart then k = k + 1 end
    end
    if cu[nc] ~= eu or cv[nc] ~= ev then
        nc = nc + 1
        cu[nc], cv[nc], ci[nc] = eu, ev, np
    end
    local land, inside, swim, pu, pv, c, cell, SF, factor = 0, 0, 0, su, sv, 1, L.cell, L.SF, L.factor
    gates = np
    for kk = 1, np do       -- the stretch before gate kk, on piece fp[kk], ends where the walk meets it (xu, xv)
        while c < nc and ci[c + 1] < kk do c = c + 1 end
        local u, v
        if c < nc and ci[c + 1] == kk then
            u, v = cu[c + 1], cv[c + 1]
        elseif fu1[kk] == fu2[kk] and fv1[kk] == fv2[kk] then
            u, v = fu1[kk], fv1[kk]
        else
            local u1, v1, u2, v2 = cu[c], cv[c], cu[min(c + 1, nc)], cv[min(c + 1, nc)]
            if fu1[kk] == fu2[kk] then
                local t = (u2 ~= u1) and (fu1[kk] - u1) / (u2 - u1) or 0
                u, v = fu1[kk], v1 + (v2 - v1) * t
            else
                local t = (v2 ~= v1) and (fv1[kk] - v1) / (v2 - v1) or 0
                u, v = u1 + (u2 - u1) * t, fv1[kk]
            end
        end
        local kd, f, cen = pieceAttr(L, fp[kk])
        local du, dv = u - pu, v - pv     -- a centre's factor is for a walk by the centre, not one drawn by sights
        local yd = sqrt(du * du + dv * dv) * cell * (sights and cen >= 0 and (kd >= 2 and SF or 1) or factor[f])
        if kd >= 2 then swim = swim + yd / SF elseif kd == 1 then inside = inside + yd else land = land + yd end
        if c < nc and ci[c + 1] == kk then cm[c + 1] = land + inside + swim * SF end
        pu, pv, xu[kk], xv[kk] = u, v, u, v
    end
    return land + inside + swim * SF, land, inside, swim
end
local function draw(i, u, v) door = true; local c, l, ins, sw = funnel(i, u, v); door = false; return c, l, ins, sw end
Gr.funnel, Gr.draw = funnel, draw
function Gr.corners() return nc, fm, gates end
-- The chain the funnel drew last kept in dc (its pieces and portals, the start at 0), or none (dc.n -1) when not found.
function Gr.keep(dc, found)
    dc.n = found and fm - 1 or -1
    for q = 0, dc.n do
        local st = chain[fm - q]
        dc.P[q], dc.A1[q], dc.A2[q], dc.B1[q], dc.B2[q] = gPiece[st], gA1[st], gA2[st], gB1[st], gB2[st]
    end
end

---------------------------------------------------------------------------------------------------------------
-- Joins: every node of a point's component with the walk to it.
local JH = 512
local jKey, jVal, jStamp, jNow = {}, {}, {}, 0
local jNb, jEst, jState, jTmp, jn = {}, {}, {}, {}, 0
local function jFind(nb)
    local h = nb % JH
    while jStamp[h] == jNow do
        if jKey[h] == nb then return jVal[h], h end
        h = (h + 1) % JH
    end
    return nil, h
end

-- the node sides of the join's cluster by piece, in slot order: made again when its slot holds another cluster
local jHead, jHeadAt, jNext, jIdx, jsl, jsk, jsm = {}, {}, {}, 0, -1, -1, nil
local function joinSettle(_, i)
    local gid = gPiece[i]
    local cl = floor(gid / PS)
    local sl = finish(L, decode(L, cl), cl)
    local sn, sp, m = C.snNode[sl], C.snPiece[sl], 0
    if jsl ~= sl or jsk ~= L.key + cl or jsm ~= L then
        jsl, jsk, jsm, jIdx = sl, L.key + cl, L, jIdx + 1
        for k = C.slotN[sl], 1, -1 do
            local lp = sp[k] % PS
            if jHeadAt[lp] ~= jIdx then jHeadAt[lp], jHead[lp] = jIdx, 0 end
            jNext[k], jHead[lp] = jHead[lp], k
        end
    end
    local k = jHeadAt[gid % PS] == jIdx and jHead[gid % PS] or 0
    while k > 0 do
        if sp[k] == gid then m = m + 1; jTmp[m] = sn[k] end
        k = jNext[k]
    end
    for t = 1, m do
        local nb = jTmp[t]
        local eu, ev = nodePoint(L, floor(nb / 2), nb % 2)
        local est = gG[i] + transit(L, gid, gEu[i], gEv[i], eu, ev)
        local j, h = jFind(nb)
        if not j then
            jn = jn + 1
            j, jStamp[h], jKey[h], jVal[h], jNb[jn], jEst[jn] = jn, jNow, nb, jn, nb, huge
        end
        if est < jEst[j] then jEst[j], jState[j] = est, i end
    end
end

-- yards of the step of entrance nd from its B side to its A side
local function stepYards(lm, nd)
    local _, _, _, _, _, side = nodeRec(lm, nd)
    if side == 1 or side == 2 then return lm.cell end
    return lm.cell * sqrt(2)
end

-- The last JOINS joins, kept: a plan's two searches join at the same points (the goal is the backward search's
-- source and the forward one's point; the data is two-way).
local JOINS, jcAt, jcL, jcG, jcX, jcY, jcN, jcD = 10, 0, {}, {}, {}, {}, {}, {}
local function joinsKept(lm, gid, x, y, into)
    for e = 1, JOINS do
        if jcL[e] == lm and jcG[e] == gid and jcX[e] == x and jcY[e] == y then
            local d, node, cost, land, inside, swim = jcD[e], into.node, into.cost, into.land, into.inside, into.swim
            for k = 1, jcN[e] do
                node[k], cost[k], land[k], inside[k], swim[k] = d[5 * k - 4], d[5 * k - 3], d[5 * k - 2], d[5 * k - 1], d[5 * k]
            end
            into.n = jcN[e]
            return true
        end
    end
end
local function joinsKeep(lm, gid, x, y, into)
    jcAt = jcAt % JOINS + 1
    local d = jcD[jcAt] or {}
    jcD[jcAt], jcL[jcAt], jcG[jcAt], jcX[jcAt], jcY[jcAt], jcN[jcAt] = d, lm, gid, x, y, into.n
    for k = 1, into.n do
        d[5 * k - 4], d[5 * k - 3], d[5 * k - 2], d[5 * k - 1], d[5 * k] = into.node[k], into.cost[k], into.land[k],
            into.inside[k], into.swim[k]
    end
end

-- A join from a point on piece gid of the search's landmass into list `into` (node, cost, land, inside, swim, n);
-- Each grid search has a budget of its own (the reference shares one per query: 16.7).
function Gr.joins(lm, gid, x, y, into)
    if joinsKept(lm, gid, x, y, into) then return end
    local u, v = (lm.x0 - x) / lm.cell, (lm.y0 - y) / lm.cell
    into.n, jNow, jn = 0, jNow + 1, 0
    gStart(lm, gid, u, v, floor(gid / PS))
    gRun(Gr.BUDGET, nil, joinSettle, nil)
    local node, cost, land, inside, swim = into.node, into.cost, into.land, into.inside, into.swim
    for k = 1, jn do
        local nb = jNb[k]
        local nd, b = floor(nb / 2), nb % 2
        local eu, ev = nodePoint(lm, nd, b)
        local c, l, ins, sw = funnel(jState[k], eu, ev)
        spend(1 + fm / 16)
        if b == 1 then local st = stepYards(lm, nd); c, l = c + st, l + st end
        local found
        for j = 1, into.n do if node[j] == nd then found = j end end
        if not found then into.n = into.n + 1; found = into.n; node[found], cost[found] = nd, huge end
        if c < cost[found] then
            cost[found], land[found], inside[found], swim[found] = c, l, ins, sw
        end
    end
    joinsKeep(lm, gid, x, y, into)
end

-- the direct walk between two points on known pieces (A* on the grid, bounded): cost, land, inside, swim or nil
function Gr.direct(lm, p1, x1, y1, p2, x2, y2)
    local u, v = (lm.x0 - x1) / lm.cell, (lm.y0 - y1) / lm.cell
    local gu, gv = (lm.x0 - x2) / lm.cell, (lm.y0 - y2) / lm.cell
    gStart(lm, p1, u, v, nil, gu, gv)
    local i = gRun(Gr.DIRECT, p2)
    if i then return funnel(i, gu, gv) end
end
-- The direct walks to one point standing on n pieces, from one A*: what it settles before a piece does not depend
-- on which piece it waits for. out[4i - 3 .. 4i]: Gr.direct's four answers for pieces[i]; false: none.
local dP, dS, dN, dLeft = {}, {}, 0, 0
local function directSettle(_, i)
    for k = 1, dN do
        if not dS[k] and dP[k] == gPiece[i] then dS[k], dLeft = i, dLeft - 1 end
    end
    return dLeft == 0
end
function Gr.directs(lm, p1, x1, y1, n, pieces, x2, y2, out)
    local gu, gv = (lm.x0 - x2) / lm.cell, (lm.y0 - y2) / lm.cell
    gStart(lm, p1, (lm.x0 - x1) / lm.cell, (lm.y0 - y1) / lm.cell, nil, gu, gv)
    dN, dLeft = n, n
    for k = 1, n do dP[k], dS[k], out[4 * k - 3] = pieces[k], false, false end
    gRun(Gr.DIRECT, nil, directSettle)
    for k = 1, n do
        if dS[k] then
            out[4 * k - 3], out[4 * k - 2], out[4 * k - 1], out[4 * k] = funnel(dS[k], gu, gv)
            spend(1 + fm / 16)  -- a pause between two walks pulled taut, as a join's
        end
    end
end

-- Appends to (wx, wy) [n + 1 ..] the corners of the walk from piece p1 at (u1, v1) to p2 at (u2, v2) (fine
-- coordinates), without its start; limit: the one cluster it stays in (a stretch inside a component), or nil;
-- straight: the corners straightened (GroundTaut), for a trail. Returns the new count. A point within 1e-6 yd of
-- the one before it is not added.
local function addPoint(lm, wx, wy, n, u, v)
    local x, y = lm.x0 - u * lm.cell, lm.y0 - v * lm.cell
    if n > 0 and abs(wx[n] - x) < 1e-6 and abs(wy[n] - y) < 1e-6 then return n end
    wx[n + 1], wy[n + 1] = x, y
    return n + 1
end
Gr.addPoint = addPoint

function Gr.leg(lm, wx, wy, n, p1, u1, v1, p2, u2, v2, limit, straight, dc)
    gStart(lm, dc and dc.P[0] or p1, u1, v1, not dc and limit or nil, u2, v2)
    for q = 1, dc and dc.n or 0 do     -- a chain kept (Gr.keep): its states again, with no search
        gPiece[q], gPred[q], gA1[q], gA2[q], gB1[q], gB2[q] = dc.P[q], q - 1, dc.A1[q], dc.A2[q], dc.B1[q], dc.B2[q]
    end
    local i = dc and dc.n or gRun(Gr.LEG, p2)
    if not i and limit then
        gStart(lm, p1, u1, v1, nil, u2, v2)
        i = gRun(Gr.LEG, p2)
    end
    if i then
        local c, l, ins, sw = draw(i, u2, v2)
        local m, U, V = nc, cu, cv
        if straight then m, U, V = ns.GroundTaut.Straight(lm, i, u2, v2, gLimit, c, l, ins, sw) end
        for k = 2, m do n = addPoint(lm, wx, wy, n, U[k], V[k]) end
        return n, c, l, ins, sw    -- and the walk as its search's chain draws it: cost, land, inside, swim
    end
    Gr.legMisses = Gr.legMisses + 1
    return addPoint(lm, wx, wy, n, u2, v2)
end

-- The stretch between two points on pieces of one cluster, following the grid inside it: n points in (wx, wy),
-- the first point included, and with wa: what each is reached on (wa) and left on (wd), the run-yards to it (wm); nil
-- when the two are not in one cluster or no walk inside it is found.
function Gr.refine(lm, x1, y1, p1, x2, y2, p2, wx, wy, wa, wd, wm)
    local cl = floor(p1 / PS)
    if floor(p2 / PS) ~= cl then return nil end
    local u1, v1 = (lm.x0 - x1) / lm.cell, (lm.y0 - y1) / lm.cell
    local u2, v2 = (lm.x0 - x2) / lm.cell, (lm.y0 - y2) / lm.cell
    gStart(lm, p1, u1, v1, cl, u2, v2)
    local i = gRun(Gr.LEG, p2)
    if not i then return nil end
    local T, n = ns.GroundTaut, 0
    local m, U, V = T.Straight(lm, i, u2, v2, cl, draw(i, u2, v2))
    for k = 1, m do n = addPoint(lm, wx, wy, n, U[k], V[k]); if wa then wa[n], wd[n], wm[n] = T.A[k], T.D[k], T.M[k] end end
    return n
end
