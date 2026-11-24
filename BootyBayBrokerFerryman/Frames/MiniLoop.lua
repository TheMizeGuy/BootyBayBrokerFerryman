local ADDON, ns = ...

-- The loop (INTERFACES 5.5.16, 6.12) on the minimap: the part of its own line in view, as dots of the side trail's
-- look, fixed on the ground and even round the whole closed way. It does not subscribe: MapTrail hands it every
-- publish. What the dots are found by is made when a loop is taken; a frame then examines STEP of it at most.
local M = {}
ns.MiniLoop = M

M.DOTS = 96             -- dot textures: the dots of the loop in reach, at most
M.PIECE = 32            -- yards of the way round in a piece, at least: a pass steps from piece to piece
M.PIECES = 256          -- pieces at most: a longer loop has longer ones
M.STEP = 6              -- what a frame examines while the dots are laid again: a piece counts 1, a dot placed 2
M.BUSY = 0.03           -- seconds: a shorter frame waits out a tick's publish on its way here; a longer one runs its slice
M.laid = 0              -- 1 while a dot of the last pass lies inside the view: MiniSide leaves the route to it (6.10, S8)

local floor, ceil, sqrt, max, min, huge = math.floor, math.ceil, math.sqrt, math.max, math.min, math.huge

local frame, canvas, mask, Nearest, Skin, Look      -- Look: MiniSide, whose dot, pitch and margins these are
local dots, slotX, slotY, slotOn = {}, {}, {}, {}
-- The dots laid, by their number round the loop, ascending, each with its texture: the last pass's list, and the one
-- the pass at hand writes. The textures that passed dots gave up, still shown, and the hidden ones.
local oldN, oldS, nOld, newN, newS, nNew = {}, {}, 0, {}, {}, 0
local stale, nStale, spare, nSpare = {}, 0, {}, 0
local shown, snap, mass, heard, told = false, nil, false, false, 0     -- told: the snapshot's rev last heard
-- The view the dots are laid for, read on each publish.
local vRot, vR, vW, vSq = false, 0, 0, false
-- UI units of one physical pixel and of one pitch; UI units a yard; the world point the canvas' centre stands for.
local unit, pitchU, scale, ox, oy = 0, 7, 1, 0, 0
-- The facing the dots are set for as its cosine and sine times the scale; the canvas' offset; seconds stood still.
local lastX, lastY, lastF, cosF, sinF, canX, canY, still = 0, 0, 0, 1, 0, 0, 0, false
-- The loop prepared (its rev; false: none): the way round to each point and in all, its pieces' length and count,
-- and for each piece the point it begins after and where it begins.
local prep, far, total, piece, nPieces, pieceI, pieceX, pieceY = false, {}, 0, 0, 0, {}, {}, {}
-- The dots round the loop and the yards from one to the next. The pass at hand: its piece (false: none), its dot
-- (-1: the piece not looked at yet), its stretch and its place in the last pass's list; where the player stood as it
-- began; the reach squared, the reach and a piece, the squared walk that begins the next; whether a dot found no
-- texture, and whether the pass is the one more that such a dot gets.
local count, pitch = 0, 0
local pk, pj, pi, pOld, laidX, laidY = false, -1, 1, 1, 0, 0
local reach2, outer, again, short, retried = 0, 0, 0, false, false

local function Hidden(v) return issecretvalue(v) or v == nil end

local function Hide()
    if not shown then return end
    shown, M.laid = false, 0
    frame:SetScript("OnUpdate", nil)
    frame:Hide()
end

local function Whole(v)
    return floor(v / unit + 0.5) * unit
end

-- A dot's place on the canvas for world point (x, y), turned as the dots are set; whole pixels on a fixed map.
local function Put(tex, x, y)
    local e, north = oy - y, x - ox
    local sx, sy = e * cosF + north * sinF, north * cosF - e * sinF
    if not vRot then sx, sy = Whole(sx), Whole(sy) end
    tex:SetPoint("CENTER", canvas, "CENTER", sx, sy)
end

