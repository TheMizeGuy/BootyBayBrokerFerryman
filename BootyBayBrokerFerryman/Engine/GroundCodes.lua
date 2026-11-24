local ADDON, ns = ...

-- The walking data of tools/terrain/FORMAT.md (format 3) read in place: a landmass's header, its code tables, a
-- bit cursor and the cache of decoded clusters that every search and both landmasses share.
local C = {}
ns.GroundCodes = C

local byte, char, concat, floor, sqrt, min = string.byte, string.char, table.concat, math.floor, math.sqrt, math.min
local P2 = {}
for i = 0, 52 do P2[i] = 2 ^ i end
local PS, NONE16, NONE24, KKM = 1024, 65535, 16777215, 144
C.P2, C.PS, C.NONE16, C.NONE24, C.SLOTS = P2, PS, NONE16, NONE24, 14

local function bitsFor(n)
    local b = 0
    while P2[b] < n do b = b + 1 end
    return b
end
C.bitsFor = bitsFor

-- The cursor: a stream and a bit position. A reader that decodes a cluster between two reads sets it again;
-- bp is read before a call in the same expression, so a read and a skip are two statements.
local bs, bp = "", 0
local function at(s, pos) bs, bp = s, pos end
local function skip(n) bp = bp + n end
-- n bits (at most 16), least significant first
local function rb(n)
    if n == 0 then return 0 end
    local off = bp % 8
    local a, b, c = byte(bs, (bp - off) / 8 + 1, (bp - off) / 8 + 3)
    local x = (a + (b or 0) * 256 + (c or 0) * 65536) % P2[off + n]
    bp = bp + n
    return (x - x % P2[off]) / P2[off]
end
-- an Elias gamma code
local function rg()
    local z = 0
    while rb(1) == 0 do z = z + 1 end
    local v = 1
    for _ = 1, z do v = v * 2 + rb(1) end
    return v
end
-- one symbol of canonical code t (codes are read most significant bit first); codes of at most 8 bits through
-- t.fast, two bytes an entry indexed by the next 8 bits: symbol, length (0: a longer code)
local function rh(t)
    local off = bp % 8
    local a, b = byte(bs, (bp - off) / 8 + 1, (bp - off) / 8 + 2)
    local x = (a + (b or 0) * 256) % P2[off + 8]
    local v = (x - x % P2[off]) / P2[off]
    local sym, len = byte(t.fast, 2 * v + 1, 2 * v + 2)
    if len > 0 then bp = bp + len; return sym end
    local code, first, index, count = 0, 0, 0, t.count
    for l = 1, t.max do
        off = bp % 8
        code = code + floor(byte(bs, (bp - off) / 8 + 1) / P2[off]) % 2
        bp = bp + 1
        local cnt = count[l]
        if code - cnt < first then return byte(t.sym, index + code - first + 1) end
        index, first, code = index + cnt, (first + cnt) * 2, code * 2
    end
    error("Ferryman: walking.code")
end
C.at, C.skip, C.rb, C.rg, C.rh = at, skip, rb, rg, rh
function C.pos() return bp end

local function huffTable(lengths)
    local count, syms, fast, max = {}, {}, {}, 0
    for len = 1, 15 do count[len] = 0 end
    for sym = 0, #lengths - 1 do
        local len = byte(lengths, sym + 1)
        if len > 0 then count[len] = count[len] + 1; if len > max then max = len end end
    end
    for len = 1, max do
        for sym = 0, #lengths - 1 do if byte(lengths, sym + 1) == len then syms[#syms + 1] = char(sym) end end
    end
    for v = 1, 512 do fast[v] = "\0" end
    local first, index = 0, 0
    for len = 1, math.min(max, 8) do
        for k = 0, count[len] - 1 do
            local code, rev = first + k, 0
            for i = 0, len - 1 do rev = rev + (floor(code / P2[len - 1 - i]) % 2) * P2[i] end
            for e = 0, P2[8 - len] - 1 do
                local v = rev + e * P2[len]
                fast[2 * v + 1], fast[2 * v + 2] = syms[index + k + 1], char(len)
            end
        end
        index, first = index + count[len], (first + count[len]) * 2
    end
    return { count = count, sym = concat(syms), max = max, fast = concat(fast) }
end
local function tables(str, n)
    local t, w = {}, #str / n
    for c = 0, n - 1 do t[c] = huffTable(str:sub(c * w + 1, c * w + w)) end
    return t
end

