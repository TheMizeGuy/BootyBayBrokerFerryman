local ADDON, ns = ...

-- The shipped and measured travel data as stops and links, and one request's graph (INTERFACES 3.6, 4.4).
local M = {}
ns.Net = M

M.CAUTION, M.LANDING_PAD, M.BOARD_FLIGHT = { 3, 8 }, 60, 8
local floor, sqrt, max, abs = math.floor, math.sqrt, math.max, math.abs
local NONE, SERVICE, LINK_KIND = {}, { [0] = "no", [1] = "yes", [2] = "likely" }, { [4] = "lift", [5] = "portal" }
local D, SH, ME, Clock
local S, A = 0, 0
local sKind, sMass, sX, sY, sZ, sFac, sRef, sArea, aMass, aX, aY, aZ, aKind, fFirst, fTo, fYards
local xYards, xJumps, vCross, vRow, vPrior, vBase, vNC, nodeStop, pathVessel, spellID, itemSpell
local entMap, entDoor, landRow, held, bindSp, jOff
local function NewClosure() return { first = {}, to = {}, sec = {}, yards = {}, prev = {}, hops = {}, led = {} } end
local CL, CA = NewClosure(), NewClosure()
local Hp, G, ALT = false, false, false
local legRide, depOff = {}, {}
M.PERIOD_SLACK = 0.015

