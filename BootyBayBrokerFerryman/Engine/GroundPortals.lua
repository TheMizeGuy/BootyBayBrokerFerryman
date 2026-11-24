local ADDON, ns = ...

-- Portals of a piece (listed once per decoded cluster and kept in its slot) and where a point stands.
local P = {}
ns.GroundPortals = P

local C = ns.GroundCodes
local floor, sqrt, abs, max, min, huge = math.floor, math.sqrt, math.abs, math.max, math.min, math.huge
local P2, PS = C.P2, C.PS
local at, rb, rh, rg, bitsFor = C.at, C.rb, C.rh, C.rg, C.bitsFor
local decode, finish, cellAt, slotAt, pieceAttr, pieceCell = C.decode, C.finish, C.cellAt, C.slotAt, C.pieceAttr,
    C.pieceCell
local cEdge, cRas, slotCorner, cInfo = C.cEdge, C.cRas, C.slotCorner, C.cInfo
local pStart, pList, pCount, pAttr = C.pStart, C.pList, C.pCount, C.pAttr
P.SNAP, P.CANDIDATES, P.LOC_OTHER, P.LOC_INDOORS, P.LOC_TRACED, P.TRACE_SLIP, P.DRY = 50, 4, 5, 10, 100, 4, true

-- The portals being listed: the other piece and the two ends; gen counts the lists begun.
local SO, SA, SB, SC, SD, sn, gen = {}, {}, {}, {}, {}, 0, 0
local function put(other, a1, a2, b1, b2)
    sn = sn + 1
    SO[sn], SA[sn], SB[sn], SC[sn], SD[sn] = other, a1, a2, b1, b2
end
-- ends ordered left, then right, as seen walking through the portal in direction (du, dv)
local function emit(other, du, dv, a1, a2, b1, b2)
    if du * (b2 - a2) - dv * (b1 - a1) > 0 then put(other, b1, b2, a1, a2) else put(other, a1, a2, b1, b2) end
end

-- the model walk on piece gid from (u1, v1) to (u2, v2), run-yards: straight, or through its centre
function P.transit(L, gid, u1, v1, u2, v2)
    local _, f, c = pieceAttr(L, gid)
    local d
    if c < 0 then
        local du, dv = u2 - u1, v2 - v1
        d = sqrt(du * du + dv * dv)
    else
        local R, Cc = pieceCell(L, gid)
        local cv = c % L.G
        local cu, cw = R * L.G + (c - cv) / L.G + 0.5, Cc * L.G + cv + 0.5
        local a, b, e, g = cu - u1, cw - v1, u2 - cu, v2 - cw
        d = sqrt(a * a + b * b) + sqrt(e * e + g * g)
    end
    return d * (L.cell * L.factor[f])
end

