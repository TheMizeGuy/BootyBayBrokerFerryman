local ADDON, ns = ...

local M = {}
ns.MapTrail = M

M.MAX_LINES = 400
M.SIDE_LINES = 64       -- the side trail's dots, after the trip's lines
-- Lines are solid colour: the flight-map line art's visible core is near black, so no tint would show on it.
M.PIXELS = 3
M.SETTLE = 0.1
-- Work a zoom may do in one frame: the scale read and the script switch leave ten of the dozen calls, nine while the
-- marks' pins are shown, whose scale the zoom sets.
M.FRAME_CALLS = 10
M.STOP_SIZE = 14
M.DEST_SIZE = 30
M.MARGIN = 0.05
-- A dot of the side trail: a line DOT physical pixels long (and PIXELS thick) every DOT_PITCH, from its end.
M.DOT = 3
M.DOT_PITCH = 6

M.ATLAS = {
    dest = "Waypoint-MapPin-Tracked", stop = "ui-taxi-icon-nub",
    flight = "flightmaster", boat = "flightmasterferry", zeppelin = "flightmasterferry",
}

local GOLD, BLUE, TEAL, VIOLET = { 1, 0.9, 0.35 }, { 0.36, 0.66, 1 }, { 0.2, 0.84, 0.76 }, { 0.78, 0.7, 1 }
M.COLOR = {
    walk = GOLD, flight = BLUE, boat = TEAL, zeppelin = TEAL,
    tram = VIOLET, lift = VIOLET, portal = VIOLET, hearth = VIOLET, spell = VIOLET,
    side = { 0.45, 0.82, 1 },       -- a lighter blue than a flight's, and dotted
}

local format, sqrt = string.format, math.sqrt

local frame, provider, pinLevel
local lines, lineKind, lineThick, lineOn, nLines, used = {}, {}, {}, {}, 0, 0
local holders, pins, pinTex, nPins, usedPins = {}, {}, {}, 0, 0
local destHolder, destPin
local seenTrail, seenLegs = {}, 0
local drawnTrip, drawnAt, drawnT, dirty, wanted = false, 0, 0, false, false
-- The lines the trip took, and the rev of the side trail and of the loop drawn (false: none).
local tripLines, drawnRev, drawnLoop = 0, false, false
local curMap, cw, ch = 0, 0, 0
local scale, thick, pinsDone, linesDone, dotsDone, settle, running = 1, 1, 0, 0, 0, 0, false

-- Line thickness in canvas units that shows PIXELS physical pixels at the canvas's current effective scale.
local function Thickness()
    local ph = GetPhysicalScreenSize and select(2, GetPhysicalScreenSize())
    return M.PIXELS * 768 / ((ph and ph > 0 and ph or 768) * (frame:GetEffectiveScale() or 1))
end

-- A line from (x1, y1) to (x2, y2) in canvas units, unless cap lines are drawn; a dot of the side trail sits on
-- the layer's sublevel 1, over the trip's lines.
local function Segment(x1, y1, x2, y2, kind, cap)
    local lo, hiX, hiY = -M.MARGIN, (1 + M.MARGIN) * cw, (1 + M.MARGIN) * ch
    if (x1 < lo * cw and x2 < lo * cw) or (x1 > hiX and x2 > hiX)
        or (y1 < lo * ch and y2 < lo * ch) or (y1 > hiY and y2 > hiY) then
        return
    end
    if used >= cap then return end
    used = used + 1
    local k = used
    if k > nLines then
        nLines = k
        local line = frame:CreateLine(nil, "ARTWORK")
        line:SetColorTexture(1, 1, 1, 1)
        lines[k], lineKind[k], lineThick[k], lineOn[k] = line, false, 0, true
    end
    local line = lines[k]
    line:SetStartPoint("TOPLEFT", frame, x1, -y1)
    line:SetEndPoint("TOPLEFT", frame, x2, -y2)
    if lineKind[k] ~= kind then
        local c = M.COLOR[kind] or VIOLET
        line:SetVertexColor(c[1], c[2], c[3], 1)
        if (kind == "side") ~= (lineKind[k] == "side") then line:SetDrawLayer("ARTWORK", kind == "side" and 1 or 0) end
        lineKind[k] = kind
    end
    if lineThick[k] ~= thick then
        line:SetThickness(thick)
        lineThick[k] = thick
    end
    if not lineOn[k] then
        line:Show()
        lineOn[k] = true
    end
end

-- Every polyline thinned by the same stride, each keeping its last point, so the whole fits MAX_LINES.
local function Emit()
    local P = ns.MapPath
    local stride, first, last, kind, px, py = P.Stride(M.MAX_LINES), P.first, P.last, P.kind, P.x, P.y
    for p = 1, P.n do
        local i, stop = first[p], last[p]
        while i < stop do
            local j = i + stride
            if j > stop then j = stop end
            Segment(px[i], py[i], px[j], py[j], kind[p], M.MAX_LINES)
            i = j
        end
    end
