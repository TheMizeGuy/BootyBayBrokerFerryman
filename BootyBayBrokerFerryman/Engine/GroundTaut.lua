local ADDON, ns = ...

-- Straight lines (tools/terrain/FORMAT.md, "Straight lines"): the corners of a line the funnel drew joined straight
-- where a straight line crosses the data's portals and the line gets no longer, costlier or wetter for it (Straight),
-- and the entrances between the lines Ground.Detail walks crossed straight the same way (Free), never off the written
-- floor where the line replaced keeps on it. Only drawing asks: prices never see it.
local T = {}
ns.GroundTaut = T

local C, P, Gr = ns.GroundCodes, ns.GroundPortals, ns.GroundGrid
local floor, sqrt, abs, min, max = math.floor, math.sqrt, math.abs, math.min, math.max
local PS, pieceAttr, pieceCell, eachPortal, spend = C.PS, C.pieceAttr, C.pieceCell, P.eachPortal, C.spend
T.CAP, T.FREE = 48, true     -- the most corners, and pieces of a chain, a line straightened has; entrances freed

local tr, co, ct, cl, c1, c2, c3, c4 = { n = 0 }, {}, {}, {}, {}, {}, {}, {}
local Q, A1, A2, B1, B2, pa, pd, oU, oV, nIn, nSw = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
local cA, cD, cM, oA, oD, oM, W = {}, {}, {}, {}, {}, {}, {}
local L, chain, m, gP, gA1, gA2, gB1, gB2, limit

-- The floor (FORMAT.md, "Straight lines"): a line's samples, a quarter of a fine cell apart inside each stretch between
-- two gates of its funnel, each on the stretch's piece; a sample far is one no floor of that piece lies under or within
-- two quarters and a half of (GroundWalks.On). Whether every far sample of the line in xu, xv, fp [0..np] passes ok.
local Far, sU, sV, sP, fU, fV, nU, nV, sN, fN, nN, R2 = ns.GroundWalks.Far, {}, {}, {}, {}, {}, {}, {}, 0, 0, 0, 0
local head, link = {}, {}
local function far(xu, xv, fp, np, ok)
    for k = 1, np do
        local du, dv = xu[k] - xu[k - 1], xv[k] - xv[k - 1]
        local s = floor(sqrt(du * du + dv * dv) * 4)
        if not Far(L, fp[k], xu[k - 1], xv[k - 1], xu[k], xv[k], s, ok) then return false end
        spend(0.25 * s + 0.25)      -- a unit every 4 samples
    end
    return true
end
local function none() return false end
local function keepF(u, v) fN = fN + 1; fU[fN], fV[fN] = u, v; return true end
local function keepN(u, v) nN = nN + 1; nU[nN], nV[nN] = u, v; return true end
-- whether each far sample of the line the funnel drew last stands within 3 yd of one of the old line's (its stretches in
-- sU, sV, sP [0..sN])
local function onFloor(np)
    nN = 0
    far(Gr.xu, Gr.xv, Gr.fp, np, keepN)
    if nN == 0 then return true end
    fN = 0
    far(sU, sV, sP, sN, keepF)
    local r = sqrt(R2)      -- the old ones in squares of 3 yd: a new one looks in the nine around its own
    for k in pairs(head) do head[k] = nil end
    for q = 1, fN do local key = floor(fU[q] / r) * 1048576 + floor(fV[q] / r); link[q], head[key] = head[key] or 0, q end
    for i = 1, nN do
        local bu, bv, ok = floor(nU[i] / r), floor(nV[i] / r), false
        for du = -1, 1 do
            for dv = -1, 1 do
                local q = head[(bu + du) * 1048576 + bv + dv] or 0
                while q > 0 and not ok do ok, q = (fU[q] - nU[i]) ^ 2 + (fV[q] - nV[i]) ^ 2 < R2, link[q] end
            end
        end
        if not ok then return false end
        if i % 64 == 0 then spend(1) end
    end
    return true
end