function M.Load(data, shapes, measured)
    local U, C = ns.Bytes.U, ns.Bytes.C
    if type(data) ~= "table" or data.version ~= 1 then return false, "network.version" end
    local st, fl, xs, pl, ar, jn = data.stops, data.flights, data.crossings, data.places, data.stopAreas, data.joins
    if type(st) ~= "string" or type(fl) ~= "string" or type(xs) ~= "string" or type(pl) ~= "string" or type(ar) ~= "string"
        or type(jn) ~= "string" or #st % 15 ~= 0 or #fl % 13 ~= 0 or #xs % 10 ~= 0 or #pl % 12 ~= 0 or #ar * 5 ~= #st then
        return false, "network.records"
    end
    if type(measured) ~= "table" or measured.build ~= data.build then return false, "measured.build" end
    local n, rows, tr = #st / 15, {}, measured.tram
    for _, r in ipairs(measured.vessels) do rows[r.path] = r end
    for _, v in ipairs(data.vessels) do -- a ride per call, each positive, and a period that is their sum and the waits
        local r, sum = rows[v.path], v.wait
        local ok = r and type(r.rides) == "table" and #r.rides == #v.calls / 3 and type(r.period) == "number"
        for c = 1, ok and #r.rides or 0 do
            local s = r.rides[c]
            if type(s) == "number" and s > 0 then sum = sum + s else ok = false end
        end
        if not (ok and abs(sum - r.period) <= 0.1) then return false, "measured.vessel:" .. v.path end
    end
    local named = { tr.stormwind, tr.ironforge }
    for j, d in ipairs(tr.doors) do named[2 + j] = d.stop end
    for j = 1, 2 + #tr.doors do
        local i = named[j]
        if type(i) ~= "number" or i < 1 or i > n or i ~= floor(i) then return false, "measured.stop:" .. tostring(i) end
    end
    D, SH, ME, Clock, S = data, shapes, measured, ns.Clock, n
    sKind, sMass, sX, sY, sZ, sFac, sRef, sArea, nodeStop = {}, {}, {}, {}, {}, {}, {}, {}, {}
    for i = 1, n do
        local o = i * 15 - 14
        sKind[i], sMass[i], sX[i], sY[i], sZ[i] = U(st, o, 1), U(st, o + 1, 2), C(st, o + 3), C(st, o + 6), C(st, o + 9)
        sFac[i], sRef[i], sArea[i] = U(st, o + 12, 1), U(st, o + 13, 2), U(ar, i * 3 - 2, 3)
        if sKind[i] == 1 then nodeStop[sRef[i]] = i end
    end
    fFirst, fTo, fYards = {}, {}, {}
    local nf, at = #fl / 13, 1
    for k = 1, nf do -- sorted by departure, so each stop's flights are one run
        local o = k * 13 - 12
        while at <= U(fl, o, 2) do fFirst[at], at = k, at + 1 end
        fTo[k], fYards[k] = U(fl, o + 2, 2), U(fl, o + 4, 3)
    end
    while at <= n + 1 do fFirst[at], at = nf + 1, at + 1 end
    jOff, at = {}, 1 -- record k's row of junctions holds one field per flight leaving its destination
    for k = 1, nf do jOff[k], at = at, at + 2 * (fFirst[fTo[k] + 1] - fFirst[fTo[k]]) end
    if at ~= #jn + 1 then return false, "network.records" end
    xYards, xJumps, vCross, vRow, vPrior, vBase, vNC, pathVessel = {}, {}, {}, {}, {}, {}, {}, {}
    for k = 1, #xs / 10 do
        local o = k * 10 - 9
        vCross[U(xs, o, 1)], xYards[k], xJumps[k] = k - U(xs, o + 1, 1) + 1, U(xs, o + 6, 3), U(xs, o + 9, 1)
    end
    local calls, links = 0, measured.links
    for v, ve in ipairs(data.vessels) do
        local r, off = rows[ve.path], 0
        vRow[v], pathVessel[ve.path], vBase[v], vNC[v] = r, v, calls, #ve.calls / 3
        vPrior[v] = type(r.ps) == "number" and r.ps > 0 and { period = r.period, sigma = r.ps } or false
        for c = 1, vNC[v] do
            if c > 1 then off = off + r.rides[c - 1] + ve.calls[3 * c - 1] end
            legRide[calls + c], depOff[calls + c] = r.rides[c], off
        end
        calls = calls + vNC[v]
    end
    A = n + 2 * #links
    aMass, aX, aY, aZ, aKind = {}, {}, {}, {}, {}
    for i = 1, n do aMass[i], aX[i], aY[i], aZ[i], aKind[i] = sMass[i], sX[i], sY[i], sZ[i], sKind[i] end
    for _, d in ipairs(tr.doors) do aMass[d.stop], aX[d.stop], aY[d.stop], aZ[d.stop] = d.map, d.x, d.y, false end
    for a = n + 1, A do -- row k of the links gives anchors n + 2k - 1 (its end a) and n + 2k (its end b)
        local r = links[floor((a - n + 1) / 2)]
        local p = (a - n) % 2 == 1 and r.a or r.b
        aMass[a], aX[a], aY[a], aZ[a], aKind[a] = p[1], p[2], p[3], false, r.mode + 4
    end
    spellID, itemSpell, entMap, entDoor, landRow, held, bindSp = {}, {}, {}, {}, {}, {}, {}
    for k, sp in ipairs(data.spells) do
        sp.castSeconds, sp.cooldownSeconds, spellID[sp.spell] = sp.cast / 1000, sp.cooldown / 1000, k
        for _, it in ipairs(sp.items or NONE) do itemSpell[it[1]] = k end
    end
    local caution = measured.caution
    for _, r in ipairs(measured.entrances) do entDoor[r.map] = r end
    for k, e in ipairs(data.entrances) do entMap[e.map] = k end
    for _, r in ipairs(measured.landings) do landRow[r.spell] = r end
    for i = 1, #caution - 1, 2 do held[caution[i]] = caution[i + 1] end
    for _, id in ipairs(measured.bindSpells) do bindSp[id] = true end
    M.build, M.S, M.A, M.LinkCount, M.BindCount, M.VesselCount = data.build, n, A, #links, #measured.binds, #data.vessels
    M.SpellCount, M.EntranceCount, M.PlaceCount, M.BASE_RUN = #data.spells, #data.entrances, #pl / 12, measured.move.run[1]
    M.FlightBonusCount, M.BASE_SWIM = type(data.flightBonus) == "table" and #data.flightBonus or 0, measured.move.swim[1]
    M.TramMap = data.tram.map
    CL.know, CA.know, Hp = false, false, false
    return true
end

