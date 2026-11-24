local ADDON, ns = ...

-- Drawn walks (formats 4 and 5 of tools/terrain/FORMAT.md): where a walk drawn through a piece crosses its portals
-- and bends inside it, so the line on the map stays on the floor, and in format 5 the floor itself, which says
-- what a point sees and which piece lies under it. Gr.funnel asks when it draws, the look for W.On.
local W = {}
ns.GroundWalks = W

local C, Gr = ns.GroundCodes, ns.GroundGrid
local byte, abs, min, max, floor, sqrt, huge = string.byte, math.abs, math.min, math.max, math.floor, math.sqrt, math.huge
local PS, NONE24, P2 = C.PS, C.NONE24, C.P2

-- A record: its kind (0: only portals pinned to a point; 1 rooted: a walk through passes the root; 2 a hub: only a
-- walk that starts or ends here does), the root (ru, rv), n polylines, polyline k's points u, v [s[k] .. s[k + 1] - 1],
-- its head first, towards the root; g[k]: a guard's, not a portal's. The last two records read are kept; where the
-- records of a cluster's pieces start is read once a cluster and kept for the last 24 clusters of one landmass.
local at, rb, rg = C.at, C.rb, C.rg
local function New() return { s = {}, u = {}, v = {}, g = {}, m = {}, lo = {}, hi = {} } end
local wA, wB, wC, wOff, wFor, wN = New(), New(), New(), {}, nil, 0
-- A record of format 5: its nodes, the marks 1 .. nm (a portal or the cell a node stands on, each at the point it
-- is known by; g[k]: 1 crossed at that point, 2 between lo[k] and hi[k] along its line, fine cells from the cell's
-- corner), then the points to n where walks bend; sight: m holds, sixteen to a number, which two nodes see each
-- other; floor: where its floor by quarter starts.
local function read5(w, L, R, Cc)
    local G, qb, s, u, v, g, fl = L.G, L.pb + 2, w.s, w.u, w.v, w.g, rb(2)
    w.sight, w.nm, w.r0, w.c0 = fl % 2 == 1, rg() - 1, R * G, Cc * G
    local n = w.nm
    for k = 1, n do
        s[k], u[k] = k, R * G + rb(8) / 8
        v[k] = Cc * G + rb(8) / 8
        g[k] = rb(2)
        if g[k] == 2 then w.lo[k] = rb(8) / 8; w.hi[k] = rb(8) / 8 end
    end
    if w.sight then
        for k = n + 1, n + rg() - 1 do
            n, u[k] = k, R * G + (rb(qb) + 0.5) / 4
            v[k] = Cc * G + (rb(qb) + 0.5) / 4
        end
        for i = 0, n * (n - 1) / 2 - 1, 16 do w.m[i / 16 + 1] = rb(min(16, n * (n - 1) / 2 - i)) end
    end
    w.n, w.floor = n, fl >= 2 and C.pos()
    return w
end
local function record(L, gid, into)
    if not into then
        if wB.gid == gid and wB.L == L then wA, wB = wB, wA end
        if wA.gid == gid and wA.L == L then return wA.n and wA end
        wA, wB = wB, wA
    end
    local w, d, i = into or wA, L.d, gid % PS
    local cl, G, R, Cc = (gid - i) / PS, L.G, C.pieceCell(L, gid)
    w.gid, w.L, w.n, w.nm = false, L, false, nil    -- named once read: a call cut short leaves no half record
    if wFor ~= L or wN >= 24 then
        for k in pairs(wOff) do wOff[k] = nil end
        wFor, wN = L, 0
    end
    local off = wOff[cl]
    if not off then
        local b1, b2, b3 = byte(d.walkIndex, cl * 3 + 1, cl * 3 + 3)
        off, wN = { k = 0, n = 0 }, wN + 1
        wOff[cl] = off
        if b1 + b2 * 256 + b3 * 65536 ~= NONE24 then at(d.walks, (b1 + b2 * 256 + b3 * 65536) * 8); off.n, off.at = rg() - 1, C.pos() end
    end
    while off.k <= i and off.k < off.n do      -- 8 records a unit up to the one asked, kept for the next call
        at(d.walks, off.at)
        for p = off.k, min(off.n, off.k + 8) - 1 do local len = rg() - 1; off[p] = len > 0 and C.pos(); C.skip(len) end
        off.k, off.at = min(off.n, off.k + 8), C.pos()
        C.spend(1)
    end
    w.gid = gid
    if not off[i] then return false end
    at(d.walks, off[i])
    if d.format == 5 then return read5(w, L, R, Cc) end
    local s, u, v, g, m, qb = w.s, w.u, w.v, w.g, 0, L.pb + 2
    w.kind = rb(2)
    w.rooted = w.kind == 1
    if w.kind > 0 then w.ru = R * G + rb(8) / 8; w.rv = Cc * G + rb(8) / 8 end
    w.n = rg() - 1
    for k = 1, w.n do
        m = m + 1
        s[k], g[k] = m, rb(1) == 1
        if g[k] then
            u[m] = R * G + (rb(qb) + 0.5) / 4
            v[m] = Cc * G + (rb(qb) + 0.5) / 4
        else
            u[m] = R * G + rb(8) / 8
            v[m] = Cc * G + rb(8) / 8
        end
        for _ = 2, rg() do
            m = m + 1
            u[m] = R * G + (rb(qb) + 0.5) / 4
            v[m] = Cc * G + (rb(qb) + 0.5) / 4
        end
    end
    s[w.n + 1] = m + 1
    return w
