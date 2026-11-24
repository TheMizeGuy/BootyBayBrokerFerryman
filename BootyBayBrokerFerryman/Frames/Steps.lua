local ADDON, ns = ...

-- The header, the notices and one line per ride.
local M = {}
ns.Steps = M

M.WORTH, M.FAR = 30, 300         -- seconds: a wait or a last walk under WORTH gets no line; a walk to a ride from FAR on is said
M.ATLAS = {
    header = "UI-QuestTracker-Secondary-Objective-Header",
    walk = "Waypoint-MapPin-Untracked", flight = "FlightPath", boat = "FlightMasterFerry",
    tram = "Vehicle-AllianceCart", lift = "poi-door-up", liftDown = "poi-door-down", portal = "MagePortalAlliance",
    hearth = "Innkeeper", spell = "MagePortalAlliance", zeppelin = "dragonriding-barbershop-icon-delvesairshipgoblin",
    close = "RedButton-Exit", closeDown = "RedButton-exit-pressed", closeLit = "RedButton-Highlight",
}
M.FONT = { title = "GameFontNormalMed3", line = "GameFontHighlight", small = "GameFontHighlightSmall" }
-- UI units, before they are put on the pixel grid.
M.WIDTH, M.HEADER = 260, 26      -- the client's own tracker header is 260 by 26 with its text 7 in
M.X, M.Y = 40, 120               -- default: left edge this far from the screen's, centre this far above its centre
M.INSET, M.ICON, M.TIME = 7, 18, 52
M.CLOSE_W, M.CLOSE_H = 18, 19    -- the client's red exit button
M.DIM = 0.65                     -- later legs against the current one
M.GOLD, M.GREY = { 1, 0.82, 0 }, { 0.6, 0.6, 0.6 }    -- the client's own normal text and finished-objective colours

local floor, format, max = math.floor, string.format, math.max
local T, Ledger, Driver = ns.T, ns.Ledger, ns.Driver

local STATE = {
    dead = "S_DEAD", loading = "S_LOADING", instance = "S_INSTANCE", air = "S_AIR", carried = "S_CARRIED", lost = "S_LOST", tram = "S_TRAM",
    nodata = "S_NODATA", noWay = "F_NOWAY", noGround = "F_NOGROUND", tooFar = "F_TOOFAR", error = "F_ERROR",
}
local KIND = {
    flight = "KIND_FLIGHT", boat = "KIND_BOAT", zeppelin = "KIND_ZEPPELIN", tram = "KIND_TRAM", lift = "KIND_LIFT",
    portal = "KIND_PORTAL", hearth = "KIND_HEARTH", spell = "KIND_SPELL",
}

local frame, strip, title, head, handle, closer
local rows, used = {}, 0
local snap
local shown = {}                 -- [font string] = the text it shows
local dragging = false
local unit = 1                   -- UI units of the frame per physical pixel
local headH = 0                  -- the header line's height the rows were laid out under
local clockMinute, clockText
local skipped = {}               -- [kind .. ref] = the sentence of a leg declined from its row

local function Put(fs, text)
    if shown[fs] ~= text then
        shown[fs] = text
        fs:SetText(text)
    end
end

local function Px(v)
    return floor(v / unit + 0.5) * unit
end

-- An even number of whole pixels, so that a centred piece has its edges on the grid.
local function Even(v)
    return floor(v / (2 * unit) + 0.5) * 2 * unit
end

-- A notice's numbers are durations.
local function Arg(v)
    if type(v) == "number" then
        return T.Time(v)
    end
    return v
end

local function HeadText(snapshot)
    local state, trip = snapshot.state, snapshot.trip
    if state == "planning" then
        return snapshot.estimate and format(T.HEAD_PLANNING, T.Time(snapshot.estimate)) or T.HEAD_PLANNING0
    elseif state == "walking" or state == "waiting" or state == "riding" then
        local minute = floor(trip.arrive / 60)
        if minute ~= clockMinute then
            clockMinute, clockText = minute, T.Clock(trip.arrive)
        end
        return format(T.HEAD_ARRIVE, clockText, T.Time(snapshot.left))
    end
    return T[STATE[state == "dead" and state or snapshot.reason]] or ""
end

