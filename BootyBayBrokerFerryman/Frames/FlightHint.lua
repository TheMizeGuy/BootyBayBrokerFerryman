local ADDON, ns = ...

local M = {}
ns.FlightHint = M

-- Solid blue lines this many physical pixels wide, so the hint is never taken for the window's own route lines.
M.PIXELS = 4
-- UI units of the window; on the canvas, counter-scaled by its zoom.
M.RING_SIZE = 36
-- A node the client lists without its id is matched to a stop by position, within this many yards.
M.MATCH = 30
-- The canvas flight map's node pins, whose tooltips gain a flight's time as the classic window's do.
M.PIN_TEMPLATE = "FlightMap_FlightPointPinTemplate"

M.ATLAS = { ring = "worldquest-tracker-ring" }
M.COLOR = { 0.36, 0.66, 1 }

local format = string.format
local hooked = false
local nodes = {}
-- The open window as last read: each slot's stop, whether its node is reachable, and the stop the player is at.
local stopOf, reach, here = {}, {}, false
local route, chain, MASTER = {}, {}, { [1] = true }
-- A canvas pin made before the mixin was hooked holds its OnMouseEnter as it was (oldEnter), as does its OnEnter.
local oldEnter = false
-- Per window: its frame, lines, the count in use, and the ring. classic draws over TaxiRouteMap, canvas over
-- the canvas flight map.
local classic = { lines = {}, used = 0 }
local canvas = { lines = {}, used = 0 }
local provider

-- UI units of the window's frame that make PIXELS physical pixels.
local function Thickness(w)
    local ph = GetPhysicalScreenSize and select(2, GetPhysicalScreenSize())
    return M.PIXELS * 768 / ((ph and ph > 0 and ph or 768) * (w.frame:GetEffectiveScale() or 1))
end

local function Line(w, k)
    local line = w.lines[k]
    if not line then
        line = w.frame:CreateLine(nil, "BACKGROUND")
        line:SetColorTexture(1, 1, 1, 1)
        line:SetVertexColor(M.COLOR[1], M.COLOR[2], M.COLOR[3], 1)
        w.lines[k] = line
    end
    line:SetThickness(w.thick)
    return line
end

local function Clear(w)
    if not w.frame then return end
    for k = 1, w.used do
        w.lines[k]:Hide()
    end
    w.used = 0
    if w.ring then
        w.ring:Hide()
    end
end

local function Frame(w, parent, name)
    w.frame = CreateFrame("Frame", name, parent)
    w.frame:SetAllPoints(parent)
    w.frame:SetScript("OnHide", function() Clear(w) end)
    w.ring = w.frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    w.ring:SetAtlas(M.ATLAS.ring)
    w.ring:Hide()
end

-- The flight leg to point at: the current leg, or the next one while the walk to its flight master is current.
local function FlightLeg()
    local snap = ns.Driver.Snapshot()
    local trip = snap and snap.trip
    if not trip or snap.state == "riding" or snap.state == "idle" then
        return nil
    end
    local leg = trip.legs[trip.at]
    if leg and leg.kind ~= "flight" then
        leg = trip.legs[trip.at + 1]
    end
    if leg and leg.kind == "flight" and leg.hops and #leg.hops >= 2 then
        return leg
    end
    return nil
end

-- The node of the open window that is this stop: by its client id, else by position.
local function NodeOf(n, stop)
    local Net = ns.Net
    local _, lm, sx, sy = Net.Stop(stop)
    for k = 1, n do
        local rec = nodes[k]
        if rec.node ~= 0 then
            if Net.StopOfNode(rec.node) == stop then
                return rec
            end
        elseif sx and rec.landmass == lm and (rec.x - sx) * (rec.x - sx) + (rec.y - sy) * (rec.y - sy) <= M.MATCH * M.MATCH then
            return rec
        end
    end
    return nil
end

local function Plain(v) return not issecretvalue(v) and v ~= nil end
local function Times() local o = ns.Driver.Snapshot().options return o.flightTimes == true and o.planner == true end

