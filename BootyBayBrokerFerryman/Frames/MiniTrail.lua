local ADDON, ns = ...

local M = {}
ns.MiniTrail = M

M.BEADS = 48            -- bead textures: the way's next 48 beads at most
M.PITCH = 9             -- UI units from bead to bead along the way
M.BEAD = 5.6            -- UI units across a bead, its dark edge included
M.END = 12              -- UI units up the end mark
M.GAP = 1.4             -- a pitch is at least this many drawn bead widths (a small minimap on a small screen)
M.MARGIN = 0.15         -- of the view radius: beads are laid this far past the rim, and again after half of it is walked
M.ROAM = 8              -- view radii the canvas may wander from where it started before it starts anew
M.STILL = 0.2           -- seconds without a step after which the trail settles on whole pixels
M.GLIDE = 0.3           -- seconds a bead takes to its new place when the lead is laid anew
M.GLIDE_MAX = 36        -- UI units, four pitches: a bead moved farther is set at once
M.LEAD_OFF = 10         -- yards off the way from which the beads lead from the player to the way ahead,
M.LEAD_ON = 7           -- and yards off it down to which they go on doing so
M.LEAD_KEEP = 6         -- yards the player may be off that lead before it is laid again from where they stand
M.ART = "Interface\\AddOns\\" .. ADDON .. "\\Art\\"
-- The sizes the art is drawn at, in physical pixels: a mark is shown texel for pixel, never scaled.
M.BEAD_SIZES = { 5, 6, 7, 8, 9, 10, 12, 14, 16, 20 }
M.END_SIZES = { 10, 12, 14, 16, 20, 24, 32 }

local floor, abs, sqrt, min, huge = math.floor, math.abs, math.sqrt, math.min, math.huge

local frame, canvas, mask, mark
-- Bead n of the way (n pitches before its end) is drawn by texture n % BEADS + 1 for as long as it is laid.
local beads, slotN, slotX, slotY, slotOn, slotLaid = {}, {}, {}, {}, {}, {}
-- A bead on its way to a new place: where it set out from and how far it has come (0 to 1), else false.
local slotFX, slotFY, slotU, glides, mayGlide = {}, {}, {}, false, false
local shown, markOn, markX, markY = false, false, 0, 0
local snap, heard = nil, 0
-- The view the beads are laid for, read on each publish (a zoom publishes) and not every frame.
local vRot, vR, vW, vSq = false, 0, 0, false
-- UI units of one physical pixel and of one pitch; UI units a yard; the world point the canvas' centre stands for.
local unit, pitchU, scale, ox, oy = 0, M.PITCH, 1, 0, 0
-- The facing the marks are set for (0 on a fixed map) as its cosine and sine times the scale; the canvas'
-- offset; the seconds stood still, false once settled.
local lastX, lastY, lastF, cosF, sinF, canX, canY, still = 0, 0, 0, 1, 0, 0, 0, false
-- Where and for what the beads were last laid; the squared walk after which they are laid again.
local laidX, laidY, laidTrail, again, laid = 0, 0, false, 0, 0
-- The lead from a player off the way: the bead of the way it joins (false: none), that bead's place, and where
-- the player stood when it was drawn.
local leadN, leadRX, leadRY, leadX, leadY = false, 0, 0, 0, 0

local function Hide()
    if not shown then return end
    shown, laidTrail, leadN = false, false, false     -- an ended trip's trail is not kept
    frame:SetScript("OnUpdate", nil)
    frame:Hide()
end

local function Whole(v)
    return floor(v / unit + 0.5) * unit
end

-- A mark's place on the canvas for world point (x, y). On a fixed map it is a whole number of pixels, so every
-- mark shares the canvas' fraction of a pixel and all are drawn alike.
local function Put(tex, x, y)
    local e, north = oy - y, x - ox
    local sx, sy = e * cosF + north * sinF, north * cosF - e * sinF
    if not vRot then sx, sy = Whole(sx), Whole(sy) end
    tex:SetPoint("CENTER", canvas, "CENTER", sx, sy)
end