-- Under a leg's sentence: the departure while waited for, nothing while ridden, its tag or a long wait (now: current).
local function Under(snapshot, leg, now)
    if now and snapshot.state == "waiting" and snapshot.count then
        return T.Pier(snapshot.count, snapshot.countWhat)
    end
    if now and snapshot.state == "riding" then return "" end
    local tag, wait = T.Tag(leg), leg.kind ~= "walk" and (now and leg.depart - now or leg.wait) or 0
    if tag == "" and wait >= M.WORTH then
        return format(T.STEP_WAIT, T.Time(wait))
    end
    return tag
end

local function OnClick(hit, button)
    local row, role = hit.row, hit.row.role
    if role == "leg" and button == "RightButton" and row.kind ~= "walk" then
        local kind, ref, text = row.kind, row.ref, shown[row.text]
        -- A flight's ref is its master, so declining it skips every flight from there: the master is named.
        local leg = kind == "flight" and snap.trip and snap.trip.legs[row.k]
        if leg then text = format(T.STEP_SKIP_FLIGHT, ns.Env.PlaceName(leg.from)) end
        MenuUtil.CreateContextMenu(hit, function(_, root)
            root:CreateButton(T.CTX_WITHOUT, function()
                skipped[kind .. ref] = text
                Driver.Decline(kind, ref)
            end)
        end)
    elseif role == "skip" and button == "LeftButton" then
        Driver.Restore(row.kind, row.ref)
    elseif role == "note" and row.act and button == "LeftButton" then
        local ok, why = Driver.Act(row.act)
        if not ok and why and T[why] then print(T.CHAT_PREFIX .. T[why]) end
    end
end

-- A row that answers a left click turns white under the mouse.
local function OnEnter(hit)
    if hit.row.act or hit.row.role == "skip" then
        hit.row.text:SetTextColor(1, 1, 1)
    end
end

local function OnLeave(hit)
    local c = hit.row.colour
    hit.row.text:SetTextColor(c[1], c[2], c[3])
end

local function Row(i)
    local row = rows[i]
    if not row then
        row = CreateFrame("Frame", nil, frame)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.text = row:CreateFontString(nil, "ARTWORK", M.FONT.line)
        row.time = row:CreateFontString(nil, "ARTWORK", M.FONT.line)
        row.sub = row:CreateFontString(nil, "ARTWORK", M.FONT.small)
        row.sub:SetTextColor(M.GOLD[1], M.GOLD[2], M.GOLD[3])
        row.text:SetJustifyH("LEFT")
        row.sub:SetJustifyH("LEFT")
        row.time:SetJustifyH("RIGHT")
        row.sub:SetPoint("TOPLEFT", row.text, "BOTTOMLEFT", 0, 0)
        -- Only a row that answers a click takes the mouse, through this child, shown while it does.
        local hit = CreateFrame("Button", nil, row)
        hit:SetAllPoints(row)
        hit:EnableMouse(true)
        hit:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        hit:SetScript("OnClick", OnClick)
        hit:SetScript("OnEnter", OnEnter)
        hit:SetScript("OnLeave", OnLeave)
        hit.row, row.hit = row, hit
        rows[i] = row
    end
    return row
end

-- Gives row i its role and shape at y below the frame. A leg row has an icon and a time; the others only text.
local function Shape(i, y, role, colour)
    local row = Row(i)
    local leg = role == "leg"
    row.role, row.colour = role, colour
    local left = leg and Px(M.INSET + M.ICON + 6) or Px(M.INSET)
    local textWidth = Px(M.WIDTH) - left - Px(leg and M.TIME or M.INSET)
    row.text:SetFontObject(leg and M.FONT.line or M.FONT.small)
    row.text:SetTextColor(colour[1], colour[2], colour[3])
    row.text:ClearAllPoints()
    -- A leg's first line is centred on its icon.
    row.text:SetPoint("TOPLEFT", row, "TOPLEFT", left, leg and -Px(3) or 0)
    row.text:SetWidth(textWidth)
    row.sub:SetWidth(textWidth)
    row.icon:SetShown(leg)
    row.time:SetShown(leg)
    row:SetAlpha(1)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -y)
    return row
end

-- The row's height from what its strings came to, and the y below it.
local function Close(row, y, gap)
    local height = row.text:GetStringHeight()
    if shown[row.sub] ~= "" then
        height = height + row.sub:GetStringHeight()
    end
    if row.role == "leg" then
        height = max(height + Px(3), Px(M.ICON))
    end
    height = Px(height)
    row:SetSize(Px(M.WIDTH), height)
    row.hit:SetShown(row.act ~= false or row.role == "skip" or (row.role == "leg" and row.kind ~= "walk"))
    row:Show()
    return y + height + Px(gap)