-- Lists the portals of piece gid, in the reference reader's order: its cell's south, east, north and west edge
-- lists, the portals inside its cell when the cell is split, the corner portals touching it.
local function list(L, gid)
    sn = 0
    local s, G, K, pb = L.d.blocks, L.G, L.K, L.pb
    local cl = (gid - gid % PS) / PS
    local R, Cc = pieceCell(L, gid)
    local _, _, _, first = cellAt(L, R, Cc)
    local pi = gid - first
    for pass = 1, 4 do
        local aR, aC, sd, mineA = R, Cc, (pass + 1) % 2, pass <= 2
        if pass == 3 then aR = R - 1 elseif pass == 4 then aC = Cc - 1 end
        local asl, aq, acl, afirst, an = cellAt(L, aR, aC)
        if asl then
            asl = finish(L, asl, acl)
            local bR, bC = aR + (sd == 0 and 1 or 0), aC + (sd == 1 and 1 or 0)
            local e = cEdge[asl * 144 + aq + 1]
            local off = sd == 0 and floor(e / P2[23]) or e % P2[23]
            if off > 0 then
                local border = floor(bR / K) ~= floor(aR / K) or floor(bC / K) ~= floor(aC / K)
                local _, _, _, bfirst, bn = cellAt(L, bR, bC)
                at(s, off - 1)
                local ec = rh(L.hEdge[C.edgeContext(an, not border and bn)])
                if ec ~= 0 and bfirst then
                    local line, along = (aR + 1) * G, aC * G
                    if sd == 1 then line, along = (aC + 1) * G, aR * G end
                    local dir = mineA and 1 or -1
                    local du, dv = sd == 0 and dir or 0, sd == 1 and dir or 0
                    local lo, hi, n, wa, wb = 0, G - 1, 1, 0, 0
                    if ec == 2 then
                        n, wa, wb = rh(L.hNport), bitsFor(an), bitsFor(bn)
                        if border then if rb(1) == 1 then wb = 5 else wa, wb = 0, 0 end end
                    end
                    for k = 1, n do
                        local ia, ib = 0, 0
                        if ec == 2 then
                            lo = rh(L.hPort[k == 1 and 0 or 1])
                            hi = lo % G
                            lo = (lo - hi) / G
                            ia = rb(wa)
                            ib = rb(wb)
                        end
                        if (mineA and ia == pi) or (not mineA and ib == pi) then
                            local other = mineA and (bfirst + ib) or (afirst + ia)
                            if sd == 0 then emit(other, du, dv, line, along + lo + 0.5, line, along + hi + 0.5)
                            else emit(other, du, dv, along + lo + 0.5, line, along + hi + 0.5, line) end
                        end
                    end
                end
            end
        end
    end
    -- portals inside its cell when the cell is split into quadrants (finish found where they start)
    local sl = finish(L, decode(L, cl), cl)
    local _, _, _, myq = pieceAttr(L, gid)
    local pos = floor(cRas[sl * 144 + myq + 1] / P2[23]) - 1
    if pos >= 0 then
        local wr, H = bitsFor(cInfo[sl * 144 + myq + 1] % 64), G / 2
        at(s, pos)
        for _ = 1, rg() do
            local t, lo, hi = rb(2), 0, 0
            if t < 2 then lo = rb(pb); hi = rb(pb) end
            local ia = rb(wr)
            local ib = rb(wr)
            if ia == pi or ib == pi then
                local other, dir = first + (ia == pi and ib or ia), ia == pi and 1 or -1
                if t == 0 then emit(other, dir, 0, R * G + H, Cc * G + lo + 0.5, R * G + H, Cc * G + hi + 0.5)
                elseif t == 1 then emit(other, 0, dir, R * G + lo + 0.5, Cc * G + H, R * G + hi + 0.5, Cc * G + H)
                else put(other, R * G + H, Cc * G + H, R * G + H, Cc * G + H) end
            end
        end
    end
    -- corners: the lists of the clusters that hold a cell whose corner portal can touch it (its own cell, or the
    -- cells north-west and north-east of it, holding the north piece), in the reference's order of clusters
    local cc = cl % L.cCols
    local cr = (cl - cc) / L.cCols
    local nr, wc, ec, mr, mc = floor((R - 1) / K), floor((Cc - 1) / K), floor((Cc + 1) / K), floor(R / K), floor(Cc / K)
    for k = 0, 5 do
        local ocr, occ = cr + (k < 3 and -1 or 0), cc + (k % 3) - 1
        local osl = ((ocr == mr and occ == mc) or (ocr == nr and (occ == wc or occ == ec))) and slotAt(L, ocr, occ)
        if osl then
            osl = finish(L, osl, ocr * L.cCols + occ)
            at(s, slotCorner[osl])
            if slotCorner[osl] >= 0 and rb(1) == 1 then
                for _ = 0, rb(8) do
                    local q = rb(L.qb)
                    local se = rb(1)
                    local px = rb(5)
                    local py = rb(5)
                    local p = C.pos()
                    local qc = q % K
                    local xR, xC = ocr * K + (q - qc) / K, occ * K + qc
                    local yR, yC = xR + 1, se == 0 and xC + 1 or xC - 1
                    local cu, cv = (xR + 1) * G, se == 0 and (xC + 1) * G or xC * G
                    local _, _, _, xf = cellAt(L, xR, xC)
                    local _, _, _, yf = cellAt(L, yR, yC)
                    if xf and yf then
                        if xf + px == gid then put(yf + py, cu, cv, cu, cv)
                        elseif yf + py == gid then put(xf + px, cu, cv, cu, cv) end
                    end
                    at(s, p)
                end
            end
        end
    end
    return R * G, Cc * G