-- What the dots are found by, once a loop: the way round to each point, and the loop cut into pieces of one length.
local function Prepare(loop)
    local x, y, n = loop.x, loop.y, loop.n
    far[1] = 0
    for i = 1, n do
        local j = i < n and i + 1 or 1
        far[i + 1] = far[i] + sqrt((x[j] - x[i]) ^ 2 + (y[j] - y[i]) ^ 2)
    end
    for i = n + 2, #far do far[i] = nil end
    total = far[n + 1]
    nPieces = max(1, min(M.PIECES, ceil(total / M.PIECE)))
    piece = total / nPieces
    local i = 1
    for k = 1, nPieces do
        local a = (k - 1) * piece
        while i < n and far[i + 1] <= a do i = i + 1 end
        local l, j = far[i + 1] - far[i], i < n and i + 1 or 1
        local t = l > 0 and (a - far[i]) / l or 0
        pieceI[k], pieceX[k], pieceY[k] = i, x[i] + (x[j] - x[i]) * t, y[i] + (y[j] - y[i]) * t
    end
    for k = nPieces + 1, #pieceI do pieceI[k], pieceX[k], pieceY[k] = nil, nil, nil end
    prep = loop.rev
end

-- Every dot laid is of another loop, pitch or view: its texture is the next pass's to take, or to hide.
local function Drop()
    for p = pk and pOld or 1, nOld do
        nStale = nStale + 1
        stale[nStale] = oldS[p]
    end
    for p = 1, pk and nNew or 0 do
        nStale = nStale + 1
        stale[nStale] = newS[p]
    end
    nOld, nNew, pk = 0, 0, false
end

local function Begin(x, y)
    laidX, laidY = x, y
    pk, pj, pOld, nNew, short = 1, -1, 1, 0, false
end

-- Dot j of the pass at (x, y), in reach. A pass meets the dots in the order of the last one's list: the dots of
-- that list before j were not met again and give their textures up; j keeps its own, where it is; a new dot takes
-- a texture given up, else a hidden one, and with neither waits for one more pass.
local function Dot(j, x, y)
    local p = pOld
    while p <= nOld and oldN[p] < j do
        nStale = nStale + 1
        stale[nStale], p = oldS[p], p + 1
    end
    local s
    if p <= nOld and oldN[p] == j then
        s, p = oldS[p], p + 1
    else
        if nStale > 0 then
            s, nStale = stale[nStale], nStale - 1
        elseif nSpare > 0 then
            s, nSpare = spare[nSpare], nSpare - 1
        end
        if s then
            slotX[s], slotY[s] = x, y
            Put(dots[s], x, y)
            if not slotOn[s] then
                dots[s]:Show()
                slotOn[s] = true
            end
        end
    end
    pOld = p
    if s then
        nNew = nNew + 1
        newN[nNew], newS[nNew] = j, s
    else
        short = true
    end
end

-- 1 when a dot of the last pass lies inside the view about where it began, as set now; else 0.
local function Inside()
    local h2 = vW * vW / 4
    for p = 1, nOld do
        local s = oldS[p]
        local e, north = laidY - slotY[s], slotX[s] - laidX
        local sx, sy = e * cosF + north * sinF, north * cosF - e * sinF
        if vSq and sx * sx <= h2 and sy * sy <= h2 or not vSq and sx * sx + sy * sy <= h2 then return 1 end
    end
    return 0
end

-- The pass is over: every texture given up and not taken is hidden, and the list written is the next pass's.
local function Done()
    for p = pOld, nOld do
        nStale = nStale + 1
        stale[nStale] = oldS[p]
    end
    for k = 1, nStale do
        local s = stale[k]
        dots[s]:Hide()
        slotOn[s], nSpare = false, nSpare + 1
        spare[nSpare] = s
    end
    oldN, oldS, nOld, newN, newS, nStale, pk = newN, newS, nNew, oldN, oldS, 0, false
    M.laid = Inside()
    retried = short and nSpare > 0 and not retried
    if retried then Begin(laidX, laidY) end
end

