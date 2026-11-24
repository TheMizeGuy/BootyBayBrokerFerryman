local ADDON, ns = ...

-- Marks (INTERFACES 5.6, 6.14, decision 136) on the minimap: the world map's treasure look, smaller, at each mark
-- within the minimap's view while the player's map holds a set, following the player as MiniSide's dots do. They are
-- laid from each set's cells, again once the player has walked MARGIN / 2 of the view radius, so a frame costs only
-- the marks near the player. It does not subscribe: MapMarks hands it every publish, first.
local M = {}
ns.MiniMarks = M

M.SIZE = 10             -- UI units across a mark
M.MARKS = 48            -- mark textures: the first 48 marks within reach at most
M.MARGIN, M.ROAM = 0.15, 8      -- as MiniSide's: marks are laid this far past the rim; view radii the canvas may wander
M.ART = "Interface\\AddOns\\" .. ADDON .. "\\Art\\"

local floor, huge, cos, sin = math.floor, math.huge, math.cos, math.sin
local Marks, Env = ns.Marks, ns.Env
local ROUND, SQUARE = M.ART .. "TrailMask.tga", M.ART .. "TrailMaskSquare.tga"
local frame, canvas, mask
local tex, tx, ty, made, used = {}, {}, {}, 0, 0
local shown = false
-- The view the marks are laid for; UI units a yard; the world point the canvas' centre stands for, on landmass land.
local vRot, vR, vW, vSq, scale, ox, oy, land = false, 0, 0, false, 1, 0, 0, false
-- The facing the marks are set for, as its cosine and sine times the scale; where and for which rev they were laid.
local lastX, lastY, lastF, cosF, sinF, laidX, laidY, laidRev, again = 0, 0, 0, 1, 0, 0, 0, false, 0
local gateMap, gateRev, gate = false, false, false     -- the player's map and Marks' rev the gate was asked for

local function Hidden(v) return issecretvalue(v) or v == nil end

local function Hide()
    if not shown then return end
    shown, laidRev = false, false
    frame:SetScript("OnUpdate", nil)
    frame:Hide()
end

-- A mark's place on the canvas for world point (x, y), turned with the minimap.
local function Put(k, x, y)
    local e, north = oy - y, x - ox
    tex[k]:SetPoint("CENTER", canvas, "CENTER", e * cosF + north * sinF, north * cosF - e * sinF)
end
-- The canvas carries every mark, so a step moves one frame; only a turn of a turning map sets each mark again.
local function Place(x, y, f)
    if f ~= lastF then
        cosF, sinF = cos(f) * scale, sin(f) * scale
        for k = 1, used do Put(k, tx[k], ty[k]) end
    end
    lastX, lastY, lastF = x, y, f
    local e, north = y - oy, ox - x
    canvas:SetPoint("CENTER", frame, "CENTER", e * cosF + north * sinF, north * cosF - e * sinF)
end

local function New(k)
    local t = canvas:CreateTexture(nil, "ARTWORK")
    t:SetAtlas(ns.MapMarks.ATLAS.mark)
    t:SetSize(M.SIZE, M.SIZE)
    t:SetTexelSnappingBias(0)
    t:SetSnapToPixelGrid(false)
    t:AddMaskTexture(mask)
    t:Hide()
    tex[k], tx[k], ty[k], made = t, false, false, k
end

-- The marks within reach of (x, y) on landmass lm: the cells within reach of each set whose box is, MARKS at most.
-- A texture that shows the same mark again is not set again; textures not laid are hidden.
local function Lay(lm, x, y)
    local list, reach, k, cell = Marks.Land(lm), vR * (1 + M.MARGIN) * (vSq and 1.4143 or 1), 0, Marks.CELL
    local r2, j0, j1 = reach * reach, floor((y - reach) / cell), floor((y + reach) / cell)
    -- the cells within reach are the keys from lo to hi whose column is from j0 to j1 (Marks.Cell)
    local lo, hi = Marks.Cell(floor((x - reach) / cell), j0), Marks.Cell(floor((x + reach) / cell), j1)
    for i = 1, list and list.n or 0 do
        if k == M.MARKS then break end
        local set = list[i]
        if set.x0 <= x + reach and set.x1 >= x - reach and set.y0 <= y + reach and set.y1 >= y - reach then
            local sx, sy, ord, ck, cf, c, a, b = set.x, set.y, set.ord, set.ck, set.cf, set.c, 1, set.c + 1
            while a < b do
                local mid = floor((a + b) / 2)
                if ck[mid] < lo then a = mid + 1 else b = mid end
            end
            while a <= c and ck[a] <= hi and k < M.MARKS do
                local j = ck[a] % 8192 - 4096
                for o = cf[a], (j >= j0 and j <= j1) and (a < c and cf[a + 1] or set.n + 1) - 1 or 0 do
                    local px, py = sx[ord[o]], sy[ord[o]]
                    if (px - x) * (px - x) + (py - y) * (py - y) <= r2 then
                        k = k + 1
                        if k > made then New(k) end
                        if px ~= tx[k] or py ~= ty[k] then
                            tx[k], ty[k] = px, py
                            if not vRot then Put(k, px, py) end
                        end
                        if k == M.MARKS then break end
                    end
                end
                a = a + 1
            end
        end
    end
    for i = used + 1, k do tex[i]:Show() end
    for i = k + 1, used do tex[i]:Hide() end
    used, laidX, laidY, laidRev = k, x, y, Marks.rev