end

-- The side trail's dots after the trip's lines: each a line from the point d canvas units before a side
-- polyline's end to the point len further back, one every pitch from the end; SIDE_LINES at most, so a long way
-- loses its near end.
local function Dots()
    local P = ns.MapPath
    local px, py, u = P.x, P.y, thick / M.PIXELS
    local len, pitch, cap = M.DOT * u, M.DOT_PITCH * u, tripLines + M.SIDE_LINES
    used = tripLines
    for p = P.n + 1, P.m do
        -- point j lies e units before the end; the dot's start (x1, y1) once its d is passed, then its end
        local j, e, d, x1, y1 = P.last[p], 0, 0, false, 0
        while j > P.first[p] and used < cap do
            local dx, dy = px[j - 1] - px[j], py[j - 1] - py[j]
            local l = sqrt(dx * dx + dy * dy)
            if d > e + l then
                e, j = e + l, j - 1
            else
                local t = l > 0 and (d - e) / l or 0
                local x, y = px[j] + dx * t, py[j] + dy * t
                if x1 then
                    Segment(x1, y1, x, y, "side", cap)
                    x1, d = false, d - len + pitch
                else
                    x1, y1, d = x, y, d + len
                end
            end
        end
    end
end

local function PinEnter(pin)
    local snap = ns.Driver.Snapshot()
    local trip = snap and snap.trip
    if not trip then return end
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    local i = pin.leg
    if i == 0 then
        GameTooltip:AddLine(trip.dest and trip.dest.title or "")
    else
        local leg, nextLeg = trip.legs[i], trip.legs[i + 1]
        GameTooltip:AddLine(leg and leg.toName or "")
        if nextLeg then
            GameTooltip:AddLine(format(ns.T.TIP_PIN_NEXT, ns.T.Step(nextLeg, i + 1 == trip.n, trip)))
        end
    end
    GameTooltip:Show()
end

-- Counter-scales a pin to the map's scale unless it already is; 1 when it called the client.
local function Scale(pin)
    if pin.s == scale then return 0 end
    pin:SetScale(1 / scale)
    pin.s = scale
    return 1
end

-- A pin is a mouse-free holder at its point and a child centred on it, so a zoom only rescales the child.
local function NewPin(size)
    local holder = CreateFrame("Frame", nil, frame)
    holder:SetSize(1, 1)
    local pin = CreateFrame("Frame", nil, holder)
    pin:SetSize(size, size)
    pin:SetFrameLevel(pinLevel)
    pin:SetPoint("CENTER", holder, "CENTER", 0, 0)
    pin:SetMouseClickEnabled(false)
    pin:SetMouseMotionEnabled(true)
    pin.owningMap = WorldMapFrame
    pin.leg = 0
    pin:SetScript("OnEnter", PinEnter)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    Scale(pin)
    local tex = pin:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints(pin)
    return holder, pin, tex
end

local function Place(holder, place)
    local cx, cy = ns.MapPath.ToCanvas(place.landmass, place.x, place.y)
    if not cx then return holder:Hide() end
    holder:SetPoint("CENTER", frame, "TOPLEFT", cx, -cy)
    holder:Show()
end

-- One stop pin where a leg ends and another begins (two at one point become one), and the destination pin.
local function Pins(trip)
    local lastX, lastY
    for i = trip.at, trip.n - 1 do
        local place = trip.legs[i].to
        if place.x ~= lastX or place.y ~= lastY then
            usedPins = usedPins + 1
            local k = usedPins
            if k > nPins then
                nPins = k
                holders[k], pins[k], pinTex[k] = NewPin(M.STOP_SIZE)
            end
            Scale(pins[k])
            Place(holders[k], place)
            lastX, lastY = place.x, place.y
        end
        -- At a shared point the later leg wins: the walk of no yards between two rides is not shown.
        pins[usedPins].leg = i
        pinTex[usedPins]:SetAtlas(M.ATLAS[trip.legs[i + 1].kind] or M.ATLAS.stop)
    end
    if not destHolder then
        local tex
        destHolder, destPin, tex = NewPin(M.DEST_SIZE)
        tex:SetAtlas(M.ATLAS.dest)
    end
    Scale(destPin)
    local d = trip.dest
    -- RestedXP marks its own target on the map: a trip that follows it puts no pin over that.
    if d and (d.source == "guide" or d.kind == "corpse") then return destHolder:Hide() end
    Place(destHolder, (d and d.landmass) and d or trip.legs[trip.n].to)
end

