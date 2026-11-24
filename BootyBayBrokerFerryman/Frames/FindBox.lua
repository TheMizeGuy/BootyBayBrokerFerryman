local ADDON, ns = ...

-- The finder on screen: a button the player places, and a box to type in with the places the Finder lists.
local M = {}
ns.FindBox = M

-- The field is the client's own search field and the rows its search results' (the box under its spell search).
M.ATLAS = {
    icon = "common-icon-search", glass = "common-search-magnifyingglass",
    left = "common-search-border-left", middle = "common-search-border-middle", right = "common-search-border-right",
    row = "_search-rowbg", pick = "search-select",
}
M.FONT = { text = "GameFontHighlight", name = "GameFontNormal", head = "GameFontHighlight", time = "GameFontHighlightSmall",
    line = "GameFontHighlightSmall" }
-- UI units, before they are put on the pixel grid.
M.BUTTON, M.Y = 28, 120          -- the button; default: top centre, its top this far under the screen's
M.WIDTH, M.FIELD, M.ROW, M.SHORT, M.ROWS = 260, 24, 34, 22, 7    -- the box, its field, a row of two lines and of one
M.INSET, M.GAP, M.LETTERS = 8, 4, 60
M.SHADE = 0.6                    -- black under the field
-- a place's name in the client's own gold; a row that says what is not here; second lines and the hint
M.GOLD, M.WHITE, M.GREY = { 1, 0.82, 0 }, { 1, 1, 1 }, { 0.68, 0.68, 0.68 }

local floor, min, max = math.floor, math.min, math.max
local T, Ledger, Finder = ns.T, ns.Ledger, ns.Finder
Finder.Texts(T)

local button, frame, edit, left, right, back, glass
local rows, shown, art = {}, {}, {}
local unit, laidB, laidF = 1, 0, 0       -- UI units per physical pixel; the unit the button and the box were laid out at
local sel, selE, moved = 0, 0, false     -- the row chosen by Enter, its entry, and whether the player moved it there
local focus = 0                  -- frames until the box asks for the keyboard
local dragging = false

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

-- Sizes and offsets in whole pixels: the button and its art, the field and the rows' insides. Done again when the
-- screen or the UI scale changed.
local function LayButton()
    local k = M.BUTTON / 32
    button:SetSize(Even(M.BUTTON), Even(M.BUTTON))
    for i = 1, #art do
        local a = art[i]
        a[1]:SetSize(Px(a[2] * k), Px(a[2] * k))
        a[1]:SetPoint("TOPLEFT", Px(a[3] * k), -Px(a[4] * k))
    end
end
local function LayBox()
    local field, cap, inset = Even(M.FIELD), Px(M.INSET), Px(M.INSET)
    left:SetSize(cap, field)
    right:SetSize(cap, field)
    back:SetPoint("TOPLEFT", left, "TOPLEFT", Px(3), -Px(3))
    back:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -Px(3), Px(3))
    glass:SetSize(Even(12), Even(12))
    glass:SetPoint("LEFT", left, "LEFT", inset, 0)
    edit:SetPoint("TOPLEFT", frame, "TOPLEFT", Px(M.INSET + 18), 0)
    edit:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -inset, 0)
    for i = 1, M.ROWS do
        local row = rows[i]
        row.time:SetPoint("TOPRIGHT", row, "TOPRIGHT", -inset, -Px(6))
        row.line:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", inset, Px(5))
        row.line:SetWidth(Even(M.WIDTH) - 2 * inset)
    end
end

-- The button's centre from the screen's, saved or default; the box hangs under it, or stands over it where the
-- screen ends first, its field at the same height whatever is listed. True when the box was laid out anew.
local function Place()
    local _, height = GetPhysicalScreenSize()
    unit = 768 / (height * UIParent:GetEffectiveScale())
    local w, h = UIParent:GetWidth(), UIParent:GetHeight()
    local x, y = Ledger.FramePos("find")
    if not x then
        x, y = 0, h / 2 - M.Y - M.BUTTON / 2
    end
    if button and laidB ~= unit then
        laidB = unit
        LayButton()
    end
    if button and not dragging then
        button:ClearAllPoints()
        button:SetPoint("CENTER", UIParent, "CENTER", Px(x), Px(y))
    end
    if not frame then return false end
    local tall = M.FIELD + M.GAP + M.ROWS * M.ROW
    local top = y - M.BUTTON / 2 - M.GAP
    if top - tall < -h / 2 then
        top = y + M.BUTTON / 2 + M.GAP + tall
    end
    local side = max(0, w / 2 - M.WIDTH / 2)
    frame:ClearAllPoints()
    frame:SetPoint("TOP", UIParent, "CENTER", Px(max(-side, min(side, x))), Px(top))
    if laidF == unit then return false end
    laidF = unit
    LayBox()
    return true
