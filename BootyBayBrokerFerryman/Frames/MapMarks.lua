local ADDON, ns = ...

-- Marks (INTERFACES 5.6, 6.13, decision 136) on the world map: a small treasure pin at each mark of the map shown,
-- under the client's own pins and the trip's and the side trail's drawings, taking no click; hovering one names its
-- set. A pin hangs by its centre from a holder on the canvas and lives in one frame counter-scaled as a whole, so a
-- zoom costs one call, which MapTrail's provider makes while MapTrail draws. It does not subscribe: MapTrail hands it
-- every publish, and it hands each to MiniMarks, first.
local M = {}
ns.MapMarks = M

M.SIZE = 13             -- UI units across a pin
M.PINS = 400            -- pins at most on one map
M.ATLAS = { mark = "VignetteLoot" }

local min, Marks = math.min, ns.Marks
M.pins = 0              -- pins shown: MapTrail sets their scale while it draws (6.4)

local frame, scaled
local holders, pins, hx, hy, made, used = {}, {}, {}, {}, 0, 0
-- wanted: sets are applied and the option is on; heard: the rev of Marks the last publish acted on.
local wanted, heard, drawnRev, dirty, curMap, cw, ch, scale = false, false, false, false, 0, 0, 0, 0

local function Enter(pin)
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    GameTooltip:AddLine(pin.label)
    GameTooltip:Show()
end
local function Leave() GameTooltip:Hide() end

-- A holder, a 1 x 1 texture of the canvas's frame where the mark is, and a pin of the scaled frame centred on it,
-- its mouse set once: clicks pass to the map, the cursor shows its tooltip.
local function New(k)
    local h = frame:CreateTexture(nil, "BACKGROUND")
    h:SetSize(1, 1)
    local pin = CreateFrame("Frame", nil, scaled)
    pin:SetSize(M.SIZE, M.SIZE)
    pin:SetPoint("CENTER", h, "CENTER", 0, 0)
    pin:SetMouseClickEnabled(false)
    pin:SetMouseMotionEnabled(true)
    pin.owningMap, pin.label = WorldMapFrame, ""
    pin:SetScript("OnEnter", Enter)
    pin:SetScript("OnLeave", Leave)
    local tex = pin:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(pin)
    tex:SetAtlas(M.ATLAS.mark)
    pin:Hide()
    holders[k], pins[k], hx[k], hy[k], made = h, pin, false, false, k
end

-- Pins 1 to k shown, the rest hidden.
local function Lay(k)
    for i = used + 1, k do pins[i]:Show() end
    for i = k + 1, used do pins[i]:Hide() end
    used, M.pins = k, k
end

-- The scaled frame at the canvas scale s; 1 when it called the client.
function M.Scale(s)
    if not frame or not s or s <= 0 or s == scale then return 0 end
    scale = s
    scaled:SetScale(1 / s)
    return 1
end

-- Every mark of the sets on the map shown, PINS at most; a holder whose mark has not moved is not set again. A map
-- with no set computes nothing.
local function Draw()
    curMap, drawnRev, dirty = WorldMapFrame:GetMapID(), Marks.rev, false
    local list = Marks.OnMap(curMap)
    if not list then return Lay(0) end
    local canvas = WorldMapFrame:GetCanvas()
    cw, ch = canvas:GetWidth(), canvas:GetHeight()
    M.Scale(WorldMapFrame:GetCanvasScale())
    local k = 0
    for i = 1, list.n do
        local set = list[i]
        local x, y, top, left, label = set.x, set.y, set.top, set.left, set.label
        local sx, sy = cw / (left - set.right), ch / (top - set.bottom)
        for j = 1, min(set.n, M.PINS - k) do
            k = k + 1
            if k > made then New(k) end
            local cx, cy = (left - y[j]) * sx, (x[j] - top) * sy
            if cx ~= hx[k] or cy ~= hy[k] then
                holders[k]:SetPoint("CENTER", frame, "TOPLEFT", cx, cy)
                hx[k], hy[k] = cx, cy
            end
            pins[k].label = label
        end
    end
    Lay(k)
end

local function Clear()
    Lay(0)
    drawnRev, curMap = false, 0
end

-- The drawing is of another map or canvas size, or of a change while the map was hidden.
local function Moved()
    local canvas = WorldMapFrame:GetCanvas()
    return dirty or curMap ~= WorldMapFrame:GetMapID() or cw ~= canvas:GetWidth() or ch ~= canvas:GetHeight()
end
local function Refresh()
    if wanted and (drawnRev ~= Marks.rev or Moved()) then Draw() end
end
local function Resized()
    if wanted and curMap == WorldMapFrame:GetMapID() then Refresh() end
end
-- A zoom, the reset of a map reopened included: the scaled frame takes the new scale in that frame, from MapTrail's
-- provider while MapTrail draws, whose calls a frame count it.
local function OnScale(self)
    if not wanted or used == 0 then return end
    local trail = ns.MapTrail
    if trail and trail.wanted then return end
    M.Scale(self:GetMap():GetCanvasScale())
end

local function Create()
    local canvas = WorldMapFrame:GetCanvas()
    frame = CreateFrame("Frame", "FerrymanMapMarks", canvas)
    frame:SetAllPoints(canvas)
    -- A pin at the lowest level of a pin of the client's (Blizzard_WorldMap's order), so every one of them draws over a
    -- mark: a frame is made one level over its parent, so the scaled frame sits one under it.
    local level = WorldMapFrame:GetPinFrameLevelsManager():GetValidFrameLevel("PIN_FRAME_LEVEL_DIG_SITE")
    frame:SetFrameLevel(level)
    scaled = CreateFrame("Frame", nil, frame)
    scaled:SetFrameLevel(level - 1)
    scaled:SetAllPoints(frame)
    local provider = CreateFromMixins(MapCanvasDataProviderMixin)
    provider.RefreshAllData, provider.OnMapChanged, provider.OnCanvasSizeChanged = Refresh, Refresh, Resized
    provider.RemoveAllData, provider.OnCanvasScaleChanged = Clear, OnScale
    WorldMapFrame:AddDataProvider(provider)
end

-- Called by MapTrail.OnChange with every publish.
function M.OnChange(snap, what)
    -- The minimap's marks first; a fault there never keeps the world map's from drawing.
    local ok, err = pcall(ns.MiniMarks.OnChange, snap, what)
    if not ok then geterrorhandler()(err) end
    local want = Marks.held > 0 and snap.options.marks and true or false
    if want == wanted and (Marks.rev == heard or not want) then return end
    heard = Marks.rev
    if want and not frame then Create() end
    if not frame then return end
    wanted = want
    if not want then
        Clear()
        return frame:Hide()
    end
    frame:Show()
    if WorldMapFrame:IsShown() then Draw() else dirty = true end
end