-- A slice of the pass, piece by piece round the loop. A piece that begins farther off than the reach and a piece has
-- no dot in reach, nor has any after it that the way round is too short to bring there. A piece wholly in reach
-- whose dots the last pass laid keeps them as they are. Of any other piece each dot is placed, one the last pass
-- laid where it lies, and in reach is laid.
local function Pass(steps)
    local loop = snap.loop
    local x, y, n, k, j, i = loop.x, loop.y, loop.n, pk, pj, pi
    while k <= nPieces and steps > 0 do
        if j < 0 then
            steps = steps - 1
            local dx, dy = pieceX[k] - laidX, pieceY[k] - laidY
            local d = sqrt(dx * dx + dy * dy)
            if d > outer then
                k = k + max(1, floor((d - outer) / piece))
            else
                j, i = ceil((k - 1) * count / nPieces), pieceI[k]
                local m, p = ceil(k * count / nPieces) - j, pOld
                if m > 0 and d + 2 * piece <= outer and p + m - 1 <= nOld and oldN[p] == j and oldN[p + m - 1] == j + m - 1 then
                    for q = p, p + m - 1 do
                        nNew = nNew + 1
                        newN[nNew], newS[nNew] = oldN[q], oldS[q]
                    end
                    pOld, k, j, steps = p + m, k + 1, -1, steps - 0.1 * m
                end
            end
        elseif j >= ceil(k * count / nPieces) then
            k, j = k + 1, -1
        else
            local s = pOld <= nOld and oldN[pOld] == j and oldS[pOld]
            if s then
                local dx, dy = slotX[s] - laidX, slotY[s] - laidY
                pOld, steps = pOld + 1, steps - 0.5
                if dx * dx + dy * dy <= reach2 then
                    nNew = nNew + 1
                    newN[nNew], newS[nNew] = j, s
                else
                    nStale = nStale + 1
                    stale[nStale] = s
                end
            else
                steps = steps - 2
                local a = j * pitch
                while i < n and far[i + 1] < a and steps > 0 do i, steps = i + 1, steps - 0.25 end
                -- a stretch crowded with points: this dot is placed in the next slice, from where this one stopped
                if i < n and far[i + 1] < a then break end
                local l, b = far[i + 1] - far[i], i < n and i + 1 or 1
                local t = l > 0 and (a - far[i]) / l or 0
                local px, py = x[i] + (x[b] - x[i]) * t, y[i] + (y[b] - y[i]) * t
                if (px - laidX) * (px - laidX) + (py - laidY) * (py - laidY) <= reach2 then Dot(j, px, py) end
            end
            j = j + 1
        end
    end
    pk, pj, pi = k, j, i
    if k > nPieces then Done() end
end

-- The dots of list from a to b, turned about the player: a turning map's, which are not set on whole pixels.
local function Turn(list, a, b)
    local X, Y, cos, sin, x0, y0, tex, on = slotX, slotY, cosF, sinF, ox, oy, dots, canvas
    for q = a, b do
        local s = list[q]
        local e, north = y0 - Y[s], X[s] - x0
        tex[s]:SetPoint("CENTER", on, "CENTER", e * cos + north * sin, north * cos - e * sin)
    end
end

-- The canvas carries every dot, so a step moves one frame; only a turn of a turning map sets each dot again: those
-- of the last pass, and in the middle of a pass those it has laid and those given up and still shown.
local function Place(x, y, f)
    if f ~= lastF then
        cosF, sinF = math.cos(f) * scale, math.sin(f) * scale
        Turn(oldS, pk and pOld or 1, nOld)
        if pk then
            Turn(newS, 1, nNew)
            Turn(stale, 1, nStale)
        end
    end
    lastX, lastY, lastF, still = x, y, f, 0
    local e, north = y - oy, ox - x
    canX, canY = e * cosF + north * sinF, north * cosF - e * sinF
    canvas:SetPoint("CENTER", frame, "CENTER", canX, canY)
end

-- The art for a screen on which one physical pixel is u UI units: the side trail's dot and pitch.
local function Art(u)
    unit = u
    local d = Nearest(Look.DOT_SIZES, Look.DOT / u)
    pitchU = max(Look.PITCH, Look.GAP * d * u)
    for s = 1, M.DOTS do
        Skin(dots[s], "TrailDot" .. d, (d <= 10 and 16 or 32) * u)
    end
end

-- At the side trail's frame level, one over the trip's own: a dot drawn on a bead hides neither.
local function Create()
    Look, Nearest, Skin = ns.MiniSide, ns.MiniTrail.Nearest, ns.MiniTrail.Skin
    frame = CreateFrame("Frame", "FerrymanMiniLoop", Minimap)
    frame:SetAllPoints(Minimap)
    frame:EnableMouse(false)
    frame:SetFrameLevel(frame:GetFrameLevel() + 1)
    canvas = CreateFrame("Frame", nil, frame)
    canvas:SetSize(1, 1)
    mask = frame:CreateMaskTexture()
    mask:SetAllPoints(frame)
    for s = 1, M.DOTS do
        local tex = canvas:CreateTexture(nil, "OVERLAY", nil, 0)
        tex:AddMaskTexture(mask)
        tex:Hide()
        dots[s], slotX[s], slotY[s], slotOn[s], spare[s] = tex, 0, 0, false, s
        oldN[s], oldS[s], newN[s], newS[s], stale[s] = 0, 0, 0, 0, 0       -- full size now: no table grows later
    end
    nSpare = M.DOTS
    frame:Hide()
end