end

-- the polyline of record w whose head lies on the portal (a1, a2) to (b1, b2), or nil; in format 5 its mark there
local function head(w, a1, a2, b1, b2)
    for k = 1, w and (w.nm or w.n) or 0 do
        local hu, hv = w.u[w.s[k]], w.v[w.s[k]]
        if (a1 == b1 and hu == a1 and hv >= min(a2, b2) - 0.5 and hv <= max(a2, b2) + 0.5)
            or (a2 == b2 and hv == a2 and hu >= min(a1, b1) - 0.5 and hu <= max(a1, b1) + 0.5) then return k end
    end
end
-- the point of record w nearest (x, y): polyline and index in it (0: the root); in a hub, of its guards only
local function nearest(w, x, y)
    local bk, bj, bd = 0, 0, (w.ru - x) ^ 2 + (w.rv - y) ^ 2
    for k = 1, w.n do
        for j = w.s[k], (w.rooted or w.g[k]) and w.s[k + 1] - 1 or 0 do
            local dd = (w.u[j] - x) ^ 2 + (w.v[j] - y) ^ 2
            if dd < bd then bk, bj, bd = k, j - w.s[k], dd end
        end
    end
    return bk, bj
end

-- The funnel's list being laid (Gr.funnel): point k as a portal with both ends at it, on piece p.
local F1, F2, F3, F4, FP, np, base
local function put(x, y, p)
    np = np + 1
    F1[np], F2[np], F3[np], F4[np], FP[np] = x, y, x, y, p
end
-- polyline k of w from its point `first` in to the root (k 0: the root alone)
local function inward(w, k, first, p)
    for j = k > 0 and w.s[k] + first or 1, k > 0 and w.s[k + 1] - 1 or 0 do put(w.u[j], w.v[j], p) end
    put(w.ru, w.rv, p)
end
-- and from the root out to its point `last`: where the list just came in along the same points, it turns back at
-- the point where the two ways part instead of going on to the root
local function outward(w, k, last, p)
    local j = w.s[k + 1] - 1
    while j >= w.s[k] + last and np - 1 >= base and F1[np - 1] == w.u[j] and F2[np - 1] == w.v[j]
        and F3[np - 1] == F1[np - 1] and F4[np - 1] == F2[np - 1] do
        np, j = np - 1, j - 1
    end
    for q = j, w.s[k] + last, -1 do put(w.u[q], w.v[q], p) end
end

-- a portal no record names a point for, crossed as the funnel crosses it: at its middle when it is a door, else
-- anywhere along it less a margin at an end inside the cell's edge
local function free(G, a1, a2, b1, b2)
    local du, dv = b1 - a1, b2 - a2
    local len = abs(du) + abs(dv) + 1
    if len < Gr.DOOR * G then
        a1, a2 = (a1 + b1) / 2, (a2 + b2) / 2
        b1, b2 = a1, a2
    elseif len > 1 then
        local mg = Gr.MARGIN / (len - 1)
        if (du ~= 0 and a1 % G ~= 0.5 and a1 % G ~= G - 0.5) or (dv ~= 0 and a2 % G ~= 0.5 and a2 % G ~= G - 0.5) then
            a1, a2 = a1 + du * mg, a2 + dv * mg
        end
        if (du ~= 0 and b1 % G ~= 0.5 and b1 % G ~= G - 0.5) or (dv ~= 0 and b2 % G ~= 0.5 and b2 % G ~= G - 0.5) then
            b1, b2 = b1 - du * mg, b2 - dv * mg
        end
    end
    return a1, a2, b1, b2