end

-- Calls fn(ctx, other, u1, v1, u2, v2) for every portal of piece gid: its two ends in fine coordinates, left then
-- right as seen crossing from gid into the other piece. A portal is kept as one number: the other piece and the
-- ends in half fine cells from its cell's corner. fn must not list portals itself.
local function eachPortal(L, gid, fn, ctx)
    local i = gid % PS
    local cl = (gid - i) / PS
    local sl = decode(L, cl)
    local st = pStart[sl][i + 1]
    if st == 0 then
        -- a job may pause while listing, and a call in between list again: then the list is made again
        local ru, rv, g
        repeat
            gen = gen + 1
            g = gen
            ru, rv = list(L, gid)
            sl = decode(L, cl)
        until gen == g
        st = pStart[sl][i + 1]
        if st == 0 then
            local out, k0 = pList[sl], pCount[sl]
            for k = 1, sn do
                out[k0 + k] = SO[k] * 16777216 + (((SA[k] - ru) * 128 + (SB[k] - rv) * 2) * 64
                    + (SC[k] - ru) * 2) * 64 + (SD[k] - rv) * 2
            end
            st, pCount[sl] = (k0 + 1) * 1024 + sn, k0 + sn
            pStart[sl][i + 1] = st
        end
        C.spend(1)
    end
    local q = floor(pAttr[sl][i + 1] / P2[33])
    local G, K, cc = L.G, L.K, cl % L.cCols
    local qc = q % K
    local ru, rv = ((cl - cc) / L.cCols * K + (q - qc) / K) * G, (cc * K + qc) * G
    local n, out = st % 1024, pList[sl]
    for k = (st - n) / 1024, (st - n) / 1024 + n - 1 do
        local e = out[k]
        local t0 = e % 16777216
        local d = t0 % 64
        local t = (t0 - d) / 64
        local c = t % 64
        t = (t - c) / 64
        local b = t % 64
        fn(ctx, (e - t0) / 16777216, ru + (t - b) / 128, rv + b / 2, ru + c / 2, rv + d / 2)
    end
end
P.eachPortal = eachPortal

-- the two pieces are the same or share a portal
local hit
local function Same(want, other) if other == want then hit = true end end
function P.Near(L, r1, r2)
    if r1 == r2 then return true end
    hit = false
    eachPortal(L, r1, Same, r2)
    return hit
end

---------------------------------------------------------------------------------------------------------------
-- Locate (FORMAT.md, "Reader API"). The previous piece's neighbourhood is a small stamped hash of pieces.
local HN = 1024
local hKey, hVal, hStamp, hNow, prevL, prevQ, hFill = {}, {}, {}, 0, {}, 0, 0
local function hop(piece)
    local h = (piece % PS * 37 + (piece - piece % PS) / PS) % HN
    while hStamp[h] == hNow do
        if hKey[h] == piece then return hVal[h], h end
        h = (h + 1) % HN
    end
    return nil, h
end
local function notePrev(n, other)
    local v, h = hop(other)
    if not v and hFill < HN / 2 then     -- the neighbourhood two portals out holds about 210 pieces at most
        hFill = hFill + 1
        hStamp[h], hKey[h], hVal[h] = hNow, other, n
        if n == 1 then prevQ = prevQ + 1; prevL[prevQ] = other end
    end