-- a portal of the piece being walked that the line crosses inside its fine cells, after t0; at a cell corner, once,
-- the crossing of the other edge at the same point
local function cross(tr, other, a1, a2, b1, b2)
    if limit and floor(other / PS) ~= limit then return end
    local su, sv, du, dv, t, off = tr.su, tr.sv, tr.du, tr.dv
    if a1 == b1 and a2 == b2 then
        local dd = du * du + dv * dv
        if dd <= 0 then return end
        t = ((a1 - su) * du + (a2 - sv) * dv) / dd
        local eu, ev = su + du * t - a1, sv + dv * t - a2
        off = sqrt(eu * eu + ev * ev) - 0.5
    elseif a1 == b1 then
        if du == 0 then return end
        t = (a1 - su) / du
        local v = sv + dv * t
        off = max(min(a2, b2) - 0.5 - v, v - max(a2, b2) - 0.5)
    else
        if dv == 0 then return end
        t = (a2 - sv) / dv
        local u = su + du * t
        off = max(min(a1, b1) - 0.5 - u, u - max(a1, b1) - 0.5)
    end
    if off > 1e-9 or t > 1 + 1e-9 then return end
    if t > tr.t0 + 1e-9 or (t >= tr.t0 - 1e-9 and tr.lineU ~= nil and not tr.corner and (a1 == b1) ~= tr.lineU) then
        local n = tr.n + 1
        tr.n, co[n], ct[n], cl[n], c1[n], c2[n], c3[n], c4[n] = n, other, t, abs(b1 - a1) + abs(b2 - a2), a1, a2, b1, b2
    end
end

-- The straight line from (pu, pv) on piece p to (u, v) through the portals it crosses, each piece it enters and the
-- portal into it put in the new chain after k; never into an indoor piece unless ins nor a swum one unless sw. The
-- piece it ends on and the new k, or nil where it leaves a piece's cell by no portal or the chain passes T.CAP.
local function trace(p, pu, pv, u, v, k, ins, sw)
    local G = L.G
    tr.su, tr.sv, tr.du, tr.dv, tr.t0, tr.lineU, tr.corner = pu, pv, u - pu, v - pv, 0, nil, false
    local len = max(1e-9, sqrt(tr.du * tr.du + tr.dv * tr.dv))
    while true do
        spend(0.5)
        tr.n = 0
        eachPortal(L, p, cross, tr)
        local e, bt, bl = nil, 0, 0     -- the earliest crossing of a piece it may enter, then the narrowest portal
        for j = 1, tr.n do
            local kd = pieceAttr(L, co[j])
            if not (kd == 1 and not ins or kd >= 2 and not sw) and (not e or ct[j] < bt - 1e-9 or ct[j] <= bt + 1e-9 and cl[j] < bl) then
                e, bt, bl = j, ct[j], cl[j]
            end
        end
        local R, Cc = pieceCell(L, p)
        local tx = 1
        if tr.du > 0 then tx = min(tx, ((R + 1) * G - pu) / tr.du) elseif tr.du < 0 then tx = min(tx, (R * G - pu) / tr.du) end
        if tr.dv > 0 then tx = min(tx, ((Cc + 1) * G - pv) / tr.dv) elseif tr.dv < 0 then tx = min(tx, (Cc * G - pv) / tr.dv) end
        if not (e and bt <= tx + 1 / len) then return tx >= 1 - 1e-9 and p or nil, k end
        if k >= T.CAP then return nil end
        k = k + 1
        Q[k], A1[k], A2[k], B1[k], B2[k] = co[e], c1[e], c2[e], c3[e], c4[e]
        tr.lineU, tr.corner = c1[e] == c3[e], bt <= tr.t0 + 1e-9
        p, tr.t0 = co[e], bt
    end
end

-- what each of the n corners of the funnel's line is reached on and left on, and the run-yards to it: T.A, T.D, T.M
local function ends(n, a, d, mm)
    local ci, fp, cm = Gr.ci, Gr.fp, Gr.cm
    for c = 1, n do a[c], d[c], mm[c] = fp[ci[c]], c < n and fp[ci[c] + 1] or fp[ci[c]], cm[c] end
    T.A, T.D, T.M = a, d, mm