end
W.Free = free

---------------------------------------------------------------------------------------------------------------
-- Format 5. The floors last asked are kept, piece gid's at gid % FLOORS, each as rows of bits, two numbers of 32 a
-- row (false: the data holds none for the piece, which fills its cell or stands alone in it). A floor is read 64 bits
-- a unit into its reader's own table: a call out of a job (pend[1]) and a job (pend[2]) each carry on their own; the
-- straight lines' samples (W.Far) keep their own floors, reader and record (LINE), and a drawn walk's sights theirs
-- (DRAW): neither pushes one of the look's out.
local FLOORS, pend = 32, { { F = {} }, { F = {} } }
local LOOK, LINE = { key = {}, L = {}, row = {}, tab = {} }, { key = {}, L = {}, row = {}, tab = {}, p = { F = {} }, w = New() }
local DRAW = { key = {}, L = {}, row = {}, tab = {} }
-- the squares left of p's floor from bit p.at: row, column and size, three numbers a square, the last read first
local function quad(p)
    local F, n, stop = p.F, p.n, p.at + 64
    at(p.L.d.walks, p.at)
    while n > 0 and C.pos() < stop do
        local r, c, s = p[n - 2], p[n - 1], p[n]; n = n - 3
        if s > 1 and rb(1) == 0 then
            s = s / 2
            for k = 3, 0, -1 do p[n + 1], p[n + 2], p[n + 3], n = r + (k >= 2 and s or 0), c + k % 2 * s, s, n + 3 end
        elseif rb(1) == 1 then
            local h, x = c >= 32 and 1 or 0, (P2[min(s, 32)] - 1) * P2[c % 32]
            for i = 2 * r, 2 * (r + s) - 2, 2 do F[i + h] = F[i + h] + x; if s > 32 then F[i + 1] = F[i + 1] + x end end
        end
    end
    p.n, p.at = n, C.pos()
end
local function floorOf(L, gid, w, c)
    local k, p, own = gid % FLOORS + 1, c.p or pend[C.left and 1 or 2], c.w or wC
    if c.key[k] == gid and c.L[k] == L then return c.row[k] end
    if p.gid ~= gid or p.L ~= L then
        w = w or record(L, gid, own)      -- the look's own record: a walk being laid keeps its two
        if not (w and w.floor) then c.key[k], c.L[k], c.row[k] = gid, L, false; return false end
        for i = 0, 8 * L.G - 1 do p.F[i] = 0 end
        p.gid, p.L, p.at, p.n, p[1], p[2], p[3] = gid, L, w.floor, 3, 0, 0, 4 * L.G
    end
    while p.n > 0 and p.gid == gid and p.L == L do quad(p); C.spend(1) end
    -- a call made while a job paused read this floor, or began another (and may have taken the record)
    if p.gid ~= gid or p.L ~= L then return floorOf(L, gid, w ~= own and w or nil, c) end
    local F = p.F
    p.gid, c.key[k], c.L[k], c.row[k], c.tab[k], p.F = nil, gid, L, F, F, c.tab[k] or {}
    return F