end

-- the 4 x 4 owner raster at bit position pos (a two-level quadtree) into out[0..15]
local function readRaster(s, pos, wr, out)
    at(s, pos)
    if rb(1) == 1 then
        local o = rb(wr)
        for sq = 0, 15 do out[sq] = o end
        return
    end
    for qr = 0, 2, 2 do
        for qc = 0, 2, 2 do
            if rb(1) == 1 then
                local o = rb(wr)
                out[qr * 4 + qc], out[qr * 4 + qc + 1], out[qr * 4 + qc + 4], out[qr * 4 + qc + 5] = o, o, o, o
            else
                for a = 0, 1 do for c = 0, 1 do out[(qr + a) * 4 + qc + c] = rb(wr) end end
            end
        end
    end
end
P.readRaster = readRaster

-- the earliest portal of the piece being walked that the traced line crosses after t0, within tol fine cells
local tr = {}
local function traceCross(tr, other, a1, a2, b1, b2)
    local su, sv, du, dv, tol = tr.su, tr.sv, tr.du, tr.dv, tr.tol
    local t, off
    if a1 == b1 and a2 == b2 then
        local dd = du * du + dv * dv
        if dd <= 0 then return end
        t = ((a1 - su) * du + (a2 - sv) * dv) / dd
        local eu, ev = su + du * t - a1, sv + dv * t - a2
        off = max(0, sqrt(eu * eu + ev * ev) - 0.5)
    elseif a1 == b1 then
        if du == 0 then return end
        t = (a1 - su) / du
        local v = sv + dv * t
        off = max(0, min(a2, b2) - 0.5 - v, v - max(a2, b2) - 0.5)
    else
        if dv == 0 then return end
        t = (a2 - sv) / dv
        local u = su + du * t
        off = max(0, min(a1, b1) - 0.5 - u, u - max(a1, b1) - 0.5)
    end
    if off > tol then return end
    if tr.ind ~= nil and (pieceAttr(tr.L, other) % 2 == 1) ~= tr.ind then off = off + 1 end
    local len = abs(b1 - a1) + abs(b2 - a2)
    if t > tr.t0 + 1e-9 and t <= 1 + 1e-9 and (not tr.best or t < tr.bt - 1e-9 or (t <= tr.bt + 1e-9 and
        (off < tr.boff - 1e-9 or (off <= tr.boff + 1e-9 and len < tr.blen)))) then
        tr.best, tr.bt, tr.boff, tr.blen = other, t, off, len
    end
end

-- the piece the walker stands on at (u, v), followed from piece p at (pu, pv) along the straight line, or nil
local function trace(L, p, pu, pv, u, v, tol, ind)
    if ind == nil then tr.ind = nil else tr.ind = ind and true or false end
    tr.L, tr.su, tr.sv, tr.du, tr.dv, tr.tol, tr.t0 = L, pu, pv, u - pu, v - pv, tol, 0
    local G = L.G
    for _ = 1, 64 do
        tr.best = nil
        eachPortal(L, p, traceCross, tr)
        local R, Cc = pieceCell(L, p)
        local tx = 1
        if tr.du > 0 then tx = min(tx, ((R + 1) * G - pu) / tr.du) elseif tr.du < 0 then tx = min(tx, (R * G - pu) / tr.du) end
        if tr.dv > 0 then tx = min(tx, ((Cc + 1) * G - pv) / tr.dv) elseif tr.dv < 0 then tx = min(tx, (Cc * G - pv) / tr.dv) end
        local len = max(1e-9, sqrt(tr.du * tr.du + tr.dv * tr.dv))
        if tr.best and tr.bt <= tx + (tol + 1) / len then
            p, tr.t0 = tr.best, tr.bt
        else
            -- no portal crossed: the piece, when the line ends in its cell or just past it
            local eu, ev = max(0, R * G - u, u - (R + 1) * G), max(0, Cc * G - v, v - (Cc + 1) * G)
            local cu, cv = pu + tr.du * tr.t0, pv + tr.dv * tr.t0
            local su, sv = max(0, R * G - cu, cu - (R + 1) * G), max(0, Cc * G - cv, cv - (Cc + 1) * G)
            local slip = P.TRACE_SLIP + min(P.TRACE_SLIP, sqrt(su * su + sv * sv))
            if tx >= 1 or eu * eu + ev * ev <= slip * slip then return p end
            return nil
        end
    end
    return nil
