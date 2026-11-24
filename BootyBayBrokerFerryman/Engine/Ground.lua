local ADDON, ns = ...

-- INTERFACES 4.5 over the walking data of tools/terrain/FORMAT.md (format 3, 4 or 5). A region is a piece. The parts:
-- GroundCodes (header, bit readers, the cluster cache), GroundPortals (portals, locate), GroundGrid (the grid
-- search and funnel), GroundSpread (the long-range spread), GroundTrail (measures, points, the anchor table),
-- GroundWalks (the drawn walks of formats 4 and 5).
local M = {}
ns.Ground = M

local floor, sqrt, max, min, huge = math.floor, math.sqrt, math.max, math.min, math.huge
M.SNAP, M.FAR_SNAP, M.LEVEL_MARGIN, M.CANDIDATES, M.ANCHOR_NEAR, M.SHORE = 50, 500, 6, 4, 40, 1000
M.settled, M.found = 0, {}

local C, P, Gr, Sp, Tr
local data, anchorN, build = nil, 0, nil
local mass, caps, pool, own = {}, {}, {}, nil

local function Parts()
    C, P, Gr, Sp, Tr = ns.GroundCodes, ns.GroundPortals, ns.GroundGrid, ns.GroundSpread, ns.GroundTrail
end

function M.Price(cost, land, inside, swim, risk)
    local real = land / cost.vLand + inside / cost.vInside + swim / cost.vSwim
    return real, real + (cost.factor - 1) * risk / cost.vLand
end

-- Takes landmass m's table from the data given to Attach once it is there: true, or false and why its anchor
-- table cannot be used (it is then attached without one).
function M.Load(m)
    if mass[m] then return true end
    local d = data and data[m]
    if type(d) ~= "table" then return false end
    if (d.format ~= 3 and d.format ~= 4 and d.format ~= 5) or d.map ~= m then return false, "Ferryman: walking.format:" .. m end
    local L = C.New(d, m == 0 and 0 or 1)
    L.id = m
    local ok, err = d.anchorCount == anchorN and d.netBuild == build, nil
    if not ok then err = "Ferryman: walking.network:" .. m end
    -- every anchor the data places stands near the point the network gives it, which walks are floored at (4.5,
    -- guarantee 10)
    local Net, ax, ay = ns.Net, {}, {}
    for a = 1, Net and Net.A and anchorN or 0 do
        local nd, x, y = L.anchorNode[a], nil, nil
        if nd then
            local u, v = C.nodeUV(L, nd, 0)
            x, y = L.x0 - u * L.cell, L.y0 - v * L.cell
        end
        local am, px, py = Net.Anchor(a)
        ax[a], ay[a] = px, py
        if ok and x and (am ~= m or (x - px) * (x - px) + (y - py) * (y - py) > M.ANCHOR_NEAR * M.ANCHOR_NEAR) then
            ok, err = false, "Ferryman: walking.anchor:" .. m .. ":" .. a
        end
    end
    -- an anchor table built for another network would hand the spreads wrong anchors: such data is not attached
    if not ok then return false, err end
    L.ax, L.ay = ax, ay
    if mass[m] then C.Forget(mass[m]) end      -- nil would forget the other landmass's clusters too
    mass[m] = L
    caps[m] = { split = true, inside = true, risk = true, heights = false, maps = false, indoors = true,
        pairs = true, digest = d.digest }
    return true
end

-- Keeps the table every landmass's data is (or will be) put in; attaches what is there now. useDrops changes
-- nothing: the shipped data is two-way.
function M.Attach(walkData, anchors, netBuild, useDrops)
    Parts()
    data, anchorN, build = walkData, anchors, netBuild
    C.Forget()
    mass, caps = {}, {}
    local err
    for m in pairs(walkData or {}) do
        local ok, e = M.Load(m)
        if not ok then err = e or err end
    end
    return err == nil, err
end

function M.Has(landmass) return mass[landmass] ~= nil end
function M.Caps(landmass) return caps[landmass] end

local function Mass(landmass)
    return mass[landmass] or error("Ferryman: walking.landmass:" .. tostring(landmass), 3)
end