-- Bead n at world point (x, y). A bead that is where it was is not set again; one that a laying for the same
-- trail gives another place a pixel or more away, and not far (the lead laid anew), glides there. On a turning
-- map a bead neither glides nor is set here: Update sets every mark after a laying.
local function Bead(n, x, y)
    local s = n % M.BEADS + 1
    slotLaid[s] = laid
    local px, py = slotX[s], slotY[s]
    if slotN[s] ~= n or px ~= x or py ~= y then
        local d = mayGlide and not vRot and slotOn[s] and slotN[s] == n and ((x - px) * (x - px) + (y - py) * (y - py)) * scale * scale or 0
        slotN[s], slotX[s], slotY[s] = n, x, y
        if d >= unit * unit and d < M.GLIDE_MAX * M.GLIDE_MAX then
            slotFX[s], slotFY[s], slotU[s], glides = px, py, 0, true
        else
            slotU[s] = false
            if not vRot then Put(beads[s], x, y) end
        end
    end
    if not slotOn[s] then
        beads[s]:Show()
        slotOn[s] = true
    end
end

-- One frame of every glide.
local function Glide(elapsed)
    glides = false
    for s = 1, M.BEADS do
        local u = slotU[s]
        if u then
            u = u + elapsed / M.GLIDE
            if u >= 1 then
                slotU[s] = false
                Put(beads[s], slotX[s], slotY[s])
            else
                slotU[s], glides = u, true
                local e = u * u * (3 - 2 * u)
                Put(beads[s], slotFX[s] + (slotX[s] - slotFX[s]) * e, slotFY[s] + (slotY[s] - slotFY[s]) * e)
            end
        end
    end
end

-- Whether a lead may be laid: not indoors, and not while the player walks a side trail (5.5.15).
local function Free()
    return not ns.Env.now.indoors and not (snap.side and snap.side.held)
end

-- Whether the lead must be laid anew: the player came off the way or back onto it, left the lead as it is drawn,
-- or passed the bead it joins.
local function Astray(trip, x, y)
    local off = trip.off > (leadN and M.LEAD_ON or M.LEAD_OFF) and Free()
    if not (leadN and off) then return off ~= (leadN and true) end
    local vx, vy = leadRX - leadX, leadRY - leadY
    local len2 = vx * vx + vy * vy
    local t = len2 > 0 and ((x - leadX) * vx + (y - leadY) * vy) / len2 or 1
    t = t < 0 and 0 or t
    local dx, dy = leadX + vx * t - x, leadY + vy * t - y
    return t >= 1 or dx * dx + dy * dy > M.LEAD_KEEP * M.LEAD_KEEP or leadN * pitchU / scale > trip.foot
end