end
local function bit(F, r, c) return floor(F[2 * r + (c >= 32 and 1 or 0)] / P2[c % 32]) % 2 == 1 end
-- Where a point (quarters from the cell's corner) stands on floor F of Q quarters a side: itself on a quarter of
-- floor, else the middle of the nearest one within two quarters and a half (a body stands closer to a wall than
-- the floor is written), and how far that is, squared; nil when there is none.
local function stand(F, Q, u, v)
    local r0, c0, bu, bv, bd = floor(u), floor(v), nil, nil, 6.25
    if r0 >= 0 and c0 >= 0 and r0 < Q and c0 < Q and bit(F, r0, c0) then return u, v, 0 end
    local c1, c2 = max(c0 - 2, 0), min(c0 + 2, Q - 1)
    local a1, n0, n1 = max(c1, 32) - 32, min(c2, 31) - c1 + 1, c2 - max(c1, 32) + 1   -- c1 to c2 in each half of a row
    for r = max(r0 - 2, 0), min(r0 + 2, Q - 1) do
        if n0 > 0 and floor(F[2 * r] / P2[c1]) % P2[n0] > 0 or n1 > 0 and floor(F[2 * r + 1] / P2[a1]) % P2[n1] > 0 then
            for c = c1, c2 do
                local dd = (r + 0.5 - u) ^ 2 + (c + 0.5 - v) ^ 2
                if dd < bd and bit(F, r, c) then bu, bv, bd = r + 0.5, c + 0.5, dd end
            end
        end
    end
    return bu, bv, bd
end
-- Whether the straight line between two points, in quarters from the cell's corner, lies on floor F of Q quarters
-- a side: every quarter it passes. An end on the piece's edge counts as the quarter inside it.
local function clear(F, Q, u1, v1, u2, v2)
    local du, dv = u2 - u1, v2 - v1
    u1, v1, u2, v2 = u1 + du * 1e-3, v1 + dv * 1e-3, u2 - du * 1e-3, v2 - dv * 1e-3
    local r, c, r2, c2 = floor(u1), floor(v1), floor(u2), floor(v2)
    local tr = du ~= 0 and ((du > 0 and r + 1 or r) - u1) / du or huge
    local tc = dv ~= 0 and ((dv > 0 and c + 1 or c) - v1) / dv or huge
    for _ = 0, 2 * Q do
        if r < 0 or c < 0 or r >= Q or c >= Q or not bit(F, r, c) then return false end
        if r == r2 and c == c2 then return true end
        if tr < tc then r, tr = r + (du > 0 and 1 or -1), tr + abs(1 / du) else c, tc = c + (dv > 0 and 1 or -1), tc + abs(1 / dv) end
    end
    return false
end

-- How far piece gid's floor lies from (u, v), fine coordinates: 0 under it (and where the data holds no floor for
-- the piece: it fills its cell), else the squared quarters to its nearest quarter within two and a half; nil
-- beyond, and on data without floors.
function W.On(L, gid, u, v)
    if L.d.format ~= 5 then return nil end
    local F, R, Cc = floorOf(L, gid, nil, LOOK), C.pieceCell(L, gid)
    if not F then return 0 end
    local at, _, dd = stand(F, 4 * L.G, (u - R * L.G) * 4, (v - Cc * L.G) * 4)
    return at and dd
end

-- The samples of a stretch of a line on piece gid, from (au, av) to (bu, bv) in fine coordinates, at j / (s + 1) of
-- the way for j = 1 .. s: whether each far from the floor (W.On nil) passes ok(u, v); a floor not yet kept may pause.
function W.Far(L, gid, au, av, bu, bv, s, ok)
    local F = s > 0 and L.d.format == 5 and floorOf(L, gid, nil, LINE)
    if not F then return true end
    local R, Cc = C.pieceCell(L, gid)
    local Q, r0, c0 = 4 * L.G, R * L.G, Cc * L.G
    for j = 1, s do
        local u, v = au + (bu - au) * j / (s + 1), av + (bv - av) * j / (s + 1)
        local qu, qv = (u - r0) * 4, (v - c0) * 4
        local r, c = floor(qu), floor(qv)
        if not (r >= 0 and c >= 0 and r < Q and c < Q and bit(F, r, c)) and not stand(F, Q, qu, qv) and not ok(u, v) then
            return false
        end
    end
    return true
end

local function sees(w, a, b)
    if a > b then a, b = b, a end
    local i = (a - 1) * w.n - (a - 1) * a / 2 + b - a - 1
    return floor(w.m[(i - i % 16) / 16 + 1] / P2[i % 16]) % 2 == 1
end
-- Whether a walk's end at (x, y), standing on the floor of record w's piece, sees (tu, tv) over it (both: where
-- that point stands on the floor too). A piece without a floor in the data fills its cell: all of it is seen.
local function looks(L, w, x, y, tu, tv, both)
    local F, Q = floorOf(L, w.gid, w, DRAW), 4 * L.G
    if not F then return true end
    local qu, qv = stand(F, Q, (x - w.r0) * 4, (y - w.c0) * 4)
    tu, tv = (tu - w.r0) * 4, (tv - w.c0) * 4
    if both then tu, tv = stand(F, Q, tu, tv) end
    return qu and tu and clear(F, Q, qu, qv, tu, tv) or false