end
-- the new chain Q [0..k] drawn by the funnel from (u1, v1) to (u2, v2): its measure, land, inside and swum yards
local function drawQ(lm, k, u1, v1, u2, v2)
    Gr.start(lm, Q[0], u1, v1, nil, u2, v2)
    for q = 1, k do gP[q], Gr.gPred[q], gA1[q], gA2[q], gB1[q], gB2[q] = Q[q], q - 1, A1[q], A2[q], B1[q], B2[q] end
    return Gr.draw(k, u2, v2)
end

-- positions from + 1 .. to of the old chain (its start is position 1, state chain[m]) put in the new chain after k
local function splice(from, to, k)
    for q = from + 1, to do
        if k >= T.CAP then return nil end
        k = k + 1
        local st = chain[m - q + 1]
        Q[k], A1[k], A2[k], B1[k], B2[k] = gP[st], gA1[st], gA2[st], gB1[st], gB2[st]
    end
    return k
end

-- the straight line from corner a to corner b, the new chain standing at old position x after k: the old position
-- it ends on and the new k, or nil. It enters an indoor (swum) piece only where the old chain between the two has one.
local function try(a, b, k, x)
    k = splice(x, pd[a], k)
    if not k then return nil end
    local lo, hi = pd[a] - 1, pa[b]
    local e, k1 = trace(gP[chain[m - pd[a] + 1]], oU[a], oV[a], oU[b], oV[b], k, nIn[hi] > nIn[lo], nSw[hi] > nSw[lo])
    if e and e == gP[chain[m - pd[b] + 1]] then return pd[b], k1 end
    if e and e == gP[chain[m - pa[b] + 1]] then return pa[b], k1 end
end

-- The line Gr.funnel just drew to state i, ending at (eu, ev), straightened: its corners' count and their arrays (the
-- funnel's, or the old corners when nothing is kept; T.A, T.D, T.M say what each is reached and left on and the
-- run-yards to it). lim: the search's cluster or nil; oc, oi, os: the old line's measure, indoor and swum yards. The new
-- line is kept when it differs, its measure, indoor and swum yards are each at most the old's + 1e-6, and its fine
-- cells too.
function T.Straight(lm, i, eu, ev, lim, oc, _, oi, os)
    local cu, cv, ci, fp = Gr.cu, Gr.cv, Gr.ci, Gr.fp
    local nc, fm = Gr.corners()
    ends(nc, oA, oD, oM)
    if nc <= 2 or nc > T.CAP or fm > T.CAP then return nc, cu, cv end
    L, chain, m, gP, gA1, gA2, gB1, gB2, limit = lm, Gr.chain, fm, Gr.gPiece, Gr.gA1, Gr.gA2, Gr.gB1, Gr.gB2, lim
    local _, _, np = Gr.corners()
    sN, R2 = np, (3 / lm.cell) ^ 2
    for q = 0, np do sU[q], sV[q], sP[q] = Gr.xu[q], Gr.xv[q], Gr.fp[q] end
    nIn[0], nSw[0] = 0, 0
    for q = 1, m do
        local kd = pieceAttr(L, gP[chain[m - q + 1]])
        nIn[q], nSw[q] = nIn[q - 1] + (kd == 1 and 1 or 0), nSw[q - 1] + (kd >= 2 and 1 or 0)
    end
    local q, old = 1, 0     -- each corner's old position: the piece the walk reaches it on (pa), leaves it on (pd)
    for c = 1, nc do
        oU[c], oV[c] = cu[c], cv[c]
        if c > 1 then local du, dv = cu[c] - cu[c - 1], cv[c] - cv[c - 1]; old = old + sqrt(du * du + dv * dv) end
        if ci[c] > 0 then while gP[chain[m - q + 1]] ~= fp[ci[c]] and q < m do q = q + 1 end end
        pa[c] = q
        if c < nc then while gP[chain[m - q + 1]] ~= fp[ci[c] + 1] and q < m do q = q + 1 end end
        pd[c] = q
    end
    local k, x, a, used = 0, 1, 1, false
    Q[0] = gP[chain[m]]
    while a < nc do
        local best, bk, bx = a + 1, nil, nil
        for b = a + 2, nc do
            local y, k1 = try(a, b, k, x)
            if not y then break end
            best, bk, bx = b, k1, y
        end
        if bk and best < nc then bx, bk = try(a, best, k, x) end    -- the refused line wrote over the kept one's chain
        if bk then k, x, used = bk, bx, true else k, x = splice(x, pa[best], k), pa[best] end
        if not k then return nc, cu, cv end
        a = best
    end
    if not used or Q[k] ~= gP[i] then return nc, cu, cv end
    if k == m - 1 then
        local same = true
        for q2 = 1, k do
            local st = chain[m - q2]
            same = same and Q[q2] == gP[st] and A1[q2] == gA1[st] and A2[q2] == gA2[st] and B1[q2] == gB1[st] and B2[q2] == gB2[st]
        end
        if same then return nc, cu, cv end
    end
    local c, _, ins, sw = drawQ(lm, k, oU[1], oV[1], eu, ev)
    local len, n2, _, np2 = 0, Gr.corners()
    for c2 = 2, n2 do local du, dv = cu[c2] - cu[c2 - 1], cv[c2] - cv[c2 - 1]; len = len + sqrt(du * du + dv * dv) end
    if c <= oc + 1e-6 and ins <= oi + 1e-6 and sw <= os + 1e-6 and len <= old + 1e-6
        and (lm.d.format ~= 5 or onFloor(np2)) then ends(n2, cA, cD, cM); return n2, cu, cv end
    return nc, oU, oV
