local ADDON, ns = ...

-- The readout: the arrow and its two lines of text, moved as one.
local M = {}
ns.Pointer = M

-- Ferryman's own art (tools/art/arrow.py): the turned layers in rungs of 32, 64, 128 and 256 texels.
M.FILE = { body = "ArrowBody", gloss = "ArrowGloss", glow = "ArrowGlow64" }
M.ART = "Interface\\AddOns\\" .. ADDON .. "\\Art\\"
M.FONT = { main = "GameFontHighlightMedium", sub = "GameFontNormal" }
M.SOUND = { arrive = SOUNDKIT.UI_MAP_WAYPOINT_SUPER_TRACK_OFF }
M.SIZE = 56      -- the arrow's box, UI units
M.SPAN = 1.3     -- the glow, in boxes
M.Y = 110        -- default: centred, this far above the screen's centre, under the client's error and zone texts
M.GAP = 4        -- arrow to text
M.LEAD = 2       -- between the two lines
M.BELOW = 32     -- the gaps and the two fonts' heights under the box, kept on screen with it
M.SIDE = 110     -- beside the box: half a line of about 260 units, as a ride's sentence runs
M.EASE = 0.08    -- seconds: how fast the arrow swings to a new bend (the player's own turning is never eased)
M.GLOW = 0.45
M.BLUE = { 0.45, 0.82, 1 }     -- aimed at another addon's point: the side trail's blue (MapTrail.COLOR.side)
-- By how far the arrow turns from straight ahead, every 15 degrees: tint and glow. Gold and lit on course,
-- cooling to a dim steel blue behind, so the cue is in brightness and the glow as well as in hue.
M.HEADING = {
    { 1, 0.80, 0.24, 1 }, { 1, 0.80, 0.24, 1 }, { 0.99, 0.80, 0.30, 0.73 }, { 0.97, 0.80, 0.39, 0.33 },
    { 0.93, 0.81, 0.53, 0.15 }, { 0.87, 0.81, 0.68, 0.08 }, { 0.82, 0.82, 0.84, 0 }, { 0.78, 0.80, 0.86, 0 },
    { 0.74, 0.78, 0.88, 0 }, { 0.70, 0.76, 0.90, 0 }, { 0.66, 0.74, 0.91, 0 }, { 0.62, 0.72, 0.93, 0 },
    { 0.58, 0.70, 0.95, 0 },
}

local floor, sqrt, atan2, exp, abs, max = math.floor, math.sqrt, math.atan2, math.exp, math.abs, math.max
local format = string.format
local PI, TAU, STEP = math.pi, 2 * math.pi, math.pi / 12
local T, Env, Ledger = ns.T, ns.Env, ns.Ledger

local frame, body, gloss, glow, line1, line2, handle
local snap                       -- the Driver's one snapshot table
local leading, dragging = false, false
local aside = false              -- the snapshot's arrow while the readout is its own: another addon's point, no trip
local riding = { kind = "flight", toName = "" }   -- the flight or deck under way, for T.Riding
local shown, yardKey = {}, nil   -- [font string] = the text it shows; the half-yard line 1 was made for
local bearing, fresh, tone = 0, true, nil  -- the eased bearing; snap it at the next look; the heading row shown
local art = {}                   -- [texture] = the file it shows

local function Put(fs, text)
    if shown[fs] ~= text then
        shown[fs] = text
        fs:SetText(text)
    end
end

local function Tone(i)
    tone = i
    local c = M.HEADING[i + 1]
    local tint = aside and M.BLUE or c
    body:SetVertexColor(tint[1], tint[2], tint[3])
    glow:SetVertexColor(tint[1], tint[2], tint[3])
    glow:SetAlpha(c[4] * M.GLOW)
end

-- The handle covers everything drawn, the arrow and both lines, and no more; fitted on a publish, never a tick.
local function Grip()
    local w = max(line1:GetStringWidth(), line2:GetStringWidth())
    if leading then
        w = max(w, frame:GetWidth())
    end
    handle:ClearAllPoints()
    handle:SetPoint("TOP", leading and frame or line1, "TOP")
    handle:SetPoint("BOTTOM", shown[line2] ~= "" and line2 or line1, "BOTTOM")
    handle:SetWidth(w)
end

function M.Rest()
    if leading then
        leading = false
        frame:SetScript("OnUpdate", nil)
        body:Hide()
        gloss:Hide()
        glow:Hide()
    end
end

-- The only script that runs per frame, and only while the arrow is shown. elapsed is nil from a publish.
local function Lead(_, elapsed)
    local trip, leg, a = snap.trip, snap.leg, aside
    local m, x, y = Env.Position()
    local facing = Env.Facing()
    local tx, ty, ahead
    if a then
        -- Another addon's point: straight at it. Where it cannot point, the readout goes until a publish finds it can.
        if not (x and facing and m == a.landmass) then
            M.Rest()
            return frame:Hide()
        end
        tx, ty, ahead = a.x, a.y, 0
    elseif not (trip and x and facing and m == leg.from.landmass) then
        M.Rest()
        if elapsed then
            Grip()
        end
        return
    else
        -- Along the trail to its next bend; a walk not traced yet, straight to its end, as its yards are measured.
        tx, ty, ahead = leg.to.x, leg.to.y, 0
        if leg.trail then
            tx, ty, ahead = trip.bendX, trip.bendY, trip.ahead
        end
    end
    local dx, dy = tx - x, ty - y
    local want = atan2(dy, dx)
    local off = (want - bearing + PI) % TAU - PI
    -- Within a thousandth of a radian the swing is over.
    if fresh or off * off < 1e-6 then
        bearing, fresh = want, false
    elseif elapsed then
        bearing = bearing + off * (1 - exp(-elapsed / M.EASE))
    end
    local turn = (bearing - facing + PI) % TAU - PI
    body:SetRotation(turn)
    gloss:SetRotation(turn)
    local i = floor(abs(turn) / STEP + 0.5)
    if i ~= tone then
        Tone(i)
    end
    local yards = sqrt(dx * dx + dy * dy) + ahead
    -- T.Yards changes only at half yards, so the text is made again only when the half yard changes.
    local key = floor(yards * 2)
    if key ~= yardKey then
        yardKey = key
        Put(line1, T.Yards(yards))
    end
end

local function Unit()
    local _, height = GetPhysicalScreenSize()
    return 768 / (height * frame:GetEffectiveScale())
end

-- The rung nearest the drawn size: never shrunk or stretched by more than the square root of two.
local function Art(tex, name, px)
    local file = M.ART .. name .. (px < 45.25 and 32 or px < 90.5 and 64 or px < 181 and 128 or 256) .. ".tga"
    if art[tex] ~= file then
        art[tex] = file
        tex:SetTexture(file)
    end
end

-- Whole physical pixels: the box and the glow an even number of them, so their edges sit on the grid.
local function Place(options)
    if dragging then
        return
    end
    local scale = options.arrowScale
    frame:SetScale(scale)
    local unit = Unit()
    local px = floor(M.SIZE / (2 * unit) + 0.5) * 2
    local big = floor(M.SIZE * M.SPAN / (2 * unit) + 0.5) * 2
    frame:SetSize(px * unit, px * unit)
    glow:SetSize(big * unit, big * unit)
    Art(body, M.FILE.body, px)
    Art(gloss, M.FILE.gloss, px)
    local x, y = Ledger.FramePos("pointer")
    if not x then
        x, y = 0, M.Y
    end
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", floor(x / scale / unit + 0.5) * unit, floor(y / scale / unit + 0.5) * unit)
    line1:SetPoint("TOP", frame, "BOTTOM", 0, -floor(M.GAP / unit + 0.5) * unit)
    line2:SetPoint("TOP", line1, "BOTTOM", 0, -floor(M.LEAD / unit + 0.5) * unit)
    handle:SetShown(not options.arrowLock)
end

local function DragStart()
    GameTooltip:Hide()
    dragging = true
    frame:StartMoving()
end

-- Also the frame's OnHide: a frame hidden mid-drag may never be told the drag ended.
local function DragStop()
    if not dragging then return end
    frame:StopMovingOrSizing()
    dragging = false
    local scale = frame:GetScale()
    local x, y = frame:GetCenter()
    Ledger.SetFramePos("pointer", x * scale - UIParent:GetWidth() / 2, y * scale - UIParent:GetHeight() / 2)
    Place(snap.options)
end

local function Tip(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(T.TIP_MOVE)
    if snap.dest and not aside then
        GameTooltip:AddLine(T.TIP_END)
    end
    GameTooltip:Show()
end

local function Untip()
    GameTooltip:Hide()
end

local function Stop()
    ns.Driver.Stop("hand")
end

local function Menu(_, root)
    root:CreateButton(T.MENU_STOP, Stop)
end

local function OnMouseUp(self, button)
    if button == "RightButton" and snap.dest and not aside and self:IsMouseOver() then
        GameTooltip:Hide()
        MenuUtil.CreateContextMenu(self, Menu)
    end
end

local function Layer(layer, sub, blend)
    local tex = frame:CreateTexture(nil, layer, nil, sub)
    tex:SetBlendMode(blend)
    tex:Hide()
    return tex
end

-- A turned texture snapped to the pixel grid shimmers as it turns.
local function Turned(tex)
    tex:SetAllPoints(frame)
    tex:SetSnapToPixelGrid(false)
    tex:SetTexelSnappingBias(0)
end

local function Create()
    frame = CreateFrame("Frame", "FerrymanPointer", UIParent)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:SetDontSavePosition(true)
    frame:SetClampRectInsets(-M.SIDE, M.SIDE, 0, -M.BELOW)
    frame:Hide()
    frame:SetScript("OnHide", DragStop)
    glow = Layer("BACKGROUND", 0, "ADD")
    glow:SetTexture(M.ART .. M.FILE.glow .. ".tga")
    glow:SetPoint("CENTER", frame, "CENTER")
    body = Layer("ARTWORK", 0, "BLEND")
    gloss = Layer("ARTWORK", 1, "ADD")
    gloss:SetAlpha(0.55)
    Turned(body)
    Turned(gloss)
    line1 = frame:CreateFontString(nil, "ARTWORK", M.FONT.main)
    line2 = frame:CreateFontString(nil, "ARTWORK", M.FONT.sub)
    -- The frame takes no mouse; this child does, and exists on screen only while the readout is unlocked.
    handle = CreateFrame("Frame", nil, frame)
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", DragStart)
    handle:SetScript("OnDragStop", DragStop)
    handle:SetScript("OnMouseUp", OnMouseUp)
    handle:SetScript("OnEnter", Tip)
    handle:SetScript("OnLeave", Untip)
end

local function Hide()
    if frame and frame:IsShown() then
        M.Rest()
        frame:Hide()
    end
end

function M.OnChange(snapshot, what)
    snap = snapshot
    local state, options = snapshot.state, snapshot.options
    -- A tick a subscriber is still owed can carry the arrival the next publish reports.
    if snapshot.arrived and what ~= "tick" and options.arriveSound then
        Env.Sound(M.SOUND.arrive)
    end
    local trip, leg, broken = snapshot.trip, snapshot.leg, snapshot.broken
    -- With the planner off nothing of Ferryman's own shows while no trip is set: no landing or dock is told.
    local free = options.planner or state ~= "idle"
    local fly = free and snapshot.flyTo      -- a flight's landing (5.5.13) comes before every other mode
    -- Guided: a walk of a trip that follows RestedXP on the land its arrow points on, which leads there itself;
    -- Ferryman names a ride ahead in text only (INTERFACES 6.2).
    local guided = state == "walking" and snapshot.guideArrow and (snapshot.dest.source == "guide" or snapshot.dest.kind == "corpse")
        and snapshot.dest.landmass == leg.from.landmass
    local ride = guided and ns.Trip.RideAhead(trip)
    -- The dock list (5.5.12): in idle, and on a guided walk with no ride ahead, where it is all there is to show.
    local docks = free and snapshot.docks.n > 0 and (state == "idle" or snapshot.reason == "tram" or guided and not ride) and snapshot.docks
    local leads = (state == "walking" or state == "waiting" or state == "riding") and not (guided and not ride)
    local own = options.arrow and (fly or docks or leads)
    -- Another addon's point (5.5.17) has the arrow while nothing of a trip, a flight or a dock is shown, where it can
    -- point: from a position on its landmass, with a facing.
    local a = not own and options.arrow and snapshot.arrow
    if a then
        local m, x = Env.Position()
        a = x and m == a.landmass and Env.Facing() ~= nil and a
    end
    if not (own or a) then
        Hide()
        return
    end
    if not frame then
        Create()
    end
    local hidden, was, wasAside = not frame:IsShown(), leading, aside
    if hidden or what == "state" or what == "option" then
        Place(options)
    end
    local lead = a or not fly and state == "walking" and not broken and not guided and Env.Facing() ~= nil
        and not (snapshot.dest.kind == "pin" and trip.at == trip.n and trip.bendLast)
    -- A new leg, trail or trip turns the arrow at once; a bend moved on by a tick swings it over M.EASE.
    if what ~= "tick" then
        fresh = true
    end
    -- Between a trip and another addon's point the arrow starts anew, in the other's colour.
    aside = a or false
    if aside ~= wasAside then
        yardKey, fresh, tone = nil, true, nil
    end
    if lead and not leading then
        leading, yardKey, fresh, tone = true, nil, true, nil
        body:Show()
        gloss:Show()
        glow:Show()
        frame:SetScript("OnUpdate", Lead)
    elseif not lead then
        M.Rest()
    end
    if a then
        Lead()
        Put(line2, "")
    elseif fly then
        riding.kind, riding.toName = snapshot.flyKind or "flight", fly
        Put(line1, T.Riding(riding))
        Put(line2, snapshot.flyLeft and T.Lands(snapshot.flyLeft, riding.kind ~= "flight") or "")
    elseif broken then
        Put(line1, T.N_REPLAN)
        Put(line2, "")
    elseif docks then
        local a, b = docks[1], docks.n > 1 and docks[2]
        Put(line1, b and format(T.DOCK_LINE, T.Dock(a), T.Pier(a.count, a.what)) or T.Dock(a))
        Put(line2, b and format(T.DOCK_LINE, T.Dock(b), T.Pier(b.count, b.what)) or T.Pier(a.count, a.what))
    elseif guided then
        Put(line1, T.Step(leg, false, trip))
        Put(line2, T.Yards(snapshot.yards))
    elseif state == "walking" then
        if leading then
            Lead()
        end
        if not leading then
            Put(line1, T.Yards(snapshot.yards))
        end
        Put(line2, snapshot.dest.kind == "corpse" and format(T.ARROW_BODY, T.Time(snapshot.left)) or T.Time(snapshot.left))
    elseif state == "waiting" then
        -- The one wait on a walk is at the flight master of a "go there first" trip.
        Put(line1, leg.kind == "walk" and T.ARROW_OPEN or T.Step(leg, false, trip))
        Put(line2, snapshot.count and T.Pier(snapshot.count, snapshot.countWhat) or T.Tag(leg))
    else
        Put(line1, T.Riding(leg))
        Put(line2, T.Time(snapshot.left))
    end
    if what ~= "tick" or hidden or leading ~= was or aside ~= wasAside then
        Grip()
    end
    if hidden then
        frame:Show()
    end
end

ns.Driver.Subscribe(M.OnChange)