local function HideLines()
    for k = used + 1, nLines do
        if lineOn[k] then
            lines[k]:Hide()
            lineOn[k] = false
        end
    end
end

local function HideFrom()
    HideLines()
    for k = usedPins + 1, nPins do holders[k]:Hide() end
end

-- What was drawn: the trip (false: none) and its trails, the side trail's and the loop's rev. Nothing of an ended
-- trip is kept.
local function Remember(trip, rev, loop)
    drawnRev, drawnLoop = rev, loop
    if not trip then
        drawnTrip, seenLegs = false, 0
        for i in pairs(seenTrail) do seenTrail[i] = nil end
        return
    end
    for i = trip.n + 1, seenLegs do seenTrail[i] = nil end
    drawnTrip, drawnAt, seenLegs = trip, trip.at, trip.n
    for i = 1, trip.n do seenTrail[i] = trip.legs[i].trail end
end

-- Nothing drawn, so nothing to settle.
local function Clear()
    used, usedPins = 0, 0
    HideFrom()
    ns.MapLoop.Lay(frame, false)
    if destHolder then destHolder:Hide() end
    Remember(false, false, false)
    if running then
        frame:SetScript("OnUpdate", nil)
        running = false
    end
end

-- The rev of the snapshot's side trail when it has a trail to draw, else false.
local function SideRev(snap)
    local side = snap and snap.side
    return side and side.walk.trail and side.rev or false
end
local function LoopRev(snap) return snap and snap.loop and snap.loop.rev or false end

-- A trail traced after the trip was adopted arrives without a publish of its own.
local function TrailsChanged(trip)
    if not trip then return drawnTrip ~= false end
    if trip ~= drawnTrip or trip.n ~= seenLegs then return true end
    for i = trip.at, trip.n do
        if trip.legs[i].trail ~= seenTrail[i] then return true end
    end
    return false
end

-- The drawing is of another map, canvas size or thickness, or of a change while the map was hidden.
local function Moved()
    local canvas = WorldMapFrame:GetCanvas()
    return dirty or curMap ~= WorldMapFrame:GetMapID() or cw ~= canvas:GetWidth() or ch ~= canvas:GetHeight()
        or thick ~= Thickness()
end

local function Draw()
    local snap = ns.Driver.Snapshot()
    local trip, rev, loop = snap and snap.trip, SideRev(snap), LoopRev(snap)
    if not wanted or not (trip or rev or loop) then return Clear() end
    if not WorldMapFrame:IsShown() then
        dirty = true
        return Remember(trip, rev, loop)
    end
    local again = loop ~= drawnLoop or Moved()      -- the loop is laid again only for this
    dirty = false
    curMap = WorldMapFrame:GetMapID()
    local canvas = WorldMapFrame:GetCanvas()
    cw, ch = canvas:GetWidth(), canvas:GetHeight()
    thick = Thickness()
    used, usedPins = 0, 0
    ns.MapPath.Build(trip, curMap, cw, ch, rev and snap.side)
    Emit()
    tripLines = used
    Dots()
    if again then ns.MapLoop.Lay(frame, snap.loop, thick, cw, ch) end
    -- A side trail or a loop alone has no pin.
    if trip then Pins(trip) elseif destHolder then destHolder:Hide() end
    HideFrom()
    Remember(trip, rev, loop)
    drawnT = ns.Env.Now()
end

-- The map's callbacks: a map change calls the size callback, then the map change, then on show the refresh;
-- only the first that finds the drawing out of date draws (the size callback leaves a new map to the next).
local function Refresh()
    local snap = ns.Driver.Snapshot()
    local trip, rev, loop = snap and snap.trip, SideRev(snap), LoopRev(snap)
    if not (trip or rev or loop) or trip and trip.at ~= drawnAt or TrailsChanged(trip) or rev ~= drawnRev
        or loop ~= drawnLoop or Moved() then
        Draw()
    end
end

-- A new side trail or loop beside the trip drawn, on the map, canvas and thickness drawn: only what changed is laid
-- again.
local function Relay(snap, rev, loop)
    if not WorldMapFrame:IsShown() or Moved() then return Draw() end
    if rev ~= drawnRev then
        ns.MapPath.Side(rev and snap.side)
        Dots()
        HideLines()
    end
    if loop ~= drawnLoop then ns.MapLoop.Lay(frame, snap.loop, thick, cw, ch) end
    drawnRev, drawnLoop = rev, loop
end

local function Resized()
    if curMap == WorldMapFrame:GetMapID() then Refresh() end
end