-- A landmass: the header, the code tables, the anchors. key tells its clusters apart in the shared cache.
function C.New(d, key)
    local L = { d = d, key = key * 8192, G = d.G, K = d.K, KK = d.K * d.K, CL = d.G * d.K, cell = d.cell,
        x0 = d.x0, y0 = d.y0, pb = bitsFor(d.G), qb = bitsFor(d.K * d.K), N = d.nodeCount, SF = d.swimFactor,
        cRows = d.clusterRows, cCols = d.clusterCols, anchorNode = {}, nodeAnchor = {}, onIndex = {}, nOn = 0,
        factor = {}, step = {}, risky = {}, piece = {} }
    -- slots keep bit offsets below 2^23 beside other fields
    assert(L.KK <= KKM and d.maxPieces < PS and #d.blocks * 8 < P2[23], "Ferryman: walking.cluster")
    for a = 1, d.anchorCount do
        local x1, x2 = byte(d.anchors, (a - 1) * 5 + 1, (a - 1) * 5 + 2)
        local nd = x1 + x2 * 256
        if nd ~= NONE16 then L.anchorNode[a], L.nodeAnchor[nd], L.onIndex[a], L.nOn = nd, a, L.nOn, L.nOn + 1 end
    end
    L.hFactor, L.hEdge, L.hPort = tables(d.hFactor, 8), tables(d.hEdge, 4), tables(d.hPort, 2)
    L.hCount, L.hNport, L.hKind = tables(d.hCount, 2), huffTable(d.hNport), tables(d.hKind, 4)
    for f = 0, 31 do L.factor[f] = d.factorBase * d.factorStep ^ f end
    for c = 0, 254 do
        L.step[c] = c <= d.linkKnee and d.linkStep ^ c or d.linkStep ^ d.linkKnee * d.linkStep2 ^ (c - d.linkKnee)
    end
    return L
end

-- node record: row, col (fine cell of the A side), owner, B component (nil), local index there, side, pa, pb
local function nodeRec(L, i)
    local r1, r2, c1, c2, o1, o2, b1, b2, ib, s1, s2 = byte(L.d.nodes, i * 11 + 1, i * 11 + 11)
    local cb = b1 + b2 * 256
    return r1 + r2 * 256, c1 + c2 * 256, o1 + o2 * 256, cb ~= NONE16 and cb or nil, ib, s1 % 8, floor(s1 / 8), s2
end
C.nodeRec = nodeRec

local function otherSide(side, row, col)
    if side == 1 then return row + 1, col
    elseif side == 2 then return row, col + 1
    elseif side == 3 then return row + 1, col + 1
    elseif side == 4 then return row + 1, col - 1 end
    return row, col
end
C.otherSide = otherSide

-- the index record of cluster cl: block offset (nil: no ground), record number (nil: outside its row's span)
local function clusterRec(L, cl)
    local cc = cl % L.cCols
    local cr = (cl - cc) / L.cCols
    local c0, n, r1, r2 = byte(L.d.crow, cr * 4 + 1, cr * 4 + 4)
    if cc < c0 or cc >= c0 + n then return nil, nil end
    local r = r1 + r2 * 256 + cc - c0
    local b1, b2, b3 = byte(L.d.cindex, r * 5 + 1, r * 5 + 3)
    local bo = b1 + b2 * 256 + b3 * 65536
    return bo ~= NONE24 and bo or nil, r
end

-- the nodes whose A side stands in cluster cl: first, one past the last
local function nodesOf(L, cl)
    local _, r = clusterRec(L, cl)
    if not r then return 0, 0 end
    local a1, a2, _, _, _, b1, b2 = byte(L.d.cindex, r * 5 + 4, r * 5 + 10)
    return a1 + a2 * 256, b1 + b2 * 256
end

-- context of an edge code (nb false: the other cell lies in another cluster)
local function edgeContext(na, nb)
    if not nb then return na == 1 and 2 or 3 end
    return (na == 1 and nb == 1) and 0 or 1
end
C.edgeContext = edgeContext

---------------------------------------------------------------------------------------------------------------
-- The cache. Slot sl holds a cluster: per cell (index sl * 144 + q + 1) its first piece * 64 + count (-1: no
-- ground), where its south and east edge codes start, its raster (and, from 2^23 up, where its split portals
-- start); per piece its attributes and its portals once listed; the node sides on its pieces. Decoding stops
-- after the pieces (enough to locate); finish reads the rest when a portal or a node is asked for. Both go in
-- steps of C.STEP cells and keep their progress in the slot, so any caller carries on where another stopped.
local cInfo, cEdge, cRas = {}, {}, {}
local slotKey, slotUse, slotEnd, slotN, slotCorner, slotMass = {}, {}, {}, {}, {}, {}
local slotStep, slotPos, slotP, slotKind, slotFin, slotFpos = {}, {}, {}, {}, {}, {}
local pAttr, snNode, snPiece, pStart, pList, pCount = {}, {}, {}, {}, {}, {}
local clock, lastKey, lastSl, made, index, DONE = 0, -1, -1, false, {}, 1e9
C.cInfo, C.cEdge, C.cRas, C.slotCorner, C.slotN = cInfo, cEdge, cRas, slotCorner, slotN
C.pAttr, C.snNode, C.snPiece, C.pStart, C.pList, C.pCount = pAttr, snNode, snPiece, pStart, pList, pCount
C.decodes, C.work, C.pause, C.left, C.STEP, C.CHUNK, C.BUSY = 0, 0, nil, nil, 16, 4, ns.Ground.BUSY

-- Counts n units of work (a grid settle or a portal list is one, a step of decoding two). Inside a job the frame
-- is given back every CHUNK of them. A bounded call (C.left)
-- stops with C.BUSY once it has spent its units; a step is never cut, so the next call carries on after it.
local function spend(n)
    local left = C.left
    if left then
        C.left = left - n
        if left - n < 0 then error(C.BUSY, 0) end
    else
        C.work = C.work + n
        if C.work >= C.CHUNK and C.pause then C.work = 0; C.pause() end
    end
end
C.spend = spend

local function Make()
    made = true
    for i = 1, (C.SLOTS + 1) * KKM do cInfo[i], cEdge[i], cRas[i] = -1, 0, 0 end
    for i = 0, 63 do index[i] = 0 end
    for sl = 0, C.SLOTS do      -- slot SLOTS stays empty: every cluster without ground reads as it, and takes none
        slotKey[sl], slotUse[sl], slotEnd[sl], slotN[sl], slotCorner[sl] = -1, 0, -1, -1, -1
        slotStep[sl], slotPos[sl], slotP[sl], slotKind[sl], slotFin[sl], slotFpos[sl] = DONE, 0, 0, 0, 0, 0
        pAttr[sl], snNode[sl], snPiece[sl], pStart[sl], pList[sl], pCount[sl] = {}, {}, {}, {}, {}, 0
    end
end

-- Forgets every decoded cluster of landmass L (its data is replaced), or of all.
function C.Forget(L)
    for sl = 0, made and C.SLOTS - 1 or -1 do
        if not L or slotMass[sl] == L then slotKey[sl], slotUse[sl] = -1, 0 end
    end
    lastKey = -1
end

-- One step of decoding slot sl: every cell's piece count, or the pieces of the next C.STEP cells.
local function step(L, sl)
    local KK, base, n = L.KK, sl * KKM, slotStep[sl]
    at(L.d.blocks, slotPos[sl])
    if n == 0 then
        local ht, np = L.hCount[rb(1) == 1 and 0 or 1], 0
        for q = 1, KK do
            local c = rh(ht)
            if c > 0 then cInfo[base + q], np = np * 64 + c, np + c end
        end
        slotP[sl], slotKind[sl], n = 0, 0, 1
    else
        local pb, G, hKind, hFactor, kind, p = L.pb, L.G, L.hKind, L.hFactor, slotKind[sl], slotP[sl]
        local attr, start, last = pAttr[sl], pStart[sl], min(KK, n + C.STEP - 1)
        for q = n - 1, last - 1 do
            local info = cInfo[base + q + 1]
            if info >= 0 then
                local c = info % 64
                for _ = 1, c do
                    kind = rh(hKind[kind])
                    local f = rh(hFactor[kind * 2 + (c == 1 and 1 or 0)])
                    local b, ce = f % 2, -1
                    f = (f - b) / 2
                    if b == 1 then ce = rb(pb) * G; ce = ce + rb(pb) end
                    p = p + 1
                    attr[p], start[p] = kind + 4 * f + P2[23] * (ce + 1) + P2[33] * q, 0
                end
                if c > 1 then
                    cRas[base + q + 1] = bp
                    local wr = bitsFor(c)
                    if rb(1) == 1 then bp = bp + wr
                    else for _ = 1, 4 do local b = rb(1); bp = bp + (b == 1 and wr or 4 * wr) end end
                end
            end
        end
        slotKind[sl], slotP[sl], n = kind, p, last + 1
        if last == KK then slotEnd[sl], n = bp, DONE end
    end
    slotStep[sl], slotPos[sl] = n, bp
end

-- The slot of cluster cl of landmass L, decoded up to its pieces when it was not held.
local function decode(L, cl)
    local key = L.key + cl
    clock = clock + 1
    if key == lastKey then slotUse[lastSl] = clock; return lastSl end
    if not made then Make() end
    local sl = index[key % 64]
    if slotKey[sl] ~= key then
        local old = 0
        sl = -1
        for k = 0, C.SLOTS - 1 do
            if slotKey[k] == key then sl = k; break end
            if slotUse[k] < slotUse[old] then old = k end
        end
        if sl < 0 then
            if not clusterRec(L, cl) then return C.SLOTS end
            sl, C.decodes = old, C.decodes + 1
            if sl == lastSl then lastKey = -1 end
            slotKey[sl], slotMass[sl] = key, L
            local base = sl * KKM
            for q = 1, L.KK do cInfo[base + q], cEdge[base + q], cRas[base + q] = -1, 0, 0 end
            slotN[sl], slotCorner[sl], slotEnd[sl], pCount[sl], slotFin[sl] = -1, -1, -1, 0, 0
            local bo = clusterRec(L, cl)
            slotStep[sl], slotPos[sl] = bo and 0 or DONE, bo and bo * 8 or 0
        end
        index[key % 64] = sl
    end
    slotUse[sl] = clock
    while slotStep[sl] < DONE do
        step(L, sl)
        spend(2)
        if slotKey[sl] ~= key then return decode(L, cl) end
        slotUse[sl] = clock
    end
    lastKey, lastSl = key, sl
    return sl
end
C.decode = decode

-- One step of the rest of slot sl (cluster cl of L): where the edge codes of the next C.STEP cells start; then
-- the corner list and where each split cell's portals start; then the node sides on its pieces, from the clusters
-- that can hold them (its own A sides, the B sides from those north-west, north, north-east and west of it, and
-- from the east one: a south-west corner). Nothing here decodes another cluster.
local function finStep(L, sl, cl)
    local KK, K, G, CL, base, e = L.KK, L.K, L.G, L.CL, sl * KKM, slotFin[sl]
    if e == 0 then e, slotFpos[sl] = 1, slotEnd[sl] end
    at(L.d.blocks, slotFpos[sl])
    if e <= KK then
        local hEdge, hNport, hPort, last = L.hEdge, L.hNport, L.hPort, min(KK, e + C.STEP - 1)
        for q = e - 1, last - 1 do
            local info = cInfo[base + q + 1]
            if info >= 0 then
                local qc = q % K
                local qr, off0, off1 = (q - qc) / K, 0, 0
                for sd = 0, 1 do
                    local nr, nc = qr + (sd == 0 and 1 or 0), qc + (sd == 1 and 1 or 0)
                    local border = nr >= K or nc >= K
                    local other = not border and cInfo[base + nr * K + nc + 1]
                    if border or other >= 0 then
                        if sd == 0 then off0 = bp + 1 else off1 = bp + 1 end
                        if rh(hEdge[edgeContext(info % 64, not border and other % 64)]) == 2 then
                            local n, wa, wb = rh(hNport), bitsFor(info % 64), 0
                            if not border then wb = bitsFor(other % 64) elseif rb(1) == 1 then wb = 5 else wa = 0 end
                            for k = 1, n do rh(hPort[k == 1 and 0 or 1]); bp = bp + wa + wb end
                        end
                    end
                end
                cEdge[base + q + 1] = off0 * P2[23] + off1
            end
        end
        e = last + 1
    elseif e == KK + 1 then
        slotCorner[sl] = bp
        if rb(1) == 1 then local n = rb(8); bp = bp + (n + 1) * (L.qb + 11) end
        if rb(1) == 1 then
            local q = -1
            for _ = 1, rg() do
                q = q + rg()
                cRas[base + q + 1] = cRas[base + q + 1] % P2[23] + (bp + 1) * P2[23]
                local wr = 2 * bitsFor(cInfo[base + q + 1] % 64)
                for _ = 1, rg() do local t = rb(2); bp = bp + (t < 2 and 2 * L.pb or 0) + wr end
            end
        end
        e = e + 1
    else
        local cc, n, sn, sp = cl % L.cCols, 0, snNode[sl], snPiece[sl]
        local cr = (cl - cc) / L.cCols
        for k = 0, 5 do
            local dc = k % 3 - 1
            local ocr, occ = cr + (k - dc - 1) / 3 - 1, cc + dc
            if ocr >= 0 and occ >= 0 and ocr < L.cRows and occ < L.cCols then
                local f0, f1 = nodesOf(L, ocr * L.cCols + occ)
                for i = f0, f1 - 1 do
                    local row, col, _, _, _, side, pa, pb = nodeRec(L, i)
                    for b = 0, side == 0 and 0 or 1 do
                        local r, c, pi = row, col, pa
                        if b == 1 then r, c = otherSide(side, row, col); pi = pb end
                        local rc, ccl = r % CL, c % CL
                        if (r - rc) / CL == cr and (c - ccl) / CL == cc then
                            local info = cInfo[base + (rc - rc % G) / G * K + (ccl - ccl % G) / G + 1]
                            n = n + 1
                            sn[n], sp[n] = i * 2 + b, cl * PS + (info - info % 64) / 64 + pi
                        end
                    end
                end
            end
        end
        slotN[sl] = n
    end
    slotFin[sl], slotFpos[sl] = e, bp
end

-- The rest of the slot of cluster cl, read in steps; the slot it is in when done (the one asked for unless it was
-- given up while a job paused).
local function finish(L, sl, cl)
    while slotEnd[sl] >= 0 and slotN[sl] < 0 do
        finStep(L, sl, cl)
        spend(2)
        if slotKey[sl] ~= L.key + cl or slotStep[sl] < DONE then sl = decode(L, cl) end
    end
    return sl
end
C.finish = finish

-- slot of cluster (cluster row cr, column cc), decoded when needed; nil outside the grid
function C.slotAt(L, cr, cc)
    if cr < 0 or cc < 0 or cr >= L.cRows or cc >= L.cCols then return nil end
    return decode(L, cr * L.cCols + cc)
end

-- the cell (global grid row R, column C): slot, cell index, cluster, first piece (global), piece count
local function cellAt(L, R, Cc)
    local K = L.K
    local rr, rc = R % K, Cc % K
    local cr, cc = (R - rr) / K, (Cc - rc) / K
    if cr < 0 or cc < 0 or cr >= L.cRows or cc >= L.cCols then return nil end
    local cl = cr * L.cCols + cc
    local sl = decode(L, cl)
    local q = rr * K + rc
    local info = cInfo[sl * KKM + q + 1]
    if info < 0 then return nil end
    local n = info % 64
    return sl, q, cl, cl * PS + (info - n) / 64, n
end
C.cellAt = cellAt

-- piece gid: kind, factor code, centre (-1: straight), cell index in its cluster
local function pieceAttr(L, gid)
    local i = gid % PS
    local a = pAttr[decode(L, (gid - i) / PS)][i + 1]
    local q = floor(a / P2[33])
    a = a - q * P2[33]
    local c = floor(a / P2[23]) - 1
    a = a % P2[23]
    local k = a % 4
    return k, (a - k) / 4 % 32, c, q
end
C.pieceAttr = pieceAttr

-- the cell row and column of piece gid
local function pieceCell(L, gid)
    local cl = (gid - gid % PS) / PS
    local _, _, _, q = pieceAttr(L, gid)
    local qc, cc = q % L.K, cl % L.cCols
    return (cl - cc) / L.cCols * L.K + (q - qc) / L.K, cc * L.K + qc
end
C.pieceCell = pieceCell

-- the point of node nd on its A side (b = 0) or B side (b = 1), fine coordinates (cell centre), and its cluster;
-- nothing is decoded
function C.nodeUV(L, nd, b)
    local row, col, _, _, _, side = nodeRec(L, nd)
    if b == 1 then row, col = otherSide(side, row, col) end
    local cr, cc = (row - row % L.CL) / L.CL, (col - col % L.CL) / L.CL
    return row + 0.5, col + 0.5, cr * L.cCols + cc
end

-- the point of node nd on its A side (b = 0) or B side (b = 1), fine coordinates (cell centre), and its piece
function C.nodePoint(L, nd, b)
    local row, col, _, _, _, side, pa, pb = nodeRec(L, nd)
    local pi = pa
    if b == 1 then row, col = otherSide(side, row, col); pi = pb end
    local _, _, _, first = cellAt(L, (row - row % L.G) / L.G, (col - col % L.G) / L.G)
    return row + 0.5, col + 0.5, first + pi
end