function M.Stop(i) return sKind[i], sMass[i], sX[i], sY[i], sZ[i], sFac[i], sRef[i], sArea[i] end
function M.Anchor(a) return aMass[a], aX[a], aY[a], aZ[a], aKind[a] end
function M.Link(n) return ME.links[n] end
function M.UseDrops() return ME.move.safeFall[2] ~= 3 end
function M.HeldBy(area) return held[area] or 0 end
function M.IsBindSpell(id) return bindSp[id] == true end
function M.StopOfNode(id) return nodeStop[id] end
function M.VesselOfPath(path) return pathVessel[path] end
function M.Spell(k) return D.spells[k] end
function M.SpellByID(id) return spellID[id] end
function M.SpellOfItem(id) return itemSpell[id] end
function M.EntranceOfMap(map) return entMap[map] end
function M.TramPeriod() return D.tram.period / 1000 end
function M.TramWait() -- trains moving opposite ways leave opposite ends and pass halfway: two departures a period
    local t, P, w = D.tram.trains, D.tram.period, 0
    for i = 1, #t == 2 and t[1].dir ~= t[2].dir and 2 or 0 do
        local g = (t[3 - i].leaveFar - t[i].leaveHome) % P
        w = max(w, g * g + (P - g) * (P - g))
    end
    return (w > 0 and w or P * P) / (2 * P) / 1000
end
function M.VesselShape(v, out) return ns.Bytes.Shape(SH.vessels[v], SH.quantum, out) end
function M.BindPoint(k) local r = ME.binds[k]; return r.area, r.map, r.x, r.y end
function M.FlightBonus(k) local r = D.flightBonus[k]; return r.spell, r.bonus end
function M.Call(v, c) local cl = D.vessels[v].calls; return cl[3 * c - 2], cl[3 * c - 1], cl[3 * c] end
function M.Vessel(v) local ve = D.vessels[v]; return ve.path, ve.air, ve.lap, ve.wait, vNC[v] end
function M.Service(v)
    local r, k = vRow[v], M.PERIOD_SLACK
    local slack = max(r.period * k, vPrior[v] and vPrior[v].sigma or 0)
    return SERVICE[r.service] or "likely", r.faction, r.period, r.period - slack, r.period + slack, vPrior[v]
end
function M.Offset(v, c) return depOff[vBase[v] + (c or 1)] end -- seconds after call 1 leaves that call c leaves
function M.Ride(v, c) return legRide[vBase[v] + c] end -- seconds from leaving call c to rest at the next
function M.TramStops() local t = D.tram; return t.entrances[1], t.entrances[2], ME.tram.stormwind, ME.tram.ironforge end
function M.TramRide() local t = D.tram.trains[1]; return (t.arriveFar - t.leaveHome) / 1000 end
function M.EnglishName(a) if a <= S then return D.stopNames[a] end return ME.links[floor((a - S + 1) / 2)].id end
function M.Place(k)
    local U, C, s, o = ns.Bytes.U, ns.Bytes.C, D.places, k * 12 - 11
    return U(s, o, 3), U(s, o + 3, 2), C(s, o + 5), C(s, o + 8), U(s, o + 11, 1), D.placeNames[k]
end
function M.Entrance(k) -- the network data's point, else the measured door, else none
    local e = D.entrances[k]; local r = e.at and e or entDoor[e.map] or NONE
    return e.map, e.raid, r.at, r.x, r.y
end
function M.LinkOfAnchor(a)
    local k = a > S and a <= A and floor((a - S + 1) / 2)
    if k then return k, ((a - S) % 2 == 1 and ME.links[k].a or ME.links[k].b)[4] end
end
function M.Landing(id)
    local r, g = landRow[id], spellID[id] and D.spells[spellID[id]].guess
    if r then return r.map, r.x, r.y, r.c == 3 end
    if g then return g[1], g[2], g[3], true end
end
function M.Nearest(landmass, x, y, kinds, maxYards)
    local best, by = nil, maxYards
    for a = 1, A do
        local d = aMass[a] == landmass and kinds[aKind[a]] and sqrt((aX[a] - x) ^ 2 + (aY[a] - y) ^ 2)
        if d and (d < by or (not best and d == by)) then best, by = a, d end
    end
    if best then return best, by end
end
function M.CallAt(v, a) for c = 1, vNC[v] do if D.vessels[v].calls[3 * c - 2] == a then return c end end end
function M.Crossing(v, c, d)
    local cl, nc, base, yards, jumps, wait, i = D.vessels[v].calls, vNC[v], vCross[v] - 1, 0, 0, 0, c
    repeat
        yards, jumps, i = yards + xYards[base + i], jumps + xJumps[base + i], i % nc + 1
        if i ~= d then wait = wait + cl[3 * i - 1] end
    until i == d
    return yards, jumps, wait