end

local function Select(i, byHand)
    local list = Finder.Rows()
    sel, selE, moved = i, i > 0 and list[i].e or 0, byHand or false
    for k = 1, M.ROWS do
        rows[k].pick:SetShown(k == i)
    end
end

-- Every row from the field down: a place has its name, its time at the right and a line under it; the others say
-- one thing and cannot be chosen.
local function Fill()
    local list, y, w = Finder.Rows(), Even(M.FIELD) + Px(M.GAP), Even(M.WIDTH)
    for i = 1, M.ROWS do
        local row, r = rows[i], i <= list.n and list[i]
        if r then
            local place, two = r.kind == "place", r.line ~= ""
            local h = Px(two and M.ROW or M.SHORT)
            row:SetSize(w, h)
            row:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -y)
            local font, colour = M.FONT.line, M.GREY
            if place then font, colour = M.FONT.name, M.GOLD elseif two then font, colour = M.FONT.head, M.WHITE end
            if row.colour ~= colour then
                row.colour = colour
                row.name:SetFontObject(font)
                row.name:SetTextColor(colour[1], colour[2], colour[3])
            end
            Put(row.name, r.name)
            Put(row.line, r.line)
            Put(row.time, place and (r.secs and T.Time(r.secs) or r.secs == false and T.FIND_NO_WAY) or "")
            row.name:ClearAllPoints()
            row.name:SetPoint(two and "TOPLEFT" or "LEFT", row, two and "TOPLEFT" or "LEFT", Px(M.INSET), two and -Px(5) or 0)
            row.name:SetWidth(w - 2 * Px(M.INSET) - Px(row.time:GetStringWidth() + (shown[row.time] ~= "" and M.GAP or 0)))
            row:Show()
            y = y + h
        else
            row:Hide()
        end
    end
    frame:SetSize(w, y)
end

-- New rows: Enter takes the first place. Rows put in the order of their plans: the choice stays with its place when
-- the player moved it there, and with the first place otherwise. A figure alone moves nothing.
local function Redraw(list, what)
    if not frame:IsShown() then return end
    local i, keep = what == "figures" and sel or 0, what == "order" and moved
    for k = 1, what == "figures" and 0 or list.n do
        if list[k].kind == "place" and (i == 0 or keep and list[k].e == selE) then i = k end
    end
    Fill()
    Select(i, what ~= "rows" and moved)
end

function M.Close()
    if not (frame and frame:IsShown()) then return end
    frame:SetScript("OnUpdate", nil)
    frame:Hide()
    edit:ClearFocus()
    Finder.Close()
end

local function Choose(i)
    local ok, why = Finder.Choose(i)
    if ok then return M.Close() end
    if why then print(T.CHAT_PREFIX .. T[why]) end
end

local function Move(by)
    local list = Finder.Rows()
    local i = sel > 0 and sel or by > 0 and 0 or 1
    for _ = 1, list.n do
        i = (i - 1 + by) % list.n + 1
        if list[i].kind == "place" then return Select(i, true) end
    end
end

-- The client takes the keyboard away at every left click that is not on the field. Over the box or the button the
-- box stays and asks for the keyboard again; anywhere else it closes.
local function Lost()
    if not frame:IsShown() then return end
    if frame:IsMouseOver() or (button and button:IsVisible() and button:IsMouseOver()) then
        focus = 1
    else
        M.Close()
    end
end

-- The keyboard is asked for a frame after the box shows, and only when no one holds it.
local function OnUpdate(_, elapsed)
    if focus > 0 then
        focus = focus - 1
        if focus == 0 and not GetCurrentKeyBoardFocus() then edit:SetFocus() end
    end
    Finder.Tick(elapsed)
end

local function Texture(parent, layer, atlas)
    local tex = parent:CreateTexture(nil, layer)
    tex:SetAtlas(atlas)
    return tex
end