-- Runs only while a zoom settles: the pins counter-scaled (the destination pin first), then, once the scale has held
-- for SETTLE seconds, every line's thickness and then every loop dot's, each on a cursor of its own (a draw between two
-- frames may change the pool's count); never more than FRAME_CALLS calls in one frame, one fewer with marks shown.
local function Settle(_, elapsed)
    local marks = ns.MapMarks
    local budget = M.FRAME_CALLS - (marks and marks.pins > 0 and 1 or 0)
    while pinsDone <= usedPins and budget > 0 do
        local pin = pinsDone == 0 and destPin or pins[pinsDone]
        pinsDone = pinsDone + 1
        if pin then budget = budget - Scale(pin) end
    end
    settle = settle + elapsed
    if settle < M.SETTLE or pinsDone <= usedPins then return end
    if linesDone == 0 then
        thick = Thickness()
        linesDone, dotsDone = 1, 1
    end
    while linesDone <= used and budget > 0 do
        if lineThick[linesDone] ~= thick then
            lines[linesDone]:SetThickness(thick)
            lineThick[linesDone] = thick
            budget = budget - 1
        end
        linesDone = linesDone + 1
    end
    local L = ns.MapLoop
    while linesDone > used and dotsDone <= L.n and budget > 0 do
        budget = budget - L.Thick(dotsDone, thick)
        dotsDone = dotsDone + 1
    end
    if linesDone > used and dotsDone > L.n and budget > 0 then
        frame:SetScript("OnUpdate", nil)
        running = false
    end
end

local function OnScale(self)
    local s = self:GetMap():GetCanvasScale()
    if not s or s <= 0 or s == scale then return end
    scale = s
    -- With nothing drawn there is nothing to settle: the next draw counter-scales its pins and sets its thickness.
    if not wanted then return end
    local marks = ns.MapMarks
    if marks and marks.pins > 0 then marks.Scale(s) end
    -- The map reopened on its last map drew at the zoom it closed with, then reset the zoom: draw again.
    if drawnT == ns.Env.Now() then return Draw() end
    pinsDone, linesDone, settle = 0, 0, 0
    if not running then
        running = true
        frame:SetScript("OnUpdate", Settle)
    end
end

local function Create()
    local canvas = WorldMapFrame:GetCanvas()
    frame = CreateFrame("Frame", "FerrymanMapTrail", canvas)
    frame:SetAllPoints(canvas)
    -- Under the game's own map pin, whose hover and clicks stay the game's: the pins one level under it, the lines two.
    pinLevel = WorldMapFrame:GetPinFrameLevelsManager():GetValidFrameLevel("PIN_FRAME_LEVEL_WAYPOINT_LOCATION") - 1
    frame:SetFrameLevel(pinLevel - 1)
    provider = CreateFromMixins(MapCanvasDataProviderMixin)
    provider.RefreshAllData, provider.OnMapChanged, provider.OnCanvasSizeChanged = Refresh, Refresh, Resized
    provider.RemoveAllData = Clear
    provider.OnCanvasScaleChanged = OnScale
    scale = WorldMapFrame:GetCanvasScale() or 1
    WorldMapFrame:AddDataProvider(provider)
end

function M.OnChange(snap, what)
    -- The minimap's loop, side trail and another addon's marks first; a fault there never keeps the trip off the map.
    local ok, err = pcall(ns.MiniLoop.OnChange, snap, what)
    if not ok then geterrorhandler()(err) end
    ok, err = pcall(ns.MiniSide.OnChange, snap, what)
    if not ok then geterrorhandler()(err) end
    if ns.MapMarks then
        ok, err = pcall(ns.MapMarks.OnChange, snap, what)
        if not ok then geterrorhandler()(err) end
    end
    local rev, loop = SideRev(snap), LoopRev(snap)
    -- A change of the side trail or the loop marked with a notice is published as the notice: drawn as a tick.
    if what == "notice" then
        if rev == drawnRev and loop == drawnLoop then return end
        what = "tick"
    end
    local want = (snap.trip or rev or loop) and snap.options and snap.options.mapTrail and true or false
    -- A side trail and a loop come and go on ticks: a tick that changes what is wanted is handled as any publish.
    if what == "tick" and want == wanted then
        if not (frame and want) then return end
        if TrailsChanged(snap.trip) then return Draw() end
        if rev ~= drawnRev or loop ~= drawnLoop then return Relay(snap, rev, loop) end
        return
    end
    if want and not frame then Create() end
    if not frame then return end
    if what == "option" and want == wanted
        and (not want or snap.trip == drawnTrip and rev == drawnRev and loop == drawnLoop) then
        if want and not dirty and WorldMapFrame:IsShown() and Thickness() ~= thick then Draw() end
        return
    end
    wanted, M.wanted = want, want
    if want then
        frame:Show()
        Draw()
    else
        Clear()
        frame:Hide()
    end
end

ns.Driver.Subscribe(M.OnChange)