end
local function FlightRecord(a, b)
    if type(a) ~= "number" or a < 1 or a > S then return nil end
    for k = fFirst[a], fFirst[a + 1] - 1 do if fTo[k] == b then return k end end
end
function M.FlightShape(a, b, out) local k = FlightRecord(a, b) if k then return ns.Bytes.Shape(SH.flights[k], SH.quantum, out) end end
-- A chained flight does not land at its middle stop: the yards saved flying record k1 then k2 (FORMAT.md "joins").
local function Saving(k1, k2) return k1 > 0 and ns.Bytes.U(D.joins, jOff[k1] + 2 * (k2 - fFirst[fTo[k1]]), 2) or 0 end
function M.JoinYards(a, m, b) local k1, k2 = FlightRecord(a, m), FlightRecord(m, b) return k1 and k2 and Saving(k1, k2) or 0 end
local function Floor(a, b, y) return max(y, sqrt((sX[a] - sX[b]) ^ 2 + (sY[a] - sY[b]) ^ 2)) end -- where trims overlap

-- The flight closure: every usable ordered pair of flight masters with its fewest-time chain, kept per knowledge.
local okF, dist, dyd, dhops, dprev, dRec, mark, stamp = {}, {}, {}, {}, {}, {}, {}, 0
-- The seconds and net yards of the chain of stops ch[1..m] flown in one boarding, the boarding not counted; nil
-- where a hop has no flight record.
function M.ChainPrice(ch, m, vF, hop)
    local yards, prev = 0, 0
    for i = 1, m - 1 do
        local k = FlightRecord(ch[i], ch[i + 1])
        if not k then return nil end
        yards, prev = yards + max(fYards[k] - Saving(prev, k), 1), k
    end
    yards = Floor(ch[1], ch[m], yards)
    return yards / vF + (m - 2) * hop, yards
end
-- A chain the flight window showed replaces the computed one when every master on it is usable.
local function LedgerChain(cl, j, ch, a, b, vF, hop)
    local m = type(ch) == "table" and #ch or 0
    if m < 2 or ch[1] ~= a or ch[m] ~= b then return end
    for i = 2, m do if not okF[ch[i]] then return end end
    local sec, yards = M.ChainPrice(ch, m, vF, hop)
    if sec then cl.sec[j], cl.yards[j], cl.hops[j], cl.led[j] = sec, yards, m - 1, true end
end
local function Close(cl, know, fac, whatIf, pause)
    local Heap, learned, unread, chains = ns.Heap, know.learned or NONE, know.unread or NONE, know.chains or NONE
    local vF, hop, n = know.vFly, know.hopFlight, 0
    Hp = Hp or Heap.New(S)
    for i = 1, S do
        okF[i] = sKind[i] == 1 and sFac[i] % (2 * fac) >= fac and (learned[i] == true or (whatIf and unread[sMass[i]] == true))
    end
    for a = 1, S do
        cl.first[a] = n + 1
        if okF[a] then
            stamp = stamp + 1
            mark[a], dist[a], dyd[a], dhops[a], dprev[a], dRec[a] = stamp, 0, 0, 0, 0, 0
            local u, du = a, 0
            while u do
                for j = fFirst[u], fFirst[u + 1] - 1 do -- chosen on full yards, as the game does; priced net
                    local b, nd = fTo[j], du + fYards[j] / vF + hop
                    if okF[b] and (mark[b] ~= stamp or nd < dist[b]) then
                        mark[b], dist[b], dhops[b], dprev[b], dRec[b] = stamp, nd, dhops[u] + 1, u, j
                        dyd[b] = dyd[u] + max(fYards[j] - Saving(dRec[u], j), 1)
                        Heap.Push(Hp, b, nd)
                    end
                end
                u, du = Heap.Pop(Hp)
            end
            for b = 1, S do
                if mark[b] == stamp and b ~= a then
                    n = n + 1
                    local k = FlightRecord(a, b)     -- where a direct record joins the two, the game flies it (16.13)
                    cl.to[n], cl.yards[n], cl.prev[n], cl.hops[n], cl.led[n] = b, Floor(a, b, k and fYards[k] or dyd[b]), dprev[b], k and 1 or dhops[b], k and 1 or false
                    cl.sec[n] = cl.yards[n] / vF + (cl.hops[n] - 1) * hop
                    if chains[a * 1024 + b] then LedgerChain(cl, n, chains[a * 1024 + b], a, b, vF, hop) end
                end
            end
            pause()
        end
    end
    cl.first[S + 1], cl.know, cl.rev, cl.fac = n + 1, know, know.rev, fac
