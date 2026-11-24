local ADDON, ns = ...

local M = {}
ns.MiniSide = M

M.DOTS = 24             -- dot textures: the side trail's next 24 dots at most
M.PITCH = 7             -- UI units from dot to dot along its way
M.DOT = 4.2             -- UI units across a dot, its dark edge included
M.GAP = 1.6             -- a pitch is at least this many drawn dot widths
M.SHORT = 1             -- the dot nearest the point lies this many pitches before it: the game's own mark there shows
M.MARGIN = 0.15         -- of the view radius, as MiniTrail's: dots are laid this far past the rim, again after half of it
M.ROAM = 8              -- view radii the canvas may wander from where it started before it starts anew
M.STILL = 0.2           -- seconds without a step after which the dots settle on whole pixels
M.ART = "Interface\\AddOns\\" .. ADDON .. "\\Art\\"
-- The sizes the art is drawn at, in physical pixels: a dot is shown texel for pixel, never scaled.
M.DOT_SIZES = { 3, 4, 5, 6, 7, 8, 10, 12 }

local floor, huge, min = math.floor, math.huge, math.min

local frame, canvas, mask, Nearest, Skin
-- Dot n of the way (n pitches before its end) is drawn by texture n % DOTS + 1 for as long as it is laid.
local dots, slotN, slotX, slotY, slotOn, slotLaid = {}, {}, {}, {}, {}, {}
local shown, snap = false, nil
-- The view the dots are laid for, read on each publish.
local vRot, vR, vW, vSq = false, 0, 0, false
-- UI units of one physical pixel and of one pitch; UI units a yard; the world point the canvas' centre stands for.
local unit, pitchU, scale, ox, oy = 0, M.PITCH, 1, 0, 0
-- The facing the dots are set for as its cosine and sine times the scale; the canvas' offset; seconds stood still.
local lastX, lastY, lastF, cosF, sinF, canX, canY, still = 0, 0, 0, 1, 0, 0, 0, false
-- Where and for which side trail (its rev) the dots were last laid; the squared walk after which they are laid again.
local laidX, laidY, laidRev, again, laid = 0, 0, false, 0, 0
-- The rev of the side trail with a trail the last publish acted on (false: none), and of the loop.
local heard, heardLoop = false, false

local function Hidden(v) return issecretvalue(v) or v == nil end

local function Hide()
    if not shown then return end
    shown, laidRev = false, false
    frame:SetScript("OnUpdate", nil)
    frame:Hide()
end

local function Whole(v)
    return floor(v / unit + 0.5) * unit
end

-- A dot's place on the canvas for world point (x, y), whole pixels on a fixed map, as MiniTrail's marks.
local function Put(tex, x, y)
    local e, north = oy - y, x - ox
    local sx, sy = e * cosF + north * sinF, north * cosF - e * sinF
    if not vRot then sx, sy = Whole(sx), Whole(sy) end
    tex:SetPoint("CENTER", canvas, "CENTER", sx, sy)
end