-- The open window, read once a draw when the hint or the times need it: its nodes, and each slot's stop.
local function Read(needed)
    local Net, n = ns.Net, needed and ns.Env.ReadTaxi(nodes) or 0
    here = false
    for k in pairs(stopOf) do stopOf[k], reach[k] = nil, nil end
    for k = 1, n do
        local rec = nodes[k]
        local node, slot = rec.node, rec.slot
        local stop = Plain(slot) and Plain(node) and (node ~= 0 and Net.StopOfNode(node)
            or node == 0 and rec.landmass and Net.Nearest(rec.landmass, rec.x, rec.y, MASTER, M.MATCH))
        if stop then
            stopOf[slot], reach[slot] = stop, rec.state == "reachable"
            here = rec.state == "current" and stop or here
        end
    end
    return n
end

-- The leg when the window read has n nodes and the player stands at the leg's first flight master, else nil.
local function Ready(leg, n)
    if not leg or n == 0 then
        return nil
    end
    local at = NodeOf(n, leg.hops[1])
    if not at or at.state ~= "current" then
        return nil
    end
    return leg
end

local function DrawClassic()
    if not TaxiFrame:IsShown() then return end
    local leg = FlightLeg()
    local n = Read(leg or Times())
    leg = Ready(leg, n)
    if not leg then
        Clear(classic)
        return
    end
    if not classic.frame then
        Frame(classic, TaxiRouteMap, "FerrymanFlightHint")
        -- Level with the route map itself, so the window's node buttons stay above the lines and the ring.
        classic.frame:SetFrameLevel(math.max(0, classic.frame:GetFrameLevel() - 1))
    end
    classic.thick = Thickness(classic)
    local used, last = 0, nil
    local hops = leg.hops
    for k = 1, #hops - 1 do
        local a, b = NodeOf(n, hops[k]), NodeOf(n, hops[k + 1])
        local ba = a and _G["TaxiButton" .. a.slot]
        local bb = b and _G["TaxiButton" .. b.slot]
        if ba and bb then
            used = used + 1
            local line = Line(classic, used)
            line:SetStartPoint("CENTER", ba)
            line:SetEndPoint("CENTER", bb)
            line:Show()
        end
        last = bb
    end
    for k = used + 1, classic.used do
        classic.lines[k]:Hide()
    end
    classic.used = used
    if last then
        classic.ring:ClearAllPoints()
        classic.ring:SetSize(M.RING_SIZE, M.RING_SIZE)
        classic.ring:SetPoint("CENTER", last, "CENTER", 0, 0)
        classic.ring:Show()
    else
        classic.ring:Hide()
    end
end

-- A stop's point on the canvas flight map: its node's position when the window lists it, else the data's.
local function CanvasPoint(n, stop, map, w, h)
    local _, lm, x, y = ns.Net.Stop(stop)
    local rec = NodeOf(n, stop)
    if rec and rec.landmass then
        lm, x, y = rec.landmass, rec.x, rec.y
    end
    if not lm then
        return nil
    end
    local mx, my = ns.Env.WorldToMap(map, lm, x, y)
    if not mx then
        return nil
    end
    return mx * w, -my * h
end

-- The ring (and, after a zoom, the lines) for the canvas's scale now: RING_SIZE units, PIXELS physical pixels.
local function Zoomed(zoom)
    if not canvas.frame then return end
    if zoom then
        canvas.thick = Thickness(canvas)
        for k = 1, canvas.used do
            canvas.lines[k]:SetThickness(canvas.thick)
        end
    end
    local s = FlightMapFrame:GetCanvasScale() or 1
    canvas.ring:SetSize(M.RING_SIZE / s, M.RING_SIZE / s)
end

local function DrawCanvas()
    if not FlightMapFrame or not FlightMapFrame:IsShown() then return end
    local leg = FlightLeg()
    local n = Read(leg or Times())
    leg = Ready(leg, n)
    if not leg then
        Clear(canvas)
        return
    end
    local map = FlightMapFrame:GetMapID()
    local surface = FlightMapFrame:GetCanvas()
    if not canvas.frame then
        Frame(canvas, surface, nil)
    end
    local w, h = surface:GetWidth(), surface:GetHeight()
    canvas.thick = Thickness(canvas)
    local hops = leg.hops
    local used = 0
    local px, py = CanvasPoint(n, hops[1], map, w, h)
    for k = 2, #hops do
        local qx, qy = CanvasPoint(n, hops[k], map, w, h)
        if px and qx then
            used = used + 1
            local line = Line(canvas, used)
            line:SetStartPoint("TOPLEFT", canvas.frame, px, py)
            line:SetEndPoint("TOPLEFT", canvas.frame, qx, qy)
            line:Show()
        end
        px, py = qx, qy
    end
    for k = used + 1, canvas.used do
        canvas.lines[k]:Hide()
    end
    canvas.used = used
    -- px, py is the destination's point.
    if px then
        canvas.ring:ClearAllPoints()
        canvas.ring:SetPoint("CENTER", canvas.frame, "TOPLEFT", px, py)
        canvas.ring:Show()
    else
        canvas.ring:Hide()
    end
    Zoomed(false)