end
local function Find(g, a, b)
    local cl = (ALT and g == ALT) and CA or CL
    if not cl.know or type(a) ~= "number" or a < 1 or a > S then return cl, nil end
    for j = cl.first[a], cl.first[a + 1] - 1 do if cl.to[j] == b then return cl, j end end
    return cl
end
function M.Chain(g, a, b, out)
    local cl, j = Find(g, a, b)
    if not j then return 0 end
    if cl.led[j] == 1 then out[1], out[2] = a, b return 2 end
    local ch, n = cl.led[j] and cl.know.chains[a * 1024 + b], cl.hops[j] + 1
    for i = 1, ch and n or 0 do out[i] = ch[i] end
    out[n] = b
    for i = ch and 0 or n - 1, 1, -1 do -- back along the tree of a
        out[i] = cl.prev[j]
        if i > 1 then cl, j = Find(g, a, out[i]) end
    end
    return n
end
function M.ChainYards(g, a, b) local cl, j = Find(g, a, b) return j and cl.yards[j] or 0 end
function M.FlightYards(a, b) for k = fFirst[a], fFirst[a + 1] - 1 do if fTo[k] == b then return fYards[k] end end end

-- The request's graph.
local function Avoided(av, kind, ref)
    for i = 1, #av do if av[i].kind == kind and (av[i].ref == 0 or av[i].ref == ref) then return true end end
end
local landAt, lPlace, pFrom, pTo, nL = {}, {}, {}, {}, 0
local vOk, vP, vTT, vU, vEst = {}, {}, {}, {}, {}
local bK, bT, bR, bW, bS, bO, bE, bTT, bU, bC, bD, bI, bn = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, 0
local padSet, padN = {}, 0
local function LandingPlace(ld)
    local a = ld.anchor
    if type(a) == "number" and a > 0 then return a <= A and a or 0 end
    if not ld.rows then return 0 end
    for i = 1, nL do if landAt[i].key == ld.key then return A + i end end
    nL = nL + 1; landAt[nL] = ld
    return A + nL
end
local function Add(kind, to, ref, wait, sec, off, est, tt, u, c, d)
    bn = bn + 1
    bK[bn], bT[bn], bR[bn], bW[bn], bS[bn], bO[bn], bE[bn], bTT[bn], bU[bn], bC[bn], bD[bn], bI[bn] =
        kind, to, ref, wait, sec, off, est, tt, u, c, d, bn
end

-- Gathers the crossings, tram, lifts and portals that leave anchor p.
local function Rides(p, av, fac, know)
    for v = 1, #D.vessels do
        local cl, nc, base = D.vessels[v].calls, vNC[v], vBase[v]
        for c = 1, vOk[v] and nc or 0 do
            for d = 1, cl[3 * c - 2] == p and nc or 0 do
                if d ~= c then
                    local sec, i = legRide[base + c], c % nc + 1
                    while i ~= d do sec, i = sec + cl[3 * i - 1] + legRide[base + i], i % nc + 1 end
                    Add(2, cl[3 * d - 2], v, vTT[v] and 0 or vP[v] / 2, sec, depOff[base + c], vEst[v], vTT[v], vU[v], c, d)
                end
            end
        end
    end
    local te = D.tram.entrances
    if (p == te[1] or p == te[2]) and not Avoided(av, "tram", 0) then
        Add(3, p == te[1] and te[2] or te[1], 0, M.TramWait(), M.TramRide() + 2 * ME.tram.walk[1] + 2 * know.loading,
            0, false, false, 0, 0, 0)
    end
    local k = p > S and floor((p - S + 1) / 2)
    local r = k and ME.links[k]
    if r and (p % 2 ~= S % 2 or r.both) and r.faction % (2 * fac) >= fac and not Avoided(av, LINK_KIND[r.mode + 3], k) then
        Add(r.mode + 3, p % 2 ~= S % 2 and p + 1 or p - 1, k, r.wait, r.ride, 0, false, false, 0, 0, 0)
    end