end
-- A walk's end at (x, y) in the piece of record w: the mark it is (the cell a node stands on), else 0 and in s
-- every node it sees over the floor; an end that sees none goes by the nearest point.
local function attach(L, w, x, y, s)
    for k = 1, w.nm do if abs(w.u[k] - x) < 1e-6 and abs(w.v[k] - y) < 1e-6 then return k end end
    local bk, bd, any = 0, huge, false
    for k = 1, w.n do
        C.spend(0.25)       -- a node's sight over the floor
        local dd = (w.u[k] - x) ^ 2 + (w.v[k] - y) ^ 2
        s[k] = looks(L, w, x, y, w.u[k], w.v[k])
        any = any or s[k]
        if k > w.nm and dd < bd then bk, bd = k, dd end
    end
    if not any and bk > 0 then s[bk] = true end
    return 0
end
-- Where mark k of record w pins its portal (a1, a2)-(b1, b2): the point, or the stretch with its ends in the
-- portal's order.
local function span(w, k, a1, a2, b1, b2)
    if w.g[k] == 1 then return w.u[k], w.v[k], w.u[k], w.v[k] end
    local lo, hi = w.lo[k], w.hi[k]
    if b1 + b2 < a1 + a2 then lo, hi = hi, lo end
    if a1 == b1 then return a1, w.c0 + lo, b1, w.c0 + hi end
    return w.r0 + lo, a2, w.r0 + hi, b2
end
-- The stretch (a1, a2)-(b1, b2) of a portal as a walk's end at (x, y) in the piece of w crosses it with nothing
-- between: all of it when the end sees both its ends, else its point nearest the end when it sees that, else the
-- portal's own point (mu, mv), which it sees.
local function narrow(L, w, x, y, a1, a2, b1, b2, mu, mv)
    if a1 == b1 and a2 == b2 or looks(L, w, x, y, a1, a2) and looks(L, w, x, y, b1, b2) then return a1, a2, b1, b2 end
    local du, dv = b1 - a1, b2 - a2
    local t = max(0, min(1, ((x - a1) * du + (y - a2) * dv) / (du * du + dv * dv)))
    local fu, fv = a1 + du * t, a2 + dv * t
    if looks(L, w, x, y, fu, fv) then return fu, fv, fu, fv end
    return mu, mv, mu, mv
end

-- Lays the points of the shortest way through record w from node a to node b, every stretch between two nodes
-- that see each other; the way may pass a mark at its point. a (b) 0: the walk's start (end) at (au, av)
-- ((bu, bv)), which sees the nodes of sS (sE), and the other end where sS[0] says so. True when a and b see each
-- other: nothing is laid.
local dist, prev, done, stack, sS, sE = {}, {}, {}, {}, {}, {}
local function via(w, a, b, au, av, bu, bv, p)
    local n, u, v, best, bk = w.n, w.u, w.v, huge, 0
    if a > 0 and b > 0 then if a == b or sees(w, a, b) then return true end
    elseif a > 0 then if sE[a] then return true end
    elseif b > 0 then if sS[b] then return true end
    elseif sS[0] then return true end
    for k = 1, n do
        local s = k ~= a and k ~= b and (a > 0 and sees(w, a, k) or a == 0 and sS[k])
        dist[k], prev[k], done[k] = s and sqrt((au - u[k]) ^ 2 + (av - v[k]) ^ 2) or huge, 0, k == a or k == b
    end
    while true do
        local k, d = 0, best
        for i = 1, n do if not done[i] and dist[i] < d then k, d = i, dist[i] end end
        if k == 0 then break end
        done[k] = true
        C.spend(n / 200)    -- a node settled: n sights read
        if b > 0 and sees(w, k, b) or b == 0 and sE[k] then
            local t = d + sqrt((u[k] - bu) ^ 2 + (v[k] - bv) ^ 2)
            if t < best then best, bk = t, k end
        end
        for i = 1, n do
            local t = not done[i] and sees(w, k, i) and d + sqrt((u[k] - u[i]) ^ 2 + (v[k] - v[i]) ^ 2)
            if t and t < dist[i] then dist[i], prev[i] = t, k end
        end
    end
    local m = 0
    while bk > 0 do m = m + 1; stack[m] = bk; bk = prev[bk] end
    for i = m, 1, -1 do put(u[stack[i]], v[stack[i]], p) end
end