end

-- The seconds the planner gives the flight from the master the player stands at to this slot's node along the
-- hops the window shows, the boarding counted once; nil where any part of it is unknown or hidden (6.6).
function M.Seconds(slot)
    local to = here and Plain(slot) and reach[slot] and stopOf[slot]
    if not to or to == here then return nil end
    local h = ns.Env.TaxiHops(slot, route)
    if h < 1 then return nil end
    for i = 1, h + 1 do
        local s = route[i]
        chain[i] = Plain(s) and stopOf[s]
        if not chain[i] then return nil end
    end
    if chain[1] ~= here or chain[h + 1] ~= to then return nil end
    local know = ns.Ledger.Knowledge()
    local sec = know and ns.Net.ChainPrice(chain, h + 1, know.vFly, know.hopFlight)
    return sec and know.boardFlight + sec or nil
end

-- One line on the tooltip the client has just built for a node, shown again so that it fits: only while that tooltip
-- is shown and is the node's, so another addon's hook that took or hid it before this one gets none; hidden, none.
local function Tip(slot, owner)
    local own, shown = GameTooltip:GetOwner(), GameTooltip:IsShown()
    if not (Plain(own) and Plain(shown)) or own ~= owner or not shown then return end
    local sec = M.Seconds(slot)
    if sec then
        GameTooltip:AddLine(format(ns.T.TIP_FLIGHT, ns.T.Time(sec)))
        GameTooltip:Show()
    end
end

local function ClassicEnter(button)
    if Times() and TaxiFrame:IsShown() then
        Tip(button:GetID(), button)
    end
end

local function PinEnter(pin)
    local data = Times() and FlightMapFrame:IsShown() and pin.taxiNodeData
    if type(data) == "table" then
        Tip(data.slotIndex, pin)
    end
end

local function Sweep()
    if not oldEnter then return end
    for pin in FlightMapFrame:EnumeratePinsByTemplate(M.PIN_TEMPLATE) do
        -- its own function for the map's gamepad navigation, which calls it, and its OnEnter for the mouse
        if pin.OnMouseEnter == oldEnter then
            hooksecurefunc(pin, "OnMouseEnter", PinEnter)
            pin:HookScript("OnEnter", PinEnter)
        end
    end
end

local function AddCanvas()
    provider = CreateFromMixins(MapCanvasDataProviderMixin)
    function provider:RefreshAllData()
        DrawCanvas()
        Sweep()
    end
    -- Called after every provider's refresh: the pins of this showing exist.
    function provider:OnShow() Sweep() end
    -- The window sets its map only in OnShow, whose refresh that follows draws.
    function provider:OnMapChanged() end
    -- The window draws before its own zoom (auto-zoom or reset) and zooms on a click.
    function provider:OnCanvasScaleChanged()
        Zoomed(true)
    end
    function provider:RemoveAllData()
        Clear(canvas)
    end
    FlightMapFrame:AddDataProvider(provider)
    -- Pins made from the mixin from now on carry the hook; those made before it get theirs from Sweep.
    local mixin = FlightMap_FlightPointPinMixin
    if type(mixin) == "table" and type(mixin.OnMouseEnter) == "function" then
        oldEnter = mixin.OnMouseEnter
        hooksecurefunc(mixin, "OnMouseEnter", PinEnter)
        Sweep()
    end
end

local function Hook()
    hooked = true
    TaxiFrame:HookScript("OnShow", function() DrawClassic() end)
    if type(TaxiNodeOnButtonEnter) == "function" then
        hooksecurefunc("TaxiNodeOnButtonEnter", ClassicEnter)
    end
    EventUtil.ContinueOnAddOnLoaded("Blizzard_FlightMap", AddCanvas)
end

function M.OnChange(snap, what)
    if not hooked then
        Hook()
    end
    if what == "tick" or what == "notice" then return end
    DrawClassic()
    if provider then
        DrawCanvas()
    end
end

ns.Driver.Subscribe(M.OnChange)