-- A call that is not a search decodes with the pause it is given (none: it never pauses) and leaves the pause
-- of a search it interrupts as it was. While a bound is set (M.Bound, the client's calls from outside a job)
-- decoding stops with error(M.BUSY) once it has gone past that many steps; the next call carries on (16.7).
M.BOUND, M.BUSY = 5, "Ferryman: walking.busy"
local held = nil
-- Bound(nil) answers the units the bound had left (below 0 after BUSY)
function M.Bound(steps)
    local left = C.left
    if steps then held, C.pause = C.pause, nil else C.pause = held end
    C.left = steps
    return left
end
local function Run(pause, fn, a, b, c, d, e, f, g, h)
    local was = C.pause
    C.pause = pause
    local r1, r2, r3, r4 = fn(a, b, c, d, e, f, g, h)
    C.pause = was
    return r1, r2, r3, r4
end

function M.Locate(landmass, x, y, uiMap, indoors, prev, prevX, prevY, pause)
    if x ~= x or y ~= y then return 0, huge, 0 end      -- NaN: no place
    local n, snap, own, sure = Run(pause, P.Locate, Mass(landmass), x, y, indoors, prev, prevX, prevY, M.found)
    return n, n > 0 and snap or huge, own, sure
end

function M.Near(landmass, r1, r2) return Run(nil, P.Near, Mass(landmass), r1, r2) end
function M.Indoors(landmass, r) return Run(nil, C.pieceAttr, Mass(landmass), r) % 2 == 1 end

local function anchorRegion(a)
    for _, L in pairs(mass) do
        if L.anchorNode[a] then
            local _, _, piece = Sp.anchorPos(L, a, true)
            return piece
        end
    end
    return nil
end
function M.AnchorRegion(a) return Run(nil, anchorRegion, a) end

-- Whether two points of a landmass are too far apart for a spread to try a direct grid walk between them.
function M.Apart(landmass, x1, y1, x2, y2)
    local L, dx, dy = Mass(landmass), x1 - x2, y1 - y2
    return sqrt(dx * dx + dy * dy) > Sp.NEAR * L.CL * L.cell
end

-- Whether a spread settled a node of the clusters regions[1..n] stand in: the only nodes their joins reach.
local function touches(s, n, regions)
    local L = s.L
    for i = 1, n do
        local cl = floor(regions[i] / C.PS)
        local sl = C.finish(L, C.decode(L, cl), cl)
        local sn = C.snNode[sl]
        for k = 1, C.slotN[sl] do
            local _, closed = Sp.stOf(s, floor(sn[k] / 2))
            if closed then return true end
        end
    end
    return false
end
function M.Touches(s, n, regions) C.pause = s.pause; return touches(s, n, regions) end

function M.Pair(landmass, a, b, cost)
    local L = mass[landmass]
    if not (L and caps[landmass].pairs) then return nil end
    return Tr.Pair(L, a, b, cost)
end

-- Bit k of the numbers of t, 32 a number: whether it is set; with set, it is set now.
local function bit(t, k, set)
    local w, b = floor(k / 32), C.P2[k % 32]
    local on = (t[w] or 0) % (2 * b) >= b
    if set and not on then t[w] = (t[w] or 0) + b end
    return on
end
-- Led ground: what a walk from some anchor reaches. Its nodes are found by one spread from every anchor, once for a
-- landmass's data (L.led, a bit a node); a piece is led when a walk inside its cluster joins it to such a node
-- (a piece leaves its cluster only through a node). reach: the led pieces of the clusters in done. ownS, ownAt: a
-- spread from a start no anchor leads to, and that start: its own ground counts with the led (Shore).
local reach, done, queue, qn, ownS, ownAt = {}, {}, {}, 0, false, false
local function Wipe()
    for k in pairs(reach) do reach[k] = nil end
    for k in pairs(done) do done[k] = nil end
end
local function visit(cl, other)
    if floor(other / C.PS) == cl and not bit(reach, other, true) then qn = qn + 1; queue[qn] = other end
end
local function spreadIn(L, cl)
    done[cl] = true
    local sl = C.finish(L, C.decode(L, cl), cl)
    local sn, sp = C.snNode[sl], C.snPiece[sl]
    qn = 0
    for k = 1, C.slotN[sl] do
        local nd = floor(sn[k] / 2)
        if (bit(L.led, nd) or ownS and select(2, Sp.stOf(ownS, nd))) and not bit(reach, sp[k], true) then
            qn = qn + 1; queue[qn] = sp[k]
        end
    end
    for i = 1, ownAt and ownAt.n or 0 do visit(cl, ownAt[i]) end
    local i = 0
    while i < qn do
        i = i + 1
        P.eachPortal(L, queue[i], visit, cl)
        C.spend(1)
    end
end

-- The closest spot of the ground within maxYards: the nearest point of a sub-square some piece owns, a tenth of
-- a fine cell inside it. region, x, y, yards; nil when there is none. led: of led ground only.
local own16 = {}
local function nearest(L, x, y, maxYards, led)
    local G, cell = L.G, L.cell
    local u, v = (L.x0 - x) / cell, (L.y0 - y) / cell
    local R0, C0, sub = floor(u / G), floor(v / G), G / 4
    local best, bu, bv, bd = nil, 0, 0, huge
    for ring = 0, floor(maxYards / (cell * G)) + 1 do
        if best and (ring - 1) * G * cell > bd then break end
        for dR = -ring, ring do
            if led then C.spend(C.CHUNK) end     -- a row of a ring is a stretch of its own
            for dC = -ring, ring do
                if max(dR, -dR, dC, -dC) == ring then
                    local R, Cc = R0 + dR, C0 + dC
                    local sl, q, cl, first, npc = C.cellAt(L, R, Cc)
                    if sl and led and not done[cl] then
                        spreadIn(L, cl)
                        sl, q, cl, first, npc = C.cellAt(L, R, Cc)   -- the slot may have gone to another cluster
                    end
                    if sl then
                        if npc > 1 then P.readRaster(L.d.blocks, C.cRas[sl * 144 + q + 1] % C.P2[23], C.bitsFor(npc), own16)
                        else for k = 0, 15 do own16[k] = 0 end end
                        for k = 0, 15 do
                            local r0, c0 = R * G + floor(k / 4) * sub, Cc * G + k % 4 * sub
                            local pu, pv = max(r0 + 0.1, min(r0 + sub - 0.1, u)), max(c0 + 0.1, min(c0 + sub - 0.1, v))
                            local dd = sqrt((pu - u) * (pu - u) + (pv - v) * (pv - v)) * cell
                            local gid = first + own16[k]
                            if (dd < bd or (dd == bd and gid < best)) and (not led or bit(reach, gid)) then
                                best, bu, bv, bd = gid, pu, pv, dd
                            end
                        end
                    end
                end
            end
        end
    end
    if not best or bd > maxYards then return nil end
    return best, L.x0 - bu * cell, L.y0 - bv * cell, bd
end
function M.Nearest(landmass, x, y, maxYards, pause)
    if x == x and y == y then return Run(pause, nearest, Mass(landmass), x, y, maxYards) end
end

-- Whether the led nodes are known and none of regions[1..n] is led ground: no stop's walk leads there; and
-- whether some of them is not.
function M.Cut(landmass, n, regions, pause)
    local L, cut, some, was = mass[landmass], true, n == 0, C.pause
    if not (L and L.led) then return false, false end
    C.pause, ownS, ownAt = pause, false, false
    Wipe()
    for i = 1, n do
        local cl = floor(regions[i] / C.PS)
        if not done[cl] then spreadIn(L, cl) end
        local led = bit(reach, regions[i])
        cut, some = cut and not led, some or not led
    end
    C.pause = was
    return cut, some
end

---------------------------------------------------------------------------------------------------------------
-- Searches. A search object is GroundSpread's; the pause it was handed slices the grid work inside the calls.
function M.Acquire(pause)
    for i = 1, 2 do
        pool[i] = pool[i] or Sp.New()
        if not pool[i].busy then
            -- held only once filled: a job dropped while it fills holds nothing
            local big = 0
            for _, L in pairs(mass) do if L.N > big then big = L.N end end
            for _, L in pairs(mass) do if L.N == big then Sp.grow(pool[i], L, pause) end end
            pool[i].busy, pool[i].pause = true, pause
            return pool[i]
        end
    end
    return nil
end
function M.Release(s) s.busy = false end

function M.Begin(s, landmass, direction, cost)
    assert(direction == 1 or direction == -1, "Ferryman: walking.direction")
    C.pause = s.pause
    Sp.Begin(s, Mass(landmass), direction, cost)
end
function M.AddSource(s, region, x, y) C.pause = s.pause; Sp.AddSource(s, region, x, y) end
function M.SetPoint(s, n, regions, x, y) Sp.SetPoint(s, n, regions, x, y) end
function M.Advance(s, units) C.pause = s.pause; return Sp.Advance(s, units) end
function M.Frontier(s) return s.front end
function M.Reached(s, id) C.pause = s.pause; return Tr.Reached(s, id) end

local function Fill(wp, n)
    local x, y, z, far = wp.x, wp.y, wp.z, wp.far
    if n == 1 then x[2], y[2], n = x[1], y[1], 2 end
    wp.n = n
    far[1], z[1] = 0, false
    for i = 2, n do
        local dx, dy = x[i] - x[i - 1], y[i] - y[i - 1]
        far[i], z[i] = far[i - 1] + sqrt(dx * dx + dy * dy), false
    end
    return n
end
-- wp.raw: some line of the trail is still straight between two entrances of one cluster (wp.r, for Detail)
local function Raw(wp, n, lines) wp.raw = lines > 0; return Fill(wp, n) end
function M.Trail(s, id, wp)
    C.pause = s.pause
    wp.r = wp.r or {}
    return Raw(wp, Tr.Trail(s, id, wp.x, wp.y, wp.r))
end

-- Route, Refine, Detail, Survey and Shore share this object: one job runs at a time.
local function Own(pause)
    own = own or Sp.New()
    own.pause, C.pause = pause, pause
    return own
end
local function Drain(s, pause)
    while Sp.Advance(s, 64) do s.hits = 0; if pause then pause() end end
end

function M.Route(landmass, x1, y1, r1, x2, y2, r2, cost, wp, pause, limit)     -- r1, r2: a region or a list { n, [1..n] }
    local s, l1, l2 = Own(pause), type(r1) == "table", type(r2) == "table"
    Sp.Begin(s, Mass(landmass), 1, cost)
    for i = 1, l1 and r1.n or 1 do Sp.AddSource(s, l1 and r1[i] or r1, x1, y1) end
    if l2 then Sp.SetPoint(s, r2.n, r2, x2, y2) else s.ptR[1], s.npt, s.ptX, s.ptY = r2, 1, x2, y2 end
    local got = false
    while not got do
        local more = Sp.Advance(s, 64)
        for i = 1, s.hits do if s.hit[i] == 0 then got = true end end
        s.hits = 0
        if pause then pause() end
        if not more or limit and s.front > limit then break end     -- limit: padded seconds, past which no walk is had
    end
    if not got then wp.n = 0; return nil end
    wp.r = wp.r or {}
    Raw(wp, Tr.Trail(s, 0, wp.x, wp.y, wp.r))
    return Tr.Reached(s, 0)
end

-- The nearest spot of led ground within M.SHORE of a point that stands on none: region, x, y, yards, swum (the
-- spot is water: what lies between is swum). nil when there is none, or when the point's own spot is led. start
-- (optional, on this landmass): where it stands on ground no anchor leads to, that ground counts as led.
function M.Shore(landmass, x, y, cost, pause, start)
    local L, was = mass[landmass], C.pause
    if not L then return nil end
    if not L.led then
        local s, bits = Own(pause), {}
        Sp.Begin(s, L, 1, cost)
        for a in pairs(L.anchorNode) do Sp.AddAnchorSource(s, a) end
        Drain(s, pause)
        for nd = 0, L.N - 1 do
            local _, closed = Sp.stOf(s, nd)
            if closed then bit(bits, nd, true) end
            if nd % 512 == 511 then C.spend(4) end
        end
        L.led = bits
    end
    local isle = start and start.n > 0 and M.Cut(landmass, start.n, start, pause) and Own(pause)
    if isle then
        Sp.Begin(isle, L, 1, cost)
        for i = 1, start.n do Sp.AddSource(isle, start[i], start.x, start.y) end
        Drain(isle, pause)
    end
    C.pause, ownS, ownAt = pause, isle, isle and start
    Wipe()
    local piece, x2, y2, yards = nearest(L, x, y, M.SHORE, true)
    local water = piece and C.pieceAttr(L, piece) >= 2
    C.pause, ownS, ownAt = was, false, false
    if piece and yards > 0 then return piece, x2, y2, yards, water end
end

-- The walk between two points on known pieces of one cluster, following the ground inside it: its points in fine,
-- or nil when the two are not in one cluster or no walk inside it is found.
function M.Refine(landmass, x1, y1, r1, x2, y2, r2, fine, pause)
    Own(pause)
    local n = Gr.refine(Mass(landmass), x1, y1, r1, x2, y2, r2, fine.x, fine.y)
    return n and Fill(fine, n)
end

-- A trail as the ground walks it. Trail and Route draw a straight line between two entrances of one cluster and
-- leave what its ends stand on in wp.r (GroundTrail); here every such line becomes the walk between them, in place, all at
-- once when every walk is found (a line without a walk stays), and then once more with its entrances ahead of at.i
-- crossed straight (GroundTaut.Free), drawn() (optional) after each. at (optional): at.i, an index into wp, read when
-- the walk is written, moves with its point. Returns the points added; wp.raw is false from then on.
local fx, fy, fa, fd, fm, dx, dy, da, dd, dm, dn, tot, s1, s2 = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
local MX, MY, PA, PD, PM, ST, WK, RW = {}, {}, {}, {}, {}, {}, {}, {}
local function Piece(L, e)
    if e >= 0 then return e end
    local side = (-e - 1) % 2
    local _, _, p = C.nodePoint(L, (-e - 1 - side) / 2, side)
    return p
end
function M.Detail(landmass, wp, at, pause, drawn)
    local r, n, m = wp.r, wp.n, 0
    if not wp.raw then return 0 end
    Own(pause)
    local L, x, y = Mass(landmass), wp.x, wp.y
    for k = 1, n - 1 do
        s1[k], s2[k] = r[2 * k - 1] and Piece(L, r[2 * k - 1]), r[2 * k] and Piece(L, r[2 * k])
        local got = s1[k] and Gr.refine(L, x[k], y[k], s1[k], x[k + 1], y[k + 1], s2[k], fx, fy, fa, fd, fm)
        dn[k], tot[k] = got and got > 2 and got - 2 or 0, got and fm[got]
        for q = 2, dn[k] + 1 do
            m = m + 1
            dx[m], dy[m], da[m], dd[m], dm[m] = fx[q], fy[q], fa[q], fd[q], fm[q]
        end
    end
    -- the walk in MX, MY, each point with what it stands on and the run-yards to it, for the entrances
    local w, j = 0, 0
    for k = 1, n do
        local a, b = k > 1 and s2[k - 1], k < n and s1[k]
        w = w + 1
        MX[w], MY[w], PA[w], PD[w], PM[w], ST[w], WK[w] = x[k], y[k], a or b, b or a, a and tot[k - 1] or 0, true, b and true
        RW[k] = w
        if k % 16 == 0 then C.spend(1) end
        for _ = 1, k < n and dn[k] or 0 do
            j, w = j + 1, w + 1
            MX[w], MY[w], PA[w], PD[w], PM[w], ST[w], WK[w] = dx[j], dy[j], da[j], dd[j], dm[j], false, true
        end
    end
    for k = 1, w do x[k], y[k] = MX[k], MY[k] end
    wp.raw = false
    if at then at.i = RW[at.i] end
    Fill(wp, w)
    if drawn then drawn() end
    local kept
    w, kept = ns.GroundTaut.Free(L, MX, MY, w, PA, PD, PM, ST, WK, at)    -- it pauses, and keeps wp up to at.i + 1
    if kept then
        for k = 1, w do x[k], y[k] = MX[k], MY[k] end
        Fill(wp, w)
        if drawn then drawn() end
    end
    return w - n
end

function M.Survey(landmass, x, y, n, regions, cost, rows, pause)
    local s = Own(pause)
    Sp.Begin(s, Mass(landmass), 1, cost)
    for i = 1, n do Sp.AddSource(s, regions[i], x, y) end
    Drain(s, pause)
    local count = 0
    for a = 1, anchorN do
        local _, _, land, inside, swim, risk = Tr.Reached(s, a)
        if land then count = count + 1 end
        rows[4 * a - 3], rows[4 * a - 2], rows[4 * a - 1], rows[4 * a] = land or -1, inside or -1, swim or -1, risk or -1
    end
    return count
end