-- Format 5's list for Gr.funnel: inside a piece with sights the points of the shortest way between the portal the
-- walk comes in by and the one it leaves by, none when the two see each other; from the start and to the end by
-- what each sees over the floor. A portal is crossed where either piece pins it (a point before a stretch), else
-- as the funnel crosses it; one the start or the end sees with nothing between, where that end sees it (narrow).
local function Lay5(L, chain, m, gP, gA1, gA2, gB1, gB2, su, sv, eu, ev)
    local G, was, wasIn, gid, w, cross = L.G, nil, 0, nil, nil, 0
    for k = m, 1, -1 do
        local st = chain[k]
        gid = gP[st]
        C.spend(1)
        w = record(L, gid)
        if k == m then
            wasIn = w and w.sight and attach(L, w, su, sv, sS)
        else
            local a1, a2, b1, b2, from = gA1[st], gA2[st], gB1[st], gB2[st], gP[chain[k + 1]]
            local ho, hi, direct = head(was, a1, a2, b1, b2), head(w, a1, a2, b1, b2), false
            if was and was.sight and wasIn and ho then      -- the way out of the piece being left
                local au, av = wasIn > 0 and was.u[wasIn] or su, wasIn > 0 and was.v[wasIn] or sv
                direct = via(was, wasIn, ho, au, av, was.u[ho], was.v[ho], from) and wasIn == 0
            end
            -- pinned to a point by either piece, else to a stretch by either, else free
            local x = ho and was.g[ho] == 1 and was or hi and w.g[hi] == 1 and w or ho and was.g[ho] == 2 and was
                or hi and w.g[hi] == 2 and w
            if x then a1, a2, b1, b2 = span(x, x == was and ho or hi, a1, a2, b1, b2) else a1, a2, b1, b2 = free(G, a1, a2, b1, b2) end
            if direct then a1, a2, b1, b2 = narrow(L, was, su, sv, a1, a2, b1, b2, was.u[ho], was.v[ho]) end
            np = np + 1
            F1[np], F2[np], F3[np], F4[np], FP[np] = a1, a2, b1, b2, from
            cross, wasIn = np, w and hi
        end
        was = w
    end
    if was and was.sight and wasIn then
        local e = attach(L, was, eu, ev, sE)
        sS[0] = e == 0 and wasIn == 0 and looks(L, was, su, sv, eu, ev, true)
        local au, av = wasIn > 0 and was.u[wasIn] or su, wasIn > 0 and was.v[wasIn] or sv
        if via(was, wasIn, e, au, av, eu, ev, gid) and e == 0 and wasIn > 0 and cross > 0 then
            F1[cross], F2[cross], F3[cross], F4[cross] = narrow(L, was, eu, ev, F1[cross], F2[cross], F3[cross], F4[cross], au, av)
        end
    end
    return np
end

-- The points a drawn walk passes, for Gr.funnel in place of its own list when the data has drawn walks: through a
-- rooted piece along its polylines by the root, from a start or to an end in a rooted piece or a hub by the
-- record's point nearest it, across a portal at the head either piece names for it, else as the funnel crosses it.
-- Returns the count before the walk's end.
function W.Lay(L, chain, m, gP, gA1, gA2, gB1, gB2, f1, f2, f3, f4, fp, su, sv, eu, ev)
    F1, F2, F3, F4, FP, np, base = f1, f2, f3, f4, fp, 0, 0
    if L.d.format == 5 then return Lay5(L, chain, m, gP, gA1, gA2, gB1, gB2, su, sv, eu, ev) end
    local G, was, gid = L.G, nil, nil
    for k = m, 1, -1 do
        local st = chain[k]
        gid = gP[st]
        local w = record(L, gid)
        if k < m then
            local a1, a2, b1, b2, from = gA1[st], gA2[st], gB1[st], gB2[st], gP[chain[k + 1]]
            local hk, ok = head(w, a1, a2, b1, b2), head(was, a1, a2, b1, b2)
            if ok and was.rooted then
                outward(was, ok, 0, from)
            elseif hk or ok then
                local x = hk and w or was
                put(x.u[x.s[hk or ok]], x.v[x.s[hk or ok]], from)
            else
                np = np + 1
                F1[np], F2[np], F3[np], F4[np] = free(G, a1, a2, b1, b2)
                FP[np] = from
            end
            base = np
            if w and w.rooted then inward(w, hk or 0, 1, gid) end
        elseif w and w.kind > 0 then
            local vk, vj = nearest(w, su, sv)
            inward(w, vk, vj, gid)
        end
        was = w
    end
    if was and was.kind > 0 then
        if was.kind == 2 and m > 1 then put(was.ru, was.rv, gid) end
        local vk, vj = nearest(was, eu, ev)
        if vk > 0 then outward(was, vk, vj, gid) end
    end
    return np
end