end

-- Appends the place's gathered rides ordered by kind, destination and ref; returns the next free link.
local function Flush(p, W, K)
    for i = 2, bn do
        local x, j = bI[i], i - 1
        local xk, xt, xr = bK[x], bT[x], bR[x]
        while j >= 1 and (bK[bI[j]] > xk or (bK[bI[j]] == xk and (bT[bI[j]] > xt or (bT[bI[j]] == xt and bR[bI[j]] > xr)))) do
            bI[j + 1], j = bI[j], j - 1
        end
        bI[j + 1] = x
    end
    for i = 1, bn do
        local j = bI[i]
        G.to[K], G.kind[K], G.ref[K], G.wait[K], G.sec[K], G.off[K], G.est[K], G.tt[K], G.u[K], G.call[K], G.toCall[K] =
            bT[j], bK[j], bR[j], bW[j], bS[j], bO[j], bE[j], bTT[j], bU[j], bC[j], bD[j]
        if bK[j] < 6 and p <= W then G.board[p] = true end
        if bT[j] <= W then G.alight[bT[j]] = true end
        K = K + 1
    end
    bn = 0
    return K
end
-- G.pad for every walk that can matter: from a place a ride arrives at to a place a ride leaves.
local function Walks(req, ground, W, pause)
    local pad, list, mass, units = G.pad, G.list, G.mass, 0
    for i = 1, padN do pad[padSet[i]] = nil; if i % 512 == 0 then pause() end end; padN = 0
    for p = 1, W do
        local m = mass[p]
        local l, rows = G.alight[p] and list[m], p > A and landAt[p - A].rows
        for i = 1, l and (rows or ground.Has(m)) and l.n or 0 do
            local q, land, inside, swim, risk = l[i]
            if q ~= p and q <= A then
                if rows then
                    land, inside, swim, risk = rows[4 * q - 3], rows[4 * q - 2], rows[4 * q - 1], rows[4 * q]
                    if not land or land < 0 then land = nil end
                else
                    land, inside, swim, risk = ground.Pair(m, p, q, req.cost)
                end
                if land then
                    padN = padN + 1
                    padSet[padN] = (p - 1) * W + q
                    pad[padSet[padN]] = select(2, ground.Price(req.cost, land, inside, swim, risk)) + ns.Trip.Remount(req.cost, swim, land)
                end
                units = units + 1
                if units % 64 == 0 then pause() end
            end
        end
    end