-- Lays the beads for a player at (x, y): one every pitch counted from the way's end, from the player's foot
-- point on the way (Trip.Advance's) to the first that lies past the rim's margin. Counting from the end fixes
-- every bead on the ground: walking on, or a new trail to the same end, moves no bead of an unchanged part. Off
-- the way the beads lead from the player: in a straight line to the first bead at or past the point the arrow
-- aims at, one every pitch counted from that bead, then along the way from that bead on. The lead lies on the
-- ground as it was laid until the player leaves it. Indoors there is no lead: a straight one would cross walls.
local function Lay(leg, x, y)
    local trip, trail = snap.trip, leg.trail
    local sx, sy, far, last = trail.x, trail.y, trail.far, trail.n
    local total, pitch = far[last], pitchU / scale
    local n, left, m = floor(trip.foot / pitch), M.BEADS, leg.i
    m = m < 1 and 1 or m > last - 1 and last - 1 or m
    local reach = vR * (1 + M.MARGIN) * (vSq and 1.4143 or 1)      -- a square map shows its corners
    reach = reach * reach
    laid, mayGlide = laid + 1, trail == laidTrail
    if not mayGlide then leadN = false end
    if Astray(trip, x, y) then
        leadN, leadX, leadY = trip.off > M.LEAD_ON and Free() and floor(trip.ahead / pitch), x, y
    end
    local lead = leadN
    if lead and lead < n then n = lead end
    -- Bead 1 would touch the end mark: the last bead is the second.
    while (n >= 2 or lead) and m < last do
        local a, b, d = total - far[m], total - far[m + 1], n * pitch
        if d < b then
            m = m + 1
        else
            local t = a > b and (a - d) / (a - b) or 0
            local bx, by = sx[m] + (sx[m + 1] - sx[m]) * t, sy[m] + (sy[m + 1] - sy[m]) * t
            if lead then
                -- From the bead the lead joins back toward where the player stood when it was laid: the beads
                -- the player has not passed.
                local vx, vy = leadX - bx, leadY - by
                local len, gone = sqrt(vx * vx + vy * vy), sqrt((x - bx) * (x - bx) + (y - by) * (y - by))
                leadRX, leadRY, lead = bx, by, false
                for k = 1, len > 0 and floor(min(len, gone) / pitch) or 0 do
                    if n + k >= 2 and left > 0 then
                        Bead(n + k, bx + vx / len * k * pitch, by + vy / len * k * pitch)
                        left = left - 1
                    end
                end
            end
            if n >= 2 then
                -- Out of textures, or the way has left the view: it is not followed back in.
                if left == 0 or (bx - x) * (bx - x) + (by - y) * (by - y) > reach then break end
                Bead(n, bx, by)
                left = left - 1
            end
            n = n - 1
        end
    end
    for s = 1, M.BEADS do
        if slotOn[s] and slotLaid[s] ~= laid then
            beads[s]:Hide()
            slotOn[s], slotU[s] = false, false
        end
    end
    -- The end mark, while the end is in reach; RestedXP marks its own target on a trip that follows it.
    local ex, ey, d = sx[last], sy[last], snap.dest
    if (ex - x) * (ex - x) + (ey - y) * (ey - y) <= reach and not (d and (d.source == "guide" or d.kind == "corpse")) then
        if not markOn or ex ~= markX or ey ~= markY then
            markX, markY = ex, ey
            Put(mark, ex, ey)
        end
        if not markOn then
            mark:Show()
            markOn = true
        end
    elseif markOn then
        mark:Hide()
        markOn = false
    end
    laidX, laidY, laidTrail = x, y, trail
end

-- The canvas carries every mark, so a step moves one frame, by fractions of a pixel. Only a turn of a turning
-- map sets each mark again, about the canvas' own point.
local function Place(x, y, f)
    if f ~= lastF then
        cosF, sinF = math.cos(f) * scale, math.sin(f) * scale
        for k = 1, M.BEADS do
            if slotOn[k] then Put(beads[k], slotX[k], slotY[k]) end
        end
        if markOn then Put(mark, markX, markY) end
    end
    lastX, lastY, lastF, still = x, y, f, 0
    local e, north = y - oy, ox - x
    canX, canY = e * cosF + north * sinF, north * cosF - e * sinF
    canvas:SetPoint("CENTER", frame, "CENTER", canX, canY)
end

local function Nearest(sizes, px)
    local best = sizes[1]
    for k = 2, #sizes do
        if abs(sizes[k] - px) < abs(best - px) then best = sizes[k] end
    end
    return best
end
M.Nearest = Nearest

-- Snapping goes off after the texture is set: a new texture may bring the client's defaults back.
local function Skin(tex, name, box)
    tex:SetTexture(M.ART .. name .. ".tga")
    tex:SetTexelSnappingBias(0)
    tex:SetSnapToPixelGrid(false)
    tex:SetSize(box, box)
end
M.Skin = Skin

-- The art for a screen on which one physical pixel is u UI units: the drawn size nearest the nominal one,
-- its file shown texel for pixel.
local function Art(u)
    unit = u
    local d = Nearest(M.BEAD_SIZES, M.BEAD / u)
    pitchU = math.max(M.PITCH, M.GAP * d * u)
    for k = 1, M.BEADS do
        Skin(beads[k], "TrailBead" .. d, (d <= 10 and 16 or 32) * u)
    end
    d = Nearest(M.END_SIZES, M.END / u)
    Skin(mark, "TrailEnd" .. d, (d <= 24 and 32 or 64) * u)
end

local function Texture(level)
    local tex = canvas:CreateTexture(nil, "OVERLAY", nil, level)
    tex:AddMaskTexture(mask)
    tex:Hide()
    return tex
end

local function Create()
    frame = CreateFrame("Frame", "FerrymanMiniTrail", Minimap)
    frame:SetAllPoints(Minimap)
    frame:EnableMouse(false)
    canvas = CreateFrame("Frame", nil, frame)
    canvas:SetSize(1, 1)
    mask = frame:CreateMaskTexture()
    mask:SetAllPoints(frame)
    for k = 1, M.BEADS do
        beads[k], slotN[k], slotOn[k], slotLaid[k], slotU[k] = Texture(0), 0, false, 0, false
        slotX[k], slotY[k], slotFX[k], slotFY[k] = 0, 0, 0, 0       -- full size now: no table grows later
    end
    mark = Texture(1)
    frame:Hide()
end

-- A new view: every offset changes, so the canvas starts anew at the player and every mark is set again.
local function View(x, y, rot, r, w, sq)
    vRot, vR, vW, vSq = rot, r, w, sq
    scale, ox, oy = w / 2 / r, x, y
    lastF, cosF, sinF = 0, scale, 0
    again = (r * M.MARGIN / 2) ^ 2
    mask:SetTexture(M.ART .. (sq and "TrailMaskSquare.tga" or "TrailMask.tga"), "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    for k = 1, M.BEADS do
        slotN[k], slotU[k] = 0, false
    end
    markX, laidTrail = huge, false
end

local Update

-- Every frame: the marks follow the ground under the player. The beads are laid again once the player has
-- walked half the margin; while a tick is spread over the frames before it reaches this module, that waits.
local function OnUpdate(_, elapsed)
    local lm, x, y = ns.Env.Position()
    if not lm then return end
    local dx, dy = x - laidX, y - laidY
    if dx * dx + dy * dy > again and snap.rev == heard then
        Update(false, false)
        if not shown then return end
    end
    -- A turn sets every mark again: in the frames a tick's publish is still on its way here, the turn waits.
    local f = vRot and snap.rev == heard and ns.Env.Facing() or lastF
    if x ~= lastX or y ~= lastY or f ~= lastF then
        Place(x, y, f)
    elseif still and not vRot then
        still = still + elapsed
        if still >= M.STILL then
            -- At rest the canvas goes to the nearest whole pixel of the screen: every mark is drawn as its art.
            still = false
            local cx, cy = frame:GetCenter()
            if cx then
                canvas:SetPoint("CENTER", frame, "CENTER", Whole(cx + canX) - cx, Whole(cy + canY) - cy)
            end
        end
    end
    -- A glide waits, as a turn does, for the frames of a tick: they carry the tick's work.
    if glides and snap.rev == heard then Glide(elapsed) end
end

-- Shows the trail for the snapshot as it stands, or hides it. A publish reads the view again (fresh); the
-- per-frame script does not. The beads are laid again when the way, the view or the player's reach changed, or
-- the player strayed from what is drawn.
Update = function(fresh, force)
    local s = snap
    local leg = s.trip and s.leg
    local trail = leg and leg.kind == "walk" and leg.trail
    -- A trail still straight between its entrances is not shown: the ground's own walk is on its way (5.5.8), and
    -- the beads laid for the trip before it, a quiet replan's, lead until it comes.
    if s.state ~= "walking" or not trail or trail.n < 2 or trail.raw and not laidTrail or not s.options.miniTrail then return Hide() end
    local lm, x, y = ns.Env.Position()
    if not lm or lm ~= leg.from.landmass then return Hide() end
    if trail.raw then return end
    if fresh then
        local rot, r, w, sq = ns.Env.MinimapRotates(), ns.Env.MinimapRadius(), Minimap:GetWidth(), ns.Env.MinimapSquare()
        if not r or r <= 0 or not w or w <= 0 then return Hide() end
        -- The minimap's own scale changes without an event (Edit Mode), so the pixel is measured on each publish.
        local ph, eff = GetPhysicalScreenSize and select(2, GetPhysicalScreenSize()), frame:GetEffectiveScale()
        local u = 768 / ((ph and ph > 0 and ph or 768) * (eff and eff > 0 and eff or 1))
        if u ~= unit then
            Art(u)
            vR = 0
        end
        if rot ~= vRot or r ~= vR or w ~= vW or sq ~= vSq then View(x, y, rot, r, w, sq) end
    end
    if not shown then
        shown, force = true, true
        frame:Show()
        frame:SetScript("OnUpdate", OnUpdate)
        if glides then Glide(M.GLIDE) end      -- a glide the hiding cut short ends at its place
    end
    local dx, dy = x - laidX, y - laidY
    if force or trail ~= laidTrail or dx * dx + dy * dy > again or fresh and Astray(s.trip, x, y) then
        dx, dy = x - ox, y - oy
        if dx * dx + dy * dy > M.ROAM * M.ROAM * vR * vR then View(x, y, vRot, vR, vW, vSq) end
        local f = vRot and (ns.Env.Facing() or lastF) or 0
        Lay(leg, x, y)
        -- on a turning map every mark is set here, once, after the laying
        if vRot then lastF = huge end
        Place(x, y, f)
    end
end

function M.OnChange(s, what)
    snap, heard = s, s.rev
    if what == "notice" then return end
    if not frame then
        if s.state ~= "walking" or not s.options.miniTrail then return end
        Create()
    end
    Update(true, what ~= "tick")
end

ns.Driver.Subscribe(M.OnChange)