end

local cand, score, offs, mine, rown, pbest, und, lgen = {}, {}, {}, {}, {}, {}, {}, 0
-- squared fine cells from (u, v) to the cell of piece p
local function off(L, p, u, v)
    local R, Cc = pieceCell(L, p)
    local G = L.G
    local eu, ev = max(0, R * G - u, u - (R + 1) * G), max(0, Cc * G - v, v - (Cc + 1) * G)
    return eu * eu + ev * ev
end

local function locate(L, x, y, indoors, prev, px, py, found)
    local traced, sure
    -- history is the previous look's only while the point and that look stand within the slip of its piece's cell
    if prev and (off(L, prev, (L.x0 - x) / L.cell, (L.y0 - y) / L.cell) > P.TRACE_SLIP * P.TRACE_SLIP
        or px and off(L, prev, (L.x0 - px) / L.cell, (L.y0 - py) / L.cell) > P.TRACE_SLIP * P.TRACE_SLIP) then
        prev, px, py = nil, nil, nil
    end
    if prev and px then
        local pu, pv = (L.x0 - px) / L.cell, (L.y0 - py) / L.cell
        local u, v = (L.x0 - x) / L.cell, (L.y0 - y) / L.cell
        traced = trace(L, prev, pu, pv, u, v, 1, indoors) or trace(L, prev, pu, pv, u, v, 3, indoors)
    end
    if prev then
        hNow, prevQ, hFill = hNow + 1, 0, 1
        local _, h = hop(prev)
        hStamp[h], hKey[h], hVal[h] = hNow, prev, 0
        eachPortal(L, prev, notePrev, 1)
        for i = 1, prevQ do eachPortal(L, prevL[i], notePrev, 2) end
    end
    local bonus, cell, G, s = P.LOC_TRACED, L.cell, L.G, L.d.blocks
    local u, v = (L.x0 - x) / cell, (L.y0 - y) / cell
    local R0, C0, nc, sub = floor(u / G), floor(v / G), 0, G / 4
    for ring = 0, floor(P.SNAP / (cell * G)) + 1 do
        for dR = -ring, ring do
            for dC = -ring, ring do
                local R, Cc, sl, q, _, first, npc = R0 + dR, C0 + dC, nil
                if max(abs(dR), abs(dC)) == ring then sl, q, _, first, npc = cellAt(L, R, Cc) end
                if sl then
                    if npc > 1 then readRaster(s, cRas[sl * 144 + q + 1] % P2[23], bitsFor(npc), rown)
                    else for sq = 0, 15 do rown[sq] = 0 end end
                    local here = R == R0 and Cc == C0
                    for pi = 0, npc - 1 do pbest[pi] = huge end
                    for sq = 0, 15 do
                        local sc = sq % 4
                        local r0, c0 = R * G + (sq - sc) / 4 * sub, Cc * G + sc * sub
                        local er, ec = max(0, r0 - u, u - (r0 + sub)), max(0, c0 - v, v - (c0 + sub))
                        local dd, o = sqrt(er * er + ec * ec) * cell, rown[sq]
                        if dd < pbest[o] then pbest[o] = dd end
                    end
                    -- with floors in the data (format 5) the pieces whose floor lies nearest the point, within a
                    -- yard of it, are under it, and the piece the raster names only when none does
                    local floors, sole = false, 0
                    for pi = 0, here and npc > 1 and npc - 1 or -1 do
                        und[pi] = ns.GroundWalks.On(L, first + pi, u, v)
                        if und[pi] and (not floors or und[pi] < floors) then floors = und[pi] end
                    end
                    for pi = 0, floors and npc - 1 or -1 do sole = sole + (und[pi] == floors and 1 or 0) end
                    if here then sure = L.d.format == 5 and (npc == 1 or floors and true) end
                    for pi = 0, npc - 1 do
                        local gid, best, sc = first + pi, pbest[pi], 20 + pbest[pi]
                        if floors then best = und[pi] == floors and 0 or max(best, cell) end
                        if here and best == 0 then sc = 0 elseif here then sc = P.LOC_OTHER + 0.1 * min(best, 30) end
                        if sc < huge and (here or best <= P.SNAP) then
                            -- the client's word on indoors tells pieces apart, not the one piece whose floor is there
                            if indoors ~= nil and (pieceAttr(L, gid) % 2 == 1) ~= (indoors and true or false)
                                and not (sole == 1 and sc == 0) then
                                sc = sc + P.LOC_INDOORS
                            end
                            if traced then
                                if gid == traced then sc = sc - bonus end
                            elseif prev then
                                local n = hop(gid)
                                if n then sc = sc - (n == 0 and 30 or n == 1 and 25 or 15) end
                            end
                            nc = nc + 1
                            cand[nc], score[nc], offs[nc], mine[nc] = gid, sc + pi * 1e-3, here and 0 or best, here and (best == 0 and 2 or 1)
                        end
                    end
                end
            end
        end
        if nc > 0 and ring >= 1 then break end
    end
    -- the followed piece (or the previous one) is a candidate even where the raster names it nowhere
    local keep, keepScore = traced, -bonus
    if not traced and prev then keep, keepScore = prev, P.LOC_OTHER - 30 end
    if keep then
        local have = false
        for j = 1, nc do if cand[j] == keep then have = true end end
        if not have then nc = nc + 1; cand[nc], score[nc], offs[nc], mine[nc] = keep, keepScore, 0, false end
    end
    local n, snap, own, under = 0, nil, 0, 0
    for _ = 1, min(nc, P.CANDIDATES) do
        local b = nil
        for j = 1, nc do
            if score[j] < huge and (not b or score[j] < score[b] or (score[j] == score[b] and cand[j] < cand[b])) then
                b = j
            end
        end
        if not b then break end; n = n + 1    -- a look made during a pause took the scratch: P.Locate redoes it
        found[n] = cand[b]
        if n == 1 then snap = offs[b] end
        if mine[b] and own == n - 1 then own = n end
        if mine[b] == 2 and under == n - 1 then under = n end
        -- water's floor is its surface: a point under it may lie on the bank beside it, so the look is not sure
        if mine[b] == 2 and under == n and P.DRY and pieceAttr(L, cand[b]) >= 2 then sure = false end
        score[b] = huge
    end
    return n, snap, under > 0 and under or own > 0 and own or n, sure and under > 0
end
-- The pieces the point may stand on, best first, in found[1..n], the yards it lies off the ground (nil: none),
-- own: the pieces that lead and lie under the point (the one the raster names; with floors in the data those whose
-- floor does), else its cell's pieces, which lead (none: n), and sure: the data's floor says so. A Locate
-- that a job paused in is made again when another ran meanwhile: they share these arrays.
function P.Locate(L, x, y, indoors, prev, px, py, found)
    local n, snap, own, sure, g
    repeat
        lgen = lgen + 1
        g = lgen
        n, snap, own, sure = locate(L, x, y, indoors, prev, px, py, found)
    until lgen == g
    return n, snap, own, sure
end