end

-- Detail's trail (Free): its points, what each is reached and left on; per entrance its span and what it saves
local X, Y, PA, PD, CL, CELL, X0, Y0
local E, SA, SB, SV, BT, KO, KN, KX, KY = {}, {}, {}, {}, {}, {}, {}, {}, {}
local function cluster(k) return floor((X0 - X[k]) / CELL / CL) * 65536 + floor((Y0 - Y[k]) / CELL / CL) end
-- the straight line from point a to point b of the trail, drawn by the funnel over the pieces it crosses, none indoor or
-- swum, with no more corners than the points it passes, no costlier and no longer than the trail there, and no sample
-- far from the floor: the yards saved
local function fits(a, b)
    local ua, va, ub, vb = (X0 - X[a]) / CELL, (Y0 - Y[a]) / CELL, (X0 - X[b]) / CELL, (Y0 - Y[b]) / CELL
    local e, k = trace(PD[a], ua, va, ub, vb, 0, false, false)
    if not (e and (e == PA[b] or e == PD[b])) then return false end
    Q[0] = PD[a]
    local c, _, ins, sw = drawQ(L, k, ua, va, ub, vb)
    local n2, cu, cv, len, old = Gr.corners(), Gr.cu, Gr.cv, 0, 0
    if n2 - 2 > b - a - 1 or ins > 0 or sw > 0 or c > W[b] - W[a] + 1e-6 then return false end
    for c2 = 2, n2 do local du, dv = cu[c2] - cu[c2 - 1], cv[c2] - cv[c2 - 1]; len = len + sqrt(du * du + dv * dv) end
    for q = a + 1, b do old = old + sqrt((X[q] - X[q - 1]) ^ 2 + (Y[q] - Y[q - 1]) ^ 2) end
    if len * CELL > old + 1e-6 or L.d.format == 5 and not far(Gr.xu, Gr.xv, Gr.fp, select(3, Gr.corners()), none) then
        return false
    end
    return old - len * CELL
end