-- A new view: the canvas starts anew at the player, and every dot is laid again at the view's pitch, the least that
-- sets a whole number of dots evenly round the loop.
local function View(x, y, rot, r, w, sq)
    vRot, vR, vW, vSq = rot, r, w, sq
    scale, ox, oy = w / 2 / r, x, y
    lastF, cosF, sinF = 0, scale, 0
    local reach = r * (1 + Look.MARGIN) * (sq and 1.4143 or 1)      -- a square map shows its corners
    reach2, outer, again = reach * reach, reach + piece, (r * Look.MARGIN / 2) ^ 2
    count = floor(total * scale / pitchU)
    pitch = count > 0 and total / count or 0
    mask:SetTexture(Look.ART .. (sq and "TrailMaskSquare.tga" or "TrailMask.tga"), "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    Drop()
end

-- Every frame: the dots follow the ground under the player; once half the margin is walked a pass lays them again,
-- a slice a frame.
local function OnUpdate(_, elapsed)
    local lm, x, y = ns.Env.Position()
    local loop = snap.loop
    -- With no position, on another landmass, or between a change of the loop and its publish: nothing until that.
    if lm ~= mass or not loop or loop.rev ~= prep then return end
    local f = vRot and ns.Env.Facing() or lastF
    if x ~= lastX or y ~= lastY or f ~= lastF then
        Place(x, y, f)
    elseif still and not vRot then
        still = still + elapsed
        if still >= Look.STILL then
            -- At rest the canvas goes to the nearest whole pixel of the screen: every dot is drawn as its art.
            still = false
            local cx, cy = frame:GetCenter()
            if cx then
                canvas:SetPoint("CENTER", frame, "CENTER", Whole(cx + canX) - cx, Whole(cy + canY) - cy)
            end
        end
    end
    -- The frames in which a tick's publish is on its way here carry the tick's work: the pass waits for them, where
    -- frames are short enough that it does not wait for every one.
    if snap.rev ~= told and elapsed < M.BUSY then return end
    if pk then return Pass(M.STEP) end
    local dx, dy = x - laidX, y - laidY
    if dx * dx + dy * dy <= again then return end
    dx, dy = x - ox, y - oy
    if dx * dx + dy * dy > Look.ROAM * Look.ROAM * vR * vR then
        -- the canvas has wandered far from where it started: anew at the player, every dot at once
        View(x, y, vRot, vR, vW, vSq)
        Begin(x, y)
        Pass(huge)
        if pk then Pass(huge) end
        return Place(x, y, f)
    end
    Begin(x, y)
    Pass(M.STEP)
end

-- Shows the loop for the snapshot as it stands, or hides it. A new loop, view or pixel, and the frame shown again,
-- lay every dot at once; the per-frame script lays them as the player walks.
local function Update()
    local loop = snap.loop
    if not (loop and snap.options.miniTrail) then return Hide() end
    local lm, x, y = ns.Env.Position()
    if not lm or lm ~= loop.landmass then return Hide() end
    local rot, r, w, sq = ns.Env.MinimapRotates(), ns.Env.MinimapRadius(), Minimap:GetWidth(), ns.Env.MinimapSquare()
    if Hidden(r) or Hidden(w) or r <= 0 or w <= 0 then return Hide() end
    if not frame then Create() end
    local ph, eff = GetPhysicalScreenSize and select(2, GetPhysicalScreenSize()), frame:GetEffectiveScale()
    local u = 768 / ((ph and ph > 0 and ph or 768) * (eff and eff > 0 and eff or 1))
    if shown and loop.rev == prep and u == unit and rot == vRot and r == vR and w == vW and sq == vSq then return end
    if loop.rev ~= prep then Prepare(loop) end
    if u ~= unit then Art(u) end
    local f = rot and (ns.Env.Facing() or lastF) or 0
    View(x, y, rot, r, w, sq)
    mass = lm
    if not shown then
        shown = true
        frame:Show()
        frame:SetScript("OnUpdate", OnUpdate)
    end
    Begin(x, y)
    Pass(huge)
    if pk then Pass(huge) end
    Place(x, y, f)
end

-- Called by MapTrail.OnChange with every publish: this module does not subscribe.
function M.OnChange(s, what)
    snap, told = s, s.rev
    local loop = s.loop
    local rev = loop and loop.rev or false
    -- A notice changes nothing, unless a change of the loop was marked with it and so published as the notice.
    if what == "notice" and rev == heard then return end
    heard = rev
    -- A loop taken away keeps nothing here.
    if not loop and prep then prep, far, pieceI, pieceX, pieceY = false, {}, {}, {}, {} end
    -- Nothing is made before a loop can show (L1): Update makes it.
    if not frame and not (loop and s.options.miniTrail) then return end
    Update()
end