local function Create()
    frame = CreateFrame("Frame", "FerrymanFind", UIParent)
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:Hide()
    left, right = Texture(frame, "BACKGROUND", M.ATLAS.left), Texture(frame, "BACKGROUND", M.ATLAS.right)
    left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    local middle = Texture(frame, "BACKGROUND", M.ATLAS.middle)
    middle:SetPoint("TOPLEFT", left, "TOPRIGHT", 0, 0)
    middle:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT", 0, 0)
    -- the client's field lets the world show through: darkened, so that white text reads on snow
    back = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
    back:SetColorTexture(0, 0, 0, M.SHADE)
    glass = Texture(frame, "ARTWORK", M.ATLAS.glass)
    edit = CreateFrame("EditBox", nil, frame)
    edit:SetAutoFocus(false)
    edit:SetFontObject(M.FONT.text)
    edit:SetMaxLetters(M.LETTERS)
    edit:SetAltArrowKeyMode(false)
    edit:EnableMouse(true)
    edit:SetScript("OnTextChanged", function(self) Finder.Type(self:GetText()) end)
    edit:SetScript("OnEnterPressed", function() if sel > 0 then Choose(sel) end end)
    edit:SetScript("OnEscapePressed", M.Close)
    edit:SetScript("OnTabPressed", function() Move(IsShiftKeyDown() and -1 or 1) end)
    edit:SetScript("OnArrowPressed", function(_, key) if key == "UP" or key == "DOWN" then Move(key == "UP" and -1 or 1) end end)
    edit:SetScript("OnEditFocusLost", Lost)
    for i = 1, M.ROWS do
        local row = CreateFrame("Button", nil, frame)
        row:EnableMouse(true)
        row:RegisterForClicks("LeftButtonUp")
        Texture(row, "BACKGROUND", M.ATLAS.row):SetAllPoints(row)
        row.pick = Texture(row, "BORDER", M.ATLAS.pick)
        row.pick:SetAllPoints(row)
        row.pick:Hide()
        row.name = row:CreateFontString(nil, "ARTWORK", M.FONT.name)
        row.time = row:CreateFontString(nil, "ARTWORK", M.FONT.time)
        row.line = row:CreateFontString(nil, "ARTWORK", M.FONT.line)
        row.line:SetTextColor(M.GREY[1], M.GREY[2], M.GREY[3])
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.line:SetJustifyH("LEFT")
        row.line:SetWordWrap(false)
        row.time:SetJustifyH("RIGHT")
        row.colour = false
        row:SetScript("OnEnter", function()
            if Finder.Rows()[i].kind == "place" then Select(i, true) end
        end)
        row:SetScript("OnClick", function()
            if Finder.Rows()[i].kind == "place" then Choose(i) end
        end)
        row:Hide()
        rows[i] = row
    end
    Finder.Subscribe(Redraw)
end

-- Opens the box with the text in it, or puts the text into the open box.
function M.Open(text)
    if not ns.Driver.Snapshot().options.planner then return end
    if not frame then Create() end
    if not frame:IsShown() then
        Finder.Open(T)
        Place()
        frame:Show()
        frame:SetScript("OnUpdate", OnUpdate)
        Redraw(Finder.Rows(), "rows")
    end
    focus = 2
    edit:SetText(text or "")
    Finder.Type(edit:GetText())
end

function M.Toggle()
    if frame and frame:IsShown() then M.Close() else M.Open() end
end

local function DragStart()
    GameTooltip:Hide()
    M.Close()
    dragging = true
    button:StartMoving()
end

-- Also the button's OnHide: a frame hidden mid-drag may never be told the drag ended.
local function DragStop()
    if not dragging then return end
    button:StopMovingOrSizing()
    dragging = false
    local x, y = button:GetCenter()
    Ledger.SetFramePos("find", x - UIParent:GetWidth() / 2, y - UIParent:GetHeight() / 2)
    Place()
end

-- The round art of the map's own button (Entry), at the button's size, around a magnifying glass: each piece with
-- its size and place in the map button's 32 units.
local function Art(layer, level, size, x, y, file)
    local tex = button:CreateTexture(nil, layer, nil, level)
    tex:SetTexture(file)
    art[#art + 1] = { tex, size, x, y }
    return tex
end

local function CreateButton()
    local FILE = ns.Entry.FILE
    button = CreateFrame("Button", "FerrymanFindButton", UIParent)
    button:SetMovable(true)
    button:SetClampedToScreen(true)
    button:SetDontSavePosition(true)
    Art("BACKGROUND", 0, 25, 3, 4, FILE.back)
    Art("ARTWORK", 0, 16, 8, 8):SetAtlas(M.ATLAS.icon)
    Art("OVERLAY", 1, 54, 0, 0, FILE.ring)
    button:SetHighlightTexture(FILE.glow, "ADD")
    button:EnableMouse(true)
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnClick", M.Toggle)
    button:SetScript("OnDragStart", DragStart)
    button:SetScript("OnDragStop", DragStop)
    button:SetScript("OnHide", DragStop)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(T.TIP_FIND)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- The button follows its option, and a change of the screen or of its saved place: Entry hands on every publish
-- of the options.
function M.OnChange(snapshot)
    if not next(snapshot.options) then return end
    local on = snapshot.options.findButton and snapshot.options.planner
    if not snapshot.options.planner then M.Close() end
    if on and not button then CreateButton() end
    if button then button:SetShown(on) end
    if Place() and frame:IsShown() then Redraw(Finder.Rows(), "figures") end
end