end

local WHITE = { 1, 1, 1 }

local function Icon(tex, leg)
    local kind = leg.kind
    if kind == "spell" or kind == "hearth" then
        local file = leg.item > 0 and C_Item.GetItemIconByID(leg.item) or C_Spell.GetSpellTexture(leg.ref)
        if file then
            tex:SetTexture(file)
            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            return
        end
    elseif kind == "lift" then
        local _, level = ns.Net.LinkOfAnchor(leg.to.anchor)
        if level == 1 then
            tex:SetAtlas(M.ATLAS.liftDown)
            return
        end
    end
    tex:SetAtlas(M.ATLAS[kind])
end

-- Every row from the top: notices, legs from the current one on, declined kinds. With numbersOnly (a tick)
-- only times and what stands under a sentence change; it returns false when that would move a row.
local function Fill(snapshot, numbersOnly)
    local h = Px(head:GetStringHeight())
    if numbersOnly and h ~= headH then return false end
    headH = h
    local i, y = snapshot.nNotices, Px(4) + h + Px(5)
    if not numbersOnly then
        for k = 1, i do
            local n = snapshot.notices[k]
            local row = Shape(k, y, "note", n.act and M.GOLD or WHITE)
            row.act = n.act
            Put(row.text, format(T[n.key], Arg(n.a), Arg(n.b), Arg(n.c)))
            Put(row.sub, "")
            y = Close(row, y, 5)
        end
        y = y + Px(2)
    end
    -- The one wait on a walk is at the flight master of a "go there first" trip, whose notice says what to do.
    local trip = not (snapshot.state == "waiting" and snapshot.leg.kind == "walk") and snapshot.trip
    if trip then
        -- The last leg on land: the trip's last, or the one before the swim that ends it.
        local now, n, time, land = trip.arrive - snapshot.left, 0, 0, trip.n - (trip.swim and 1 or 0)
        for k = trip.at, trip.n do
            local leg = trip.legs[k]
            local ride, walk = leg.kind ~= "walk" and leg.kind ~= "lift", time
            local swim = k == 1 and trip.shore or k == trip.n and trip.swim
            -- The leg at hand counts down with the header: what is left of it.
            time = time + (k == trip.at and max(0, leg.arrive - now) or leg.seconds + leg.wait)
            -- A row is a ride, with the way to it, or a swim; or the walk left on land after the last ride, when it
            -- is worth a line.
            if ride or swim or k == land and (n > 0 or trip.swim) and time >= M.WORTH then
                n, i = n + 1, i + 1
                local under = Under(snapshot, leg, k == trip.at and now)
                -- A long walk to the ride is said, so that the row's time is not taken for the ride's own.
                if under == "" and ride and k > trip.at and trip.legs[k - 1].seconds >= M.FAR then
                    under = format(T.STEP_AFTER_WALK, T.Time(walk))
                end
                local row = rows[i]
                if numbersOnly then
                    if not row or row.role ~= "leg" or row.k ~= k or (under == "") ~= (shown[row.sub] == "") then
                        return false
                    end
                else
                    row = Shape(i, y, "leg", WHITE)
                    row.kind, row.ref, row.act, row.k = leg.kind, leg.ref, false, k
                    row.icon:SetSize(Px(M.ICON), Px(M.ICON))
                    row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", Px(M.INSET), 0)
                    row.time:SetPoint("TOPRIGHT", row, "TOPRIGHT", -Px(4), -Px(3))
                    Icon(row.icon, leg)
                    row:SetAlpha(n == 1 and 1 or M.DIM)
                    Put(row.text, T.Step(leg, k == trip.n, trip))
                end
                Put(row.time, T.Time(time))
                Put(row.sub, under)
                if not numbersOnly then
                    y = Close(row, y, 5)
                end
                time = 0
            end
        end
    end
    if numbersOnly then
        return i + snapshot.nDeclined == used
    end
    for k = 1, snapshot.nDeclined do
        local d = snapshot.declined[k]
        i = i + 1
        local row = Shape(i, y, "skip", M.GREY)
        row.kind, row.ref, row.act = d.kind, d.ref, false
        local one = d.ref ~= 0 and skipped[d.kind .. d.ref]
        Put(row.text, format(T.STEP_DECLINED, one or T[KIND[d.kind]]))
        Put(row.sub, "")
        y = Close(row, y, 3)
    end
    for k = i + 1, used do
        rows[k]:Hide()
    end
    used = i
    -- Keeps the rows that hang under the frame on the screen too.
    frame:SetClampRectInsets(0, 0, 0, -y)
    return true