end

-- A new view: the canvas starts anew at the player and every mark is set again.
local function View(lm, x, y, rot, r, w, sq)
    vRot, vR, vW, vSq, land = rot, r, w, sq, lm
    scale, ox, oy = w / 2 / r, x, y
    lastF, cosF, sinF = 0, scale, 0
    again = (r * M.MARGIN / 2) ^ 2
    mask:SetTexture(sq and SQUARE or ROUND, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    for k = 1, made do tx[k] = false end
end

-- The view read again; the marks laid again when it, the sets or the landmass changed, or the player has walked
-- MARGIN / 2 of the radius; then placed. A radius or width the client hides hides the marks.
local function Relay(lm, x, y)
    local rot, r, w, sq = Env.MinimapRotates(), Env.MinimapRadius(), Minimap:GetWidth(), Env.MinimapSquare()
    if Hidden(r) or Hidden(w) or r <= 0 or w <= 0 then return Hide() end
    local new = rot ~= vRot or r ~= vR or w ~= vW or sq ~= vSq or lm ~= land
        or (x - ox) * (x - ox) + (y - oy) * (y - oy) > M.ROAM * M.ROAM * r * r
    local f = rot and (Env.Facing() or lastF) or 0      -- before a new view, which forgets the last facing
    if new then View(lm, x, y, rot, r, w, sq) end
    if new or laidRev ~= Marks.rev or (x - laidX) * (x - laidX) + (y - laidY) * (y - laidY) > again then
        Lay(lm, x, y)
        if vRot then lastF = huge end       -- on a turning map every mark is set once, after the laying
    end
    Place(x, y, f)
end

-- Every frame while shown: the marks follow the player; laid again only past MARGIN / 2 of the radius.
local function OnUpdate()
    local lm, x, y = Env.Position()
    if not lm then return end
    local f = vRot and Env.Facing() or lastF
    if x == lastX and y == lastY and f == lastF then return end
    if lm ~= land or (x - laidX) * (x - laidX) + (y - laidY) * (y - laidY) > again then return Relay(lm, x, y) end
    Place(x, y, f)
end

-- Whether the player's map holds a set, asked again only when that map or the sets changed.
local function Here()
    local uiMap, rev = Env.now.uiMap, Marks.rev
    if uiMap ~= gateMap or rev ~= gateRev then gateMap, gateRev, gate = uiMap, rev, Marks.Here(uiMap) end
    return gate
end

-- One level under the trip's beads: the canvas keeps its frame's level, which MiniTrail's frame has.
local function Create()
    frame = CreateFrame("Frame", "FerrymanMiniMarks", Minimap)
    frame:SetAllPoints(Minimap)
    frame:EnableMouse(false)
    canvas = CreateFrame("Frame", nil, frame)
    canvas:SetSize(1, 1)
    canvas:SetFrameLevel(frame:GetFrameLevel())
    mask = frame:CreateMaskTexture()
    mask:SetAllPoints(frame)
    frame:Hide()
end

-- Called by MapMarks.OnChange with every publish, first: shown while a set is applied, the option is on and the
-- player's map holds a set; otherwise hidden, with no per-frame script.
function M.OnChange(s)
    if not frame then
        if not (Marks.held > 0 and s.options.marks) then return end
        Create()
    end
    local lm, x, y
    if s.options.marks and Marks.held > 0 and Here() then lm, x, y = Env.Position() end
    if not lm then return Hide() end
    if not shown then
        shown, laidRev = true, false
        frame:Show()
        frame:SetScript("OnUpdate", OnUpdate)
    end
    Relay(lm, x, y)
end