-- Ground.Detail's trail x, y [1..n] with its entrances crossed straight (FORMAT.md, "Straight lines"). An entrance is
-- two points straddling a cluster border, the end of one walked line and the start of the next (WK[k]: the stretch from
-- point k is a walked line; ST[k]: a line starts at point k; PA, PD: what each point is reached and left on; PM: the
-- run-yards to it from its line's start). Its span joins a point of the line before (from its start) to a point of the
-- line after: for each start the farthest end a straight line reaches before the first it does not, and of those that
-- fit, the one that saves the most. Of two spans that overlap the pair saving more is kept. at (optional): at.i, the
-- stretch the player is on; a span starts after it, read again before the points freed are taken out in place, with no
-- pause between that and the return: the trail up to the end of that stretch is kept. Returns the new count and whether
-- a span was kept.
function T.Free(lm, x, y, n, pa_, pd_, PM, ST, WK, at)
    if T.CAP <= 0 or not T.FREE then return n, false end
    L, limit, X, Y, PA, PD, CL, CELL, X0, Y0 = lm, nil, x, y, pa_, pd_, lm.CL, lm.cell, lm.x0, lm.y0
    gP, gA1, gA2, gB1, gB2 = Gr.gPiece, Gr.gA1, Gr.gA2, Gr.gB1, Gr.gB2
    local ne, out, a, kn, from = 0, 1, 1, 0, at and at.i + 1 or 1
    W[1] = 0
    for k = 1, n - 1 do     -- W: the run-yards along walked lines, an entrance step at its yards
        if k % 32 == 0 then spend(1) end
        if WK[k] then W[k + 1] = W[k] + PM[k + 1] - (ST[k] and 0 or PM[k])
        elseif k > 1 and WK[k - 1] and WK[k + 1] and cluster(k) ~= cluster(k + 1) then
            W[k + 1], ne = W[k] + sqrt((x[k + 1] - x[k]) ^ 2 + (y[k + 1] - y[k]) ^ 2), ne + 1
            E[ne] = k
        else W[k + 1] = 0 end
    end
    for e = 1, ne do
        local k, s, f = E[e], E[e] - 1, E[e] + 2
        while not ST[s] do s = s - 1 end
        while f < n and not ST[f] do f = f + 1 end
        SA[e], SB[e], SV[e] = false, false, 0
        for p = max(s, from), k - 1 do
            local ua, va, last = (X0 - x[p]) / CELL, (Y0 - y[p]) / CELL, nil
            for b = k + 2, f do
                local e2 = trace(PD[p], ua, va, (X0 - x[b]) / CELL, (Y0 - y[b]) / CELL, 0, false, false)
                if not (e2 and (e2 == PA[b] or e2 == PD[b])) then break end
                last = b
            end
            for b = last or 0, k + 2, -1 do
                local v = fits(p, b)
                if v and v > SV[e] then     -- its corners kept
                    SA[e], SB[e], SV[e], KO[e], KN[e] = p, b, v, kn, Gr.corners() - 2
                    for c = 2, KN[e] + 1 do kn = kn + 1; KX[kn], KY[kn] = X0 - Gr.cu[c] * CELL, Y0 - Gr.cv[c] * CELL end
                end
                if v then break end
            end
        end
        -- BT[e]: the most saved by the spans of entrances 1 .. e that do not overlap
        local prior = e > 1 and SA[e] and SB[e - 1] and SA[e] < SB[e - 1] and (BT[e - 2] or 0) or BT[e - 1] or 0
        BT[e] = max(BT[e - 1] or 0, SV[e] + prior)
    end
    for e = ne, 1, -1 do        -- the spans kept, from the last
        if BT[e] > (BT[e - 1] or 0) then
            if e > 1 and SA[e] and SB[e - 1] and SA[e] < SB[e - 1] then SA[e - 1] = false end
        else SA[e] = false end
    end
    local e, kept = 1, false
    from = at and at.i + 1 or 1
    while a < n do
        while e <= ne and (not SA[e] or SA[e] < a) do e = e + 1 end
        local best = a + 1
        if e <= ne and SA[e] == a and a >= from then
            best, kept = SB[e], true
            for c = KO[e] + 1, KO[e] + KN[e] do out = out + 1; x[out], y[out] = KX[c], KY[c] end
        end
        out = out + 1
        x[out], y[out] = x[best], y[best]
        a = best
    end
    return out, kept
end