-- Lays a dot every pitch counted from the end of the side trail's way, from the player's foot point on it (the
-- tick's Trip.Advance) to SHORT pitches before the end, while textures last and the way stays in reach. Counted
-- from the end, every dot is fixed on the ground: walking on moves none, and a dot where it was is not set again.
-- On a turning map Update sets every dot after the laying.
local function Lay(side, x, y)
    local trail = side.walk.trail
    local sx, sy, far, last = trail.x, trail.y, trail.far, trail.n
    local total, pitch, m = far[last], pitchU / scale, side.walk.i
    m = m < 1 and 1 or m > last - 1 and last - 1 or m
    -- never from behind the foot's stretch, nor past the way's start
    local n, left = floor(min(side.foot, total - far[m]) / pitch), M.DOTS
    local reach = vR * (1 + M.MARGIN) * (vSq and 1.4143 or 1)      -- a square map shows its corners
    reach = reach * reach
    laid = laid + 1
    while n >= M.SHORT and left > 0 and m < last do
        local a, b, d = total - far[m], total - far[m + 1], n * pitch
        if d < b then
            m = m + 1
        else
            local t = a > b and (a - d) / (a - b) or 0
            local px, py = sx[m] + (sx[m + 1] - sx[m]) * t, sy[m] + (sy[m + 1] - sy[m]) * t
            if (px - x) * (px - x) + (py - y) * (py - y) > reach then break end
            local s = n % M.DOTS + 1
            slotLaid[s] = laid
            if slotN[s] ~= n or slotX[s] ~= px or slotY[s] ~= py then
                slotN[s], slotX[s], slotY[s] = n, px, py
                if not vRot then Put(dots[s], px, py) end
            end
            if not slotOn[s] then
                dots[s]:Show()
                slotOn[s] = true
            end
            left, n = left - 1, n - 1
        end
    end
    for s = 1, M.DOTS do
        if slotOn[s] and slotLaid[s] ~= laid then
            dots[s]:Hide()
            slotOn[s] = false
        end
    end
    laidX, laidY, laidRev = x, y, side.rev
end

-- The canvas carries every dot, so a step moves one frame; only a turn of a turning map sets each dot again.
local function Place(x, y, f)
    if f ~= lastF then
        cosF, sinF = math.cos(f) * scale, math.sin(f) * scale
        for k = 1, M.DOTS do
            if slotOn[k] then Put(dots[k], slotX[k], slotY[k]) end
        end
    end
    lastX, lastY, lastF, still = x, y, f, 0
    local e, north = y - oy, ox - x
    canX, canY = e * cosF + north * sinF, north * cosF - e * sinF
    canvas:SetPoint("CENTER", frame, "CENTER", canX, canY)
end

-- The art for a screen on which one physical pixel is u UI units, as MiniTrail's beads.
local function Art(u)
    unit = u
    local d = Nearest(M.DOT_SIZES, M.DOT / u)
    pitchU = math.max(M.PITCH, M.GAP * d * u)
    for k = 1, M.DOTS do
        Skin(dots[k], "TrailDot" .. d, (d <= 10 and 16 or 32) * u)
    end
end

-- One level over the trip's own frame, which a child of the minimap is given as this one is: a dot drawn on a
-- bead hides neither.
local function Create()
    Nearest, Skin = ns.MiniTrail.Nearest, ns.MiniTrail.Skin
    frame = CreateFrame("Frame", "FerrymanMiniSide", Minimap)
    frame:SetAllPoints(Minimap)
    frame:EnableMouse(false)
    frame:SetFrameLevel(frame:GetFrameLevel() + 1)
    canvas = CreateFrame("Frame", nil, frame)
    canvas:SetSize(1, 1)
    mask = frame:CreateMaskTexture()
    mask:SetAllPoints(frame)
    for k = 1, M.DOTS do
        local tex = canvas:CreateTexture(nil, "OVERLAY", nil, 0)
        tex:AddMaskTexture(mask)
        tex:Hide()
        dots[k], slotN[k], slotX[k], slotY[k], slotOn[k], slotLaid[k] = tex, -1, 0, 0, false, 0
    end
    frame:Hide()
end

-- A new view: the canvas starts anew at the player and every dot is set again.
local function View(x, y, rot, r, w, sq)
    vRot, vR, vW, vSq = rot, r, w, sq
    scale, ox, oy = w / 2 / r, x, y
    lastF, cosF, sinF = 0, scale, 0
    again = (r * M.MARGIN / 2) ^ 2
    mask:SetTexture(M.ART .. (sq and "TrailMaskSquare.tga" or "TrailMask.tga"), "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    for k = 1, M.DOTS do slotN[k] = -1 end
    laidRev = false
end

-- Every frame: the dots follow the ground under the player. Nothing is laid here.
local function OnUpdate(_, elapsed)
    local lm, x, y = ns.Env.Position()
    if not lm then return end
    local f = vRot and ns.Env.Facing() or lastF
    if x ~= lastX or y ~= lastY or f ~= lastF then
        Place(x, y, f)
    elseif still and not vRot then
        still = still + elapsed
        if still >= M.STILL then
            -- At rest the canvas goes to the nearest whole pixel of the screen: every dot is drawn as its art.
            still = false
            local cx, cy = frame:GetCenter()
            if cx then
                canvas:SetPoint("CENTER", frame, "CENTER", Whole(cx + canX) - cx, Whole(cy + canY) - cy)
            end
        end
    end
end

-- Shows the side trail for the snapshot as it stands, or hides it. The dots are laid again when the side trail,
-- the view or the pixel changed, the frame is shown again, or the player has walked half the margin.
local function Update()
    local side = snap.side
    local trail = side and side.walk.trail
    if not trail or trail.n < 2 or not snap.options.miniTrail then return Hide() end
    local lm, x, y = ns.Env.Position()
    if not lm or lm ~= side.landmass then return Hide() end
    -- A loop of its own source is the route, and the minimap draws that once: while dots of it are there, none of
    -- these (6.12).
    local loop = snap.loop
    if loop and loop.source == side.source and ns.MiniLoop.laid > 0 then return Hide() end
    local rot, r, w, sq = ns.Env.MinimapRotates(), ns.Env.MinimapRadius(), Minimap:GetWidth(), ns.Env.MinimapSquare()
    if Hidden(r) or Hidden(w) or r <= 0 or w <= 0 then return Hide() end
    local ph, eff = GetPhysicalScreenSize and select(2, GetPhysicalScreenSize()), frame:GetEffectiveScale()
    local u = 768 / ((ph and ph > 0 and ph or 768) * (eff and eff > 0 and eff or 1))
    if u ~= unit then
        Art(u)
        vR = 0
    end
    local keep = lastF      -- the facing a turning map keeps when the client gives none: a new view sets none
    if rot ~= vRot or r ~= vR or w ~= vW or sq ~= vSq then View(x, y, rot, r, w, sq) end
    if not shown then
        shown = true
        frame:Show()
        frame:SetScript("OnUpdate", OnUpdate)
    end
    local dx, dy = x - laidX, y - laidY
    if side.rev ~= laidRev or dx * dx + dy * dy > again then
        dx, dy = x - ox, y - oy
        if dx * dx + dy * dy > M.ROAM * M.ROAM * vR * vR then View(x, y, vRot, vR, vW, vSq) end
        local f = vRot and (ns.Env.Facing() or keep) or 0
        Lay(side, x, y)
        -- on a turning map every dot is set here, once, after the laying
        if vRot then lastF = huge end
        Place(x, y, f)
    end
end

-- Called by MapTrail.OnChange with every publish, first: this module does not subscribe.
function M.OnChange(s, what)
    snap = s
    local side, loop = s.side, s.loop
    local rev, lrev = side and side.walk.trail and side.rev or false, loop and loop.rev or false
    -- A notice changes nothing, unless a change of the side trail or the loop was marked with it and so published as
    -- the notice.
    if what == "notice" and rev == heard and lrev == heardLoop then return end
    heard, heardLoop = rev, lrev
    if not frame then
        if not (rev and s.options.miniTrail) then return end
        Create()
    end
    Update()
end