end

local function Place(options)
    if dragging then
        return
    end
    local scale = options.stepsScale
    frame:SetScale(scale)
    local _, height = GetPhysicalScreenSize()
    unit = 768 / (height * frame:GetEffectiveScale())
    local w = Even(M.WIDTH)
    frame:SetSize(w, Even(M.HEADER))
    local x, y = Ledger.FramePos("steps")
    if not x then
        x, y = M.X + M.WIDTH * scale / 2 - UIParent:GetWidth() / 2, M.Y
    end
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", Px(x / scale), Px(y / scale))
    strip:SetSize(Even(300), Even(30))
    title:SetPoint("LEFT", frame, "LEFT", Px(M.INSET), 0)
    title:SetWidth(w - 2 * Px(M.INSET) - Px(22))
    closer:SetSize(Px(M.CLOSE_W), Px(M.CLOSE_H))
    closer:SetPoint("RIGHT", frame, "RIGHT", -Px(4), 0)
    head:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", Px(M.INSET), -Px(4))
    head:SetWidth(w - 2 * Px(M.INSET))
    handle:SetShown(not options.stepsLock)
end

local function DragStart()
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
    Ledger.SetFramePos("steps", x * scale - UIParent:GetWidth() / 2, y * scale - UIParent:GetHeight() / 2)
    Place(snap.options)
end

local function Create()
    frame = CreateFrame("Frame", "FerrymanSteps", UIParent)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:SetDontSavePosition(true)
    frame:Hide()
    frame:SetScript("OnHide", DragStop)
    strip = frame:CreateTexture(nil, "BACKGROUND")
    strip:SetAtlas(M.ATLAS.header)
    strip:SetPoint("CENTER", frame, "CENTER", 0, 0)
    title = frame:CreateFontString(nil, "ARTWORK", M.FONT.title)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    head = frame:CreateFontString(nil, "ARTWORK", M.FONT.line)
    head:SetJustifyH("LEFT")
    -- The header is the drag handle; it is on screen, and so takes the mouse, only while unlocked.
    handle = CreateFrame("Frame", nil, frame)
    handle:SetAllPoints(frame)
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", DragStart)
    handle:SetScript("OnDragStop", DragStop)
    -- Above the handle, and shown with the steps whether they are locked or not.
    closer = CreateFrame("Button", nil, frame)
    closer:SetFrameLevel(handle:GetFrameLevel() + 1)
    closer:EnableMouse(true)
    closer:RegisterForClicks("LeftButtonUp")
    closer:SetNormalAtlas(M.ATLAS.close)
    closer:SetPushedAtlas(M.ATLAS.closeDown)
    closer:SetHighlightAtlas(M.ATLAS.closeLit, "ADD")
    closer:SetScript("OnClick", function() Driver.Stop("hand") end)
    closer:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(T.MENU_STOP)
        GameTooltip:Show()
    end)
    closer:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function M.Toggle()
    Driver.SetOption("steps", not Driver.Snapshot().options.steps)
end

-- A trip that follows RestedXP shows only when there is more to say than "walk there" (INTERFACES 6.3).
local function Quiet(snapshot)
    local state, n = snapshot.state, snapshot.nNotices
    if snapshot.dest.source ~= "guide" or n > 1 or n == 1 and snapshot.notices[1].key ~= "N_REPLAN"
        or state == "suspended" and snapshot.reason == "nodata" then return false end
    return not ((state == "walking" or state == "waiting" or state == "riding") and ns.Trip.RideAhead(snapshot.trip))
end

function M.OnChange(snapshot, what)
    snap = snapshot
    local options = snapshot.options
    if not options.steps or snapshot.state == "idle" or snapshot.dest.kind == "corpse" or Quiet(snapshot) then
        if frame and frame:IsShown() then
            frame:Hide()
        end
        return
    end
    if not frame then
        Create()
    end
    local hidden = not frame:IsShown()
    if hidden or what == "state" or what == "option" then
        Place(options)
    end
    Put(head, HeadText(snapshot))
    if hidden or what ~= "tick" or not Fill(snapshot, true) then
        Put(title, format(T.HEAD_TO, snapshot.dest.kind == "pin" and T.DEST_PIN or snapshot.dest.title))
        Fill(snapshot, false)
    end
    if hidden then
        frame:Show()
    end
end

Driver.Subscribe(M.OnChange)