end
function M.Graph(req, pause)
    local know, cost = req.know, req.cost
    local fac, av, casts, portals = cost.faction, req.avoid or NONE, req.casts or NONE, know.portals or NONE
    G = G or { list = {}, mass = {}, x = {}, y = {}, board = {}, alight = {}, first = {}, to = {}, kind = {}, ref = {},
        wait = {}, sec = {}, off = {}, est = {}, tt = {}, u = {}, call = {}, toCall = {}, pad = {}, alt = false,
        landing = landAt }
    nL = 0
    for i = 1, #casts do lPlace[i] = LandingPlace(casts[i].landing) end
    for m = 1, #portals do pFrom[m], pTo[m] = LandingPlace(portals[m].from), LandingPlace(portals[m].to) end
    local W, n, mass = A + nL, A + nL + 2, G.mass
    G.A, G.L, G.n, G.W, G.START, G.GOAL, G.change, G.landed = A, nL, n, W, W + 1, W + 2, req.change or false, req.landed or false
    for p = 1, A do mass[p], G.x[p], G.y[p] = aMass[p], aX[p], aY[p] end
    for i = 1, nL do mass[A + i], G.x[A + i], G.y[A + i] = landAt[i].landmass, landAt[i].x, landAt[i].y end
    for p = 1, n do G.board[p], G.alight[p] = false, false end
    if CL.know ~= know or CL.rev ~= know.rev or CL.fac ~= fac then Close(CL, know, fac, false, pause) end
    local alt = req.whatIf and (ALT or { first = {}, to = {}, wait = {}, sec = {} }) or false
    if alt and (CA.know ~= know or CA.rev ~= know.rev or CA.fac ~= fac) then Close(CA, know, fac, true, pause) end
    G.alt, ALT = alt, ALT or alt
    local kv = know.vessels or NONE
    for v = 1, #D.vessels do
        local row, kr, ve = vRow[v], kv[v], D.vessels[v]
        local runs, P = kr and kr.runs or SERVICE[row.service] or "likely", kr and kr.period or row.period
        vOk[v] = runs ~= "no" and row.faction % (2 * fac) >= fac and not Avoided(av, ve.air and "zeppelin" or "boat", ve.path)
        if vOk[v] then
            local tt = kr and kr.tt
            vTT[v], vU[v] = false, 0
            tt = tt and Clock.View(tt, req.now, know.build, vPrior[v]); if tt then vTT[v], vU[v] = tt, tt.u end
            vP[v], vEst[v] = P, runs == "likely" or not vTT[v] or vTT[v].tier == "about"
        end
    end
    local bf, K, KA = know.boardFlight, 1, 1
    for p = 1, n do
        G.first[p] = K; if alt then alt.first[p] = KA end
        if p <= S and sKind[p] == 1 and not Avoided(av, "flight", sRef[p]) then
            for j = CL.first[p], CL.first[p + 1] - 1 do Add(1, CL.to[j], 0, bf, CL.sec[j], 0, false, false, 0, 0, 0) end
            for j = alt and CA.first[p] or 1, alt and CA.first[p + 1] - 1 or 0 do -- the what-if's masters get walks too
                alt.to[KA], alt.wait[KA], alt.sec[KA], KA = CA.to[j], bf, CA.sec[j], KA + 1
                G.board[p], G.alight[CA.to[j]] = true, true
            end
        end
        if p <= A then Rides(p, av, fac, know) end
        for m = 1, #portals do
            local pm = portals[m]
            if pFrom[m] == p and pTo[m] > 0 and not Avoided(av, "portal", -m) then
                Add(5, pTo[m], -m, 0, pm.seconds, 0, pm.from.est == true or pm.to.est == true, false, 0, 0, 0)
            end
        end
        for i = 1, p == W + 1 and #casts or 0 do
            local cs, est = casts[i], casts[i].landing.est == true
            if lPlace[i] > 0 and not Avoided(av, cs.kind, cs.spell) then
                Add(6, lPlace[i], i, 0, cs.seconds + know.loading + (est and M.LANDING_PAD or 0), 0, est, false, 0, 0, 0)
            end
        end
        K = Flush(p, W, K)
        pause()
    end
    G.first[n + 1] = K; if alt then alt.first[n + 1] = KA end
    for _, l in pairs(G.list) do l.n = 0 end
    for p = 1, W do
        local l = G.board[p] and (G.list[mass[p]] or { n = 0 })
        if l then l.n, G.list[mass[p]] = l.n + 1, l; l[l.n] = p end
    end
    Walks(req, req.ground or ns.Ground, W, pause)
    return G
end
-- A timed crossing reached at t: its uncertainty grown to t (Clock.UAt), false past a quarter period; past it the
-- untimed wait, never earlier than the answer at the moment it passed (first in, first out).
function M.UAt(g, k, t) return g.tt and g.tt[k] and (Clock or ns.Clock).UAt(g.tt[k], t, g.u[k]) end
local function Late(g, k, t)
    local tt, u = g.tt[k], M.UAt(g, k, t)
    return u or tt.period / 4, u and t or tt.at + (tt.period / 4 - g.u[k]) * tt.period / tt.sigma, u and -1e9 or tt.period / 2
end
function M.Arrive(g, k, t)
    local tt = g.tt and g.tt[k]
    if not tt then return t + g.wait[k] + g.sec[k] end
    local u, at, wait = Late(g, k, t)
    return max((Clock or ns.Clock).Arrive(tt, g.off[k], g.sec[k], u, at), t + wait + g.sec[k])
end
function M.Depart(g, k, t)
    if not (g.tt and g.tt[k]) then return t + g.wait[k] end
    local u, at, wait = Late(g, k, t)
    return max((Clock or ns.Clock).Next(g.tt[k], g.off[k], at + u), t + wait)
end
