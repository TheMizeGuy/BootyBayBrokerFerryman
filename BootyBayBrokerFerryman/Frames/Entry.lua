local ADDON, ns = ...

-- Every way the player gives a destination or a command, and the chat replies.
local M = {}
ns.Entry = M

M.ATLAS = { icon = "FlightMasterFerry" }
-- The round button art of the world map's own corner buttons.
M.FILE = {
    back = [[Interface\Minimap\UI-Minimap-Background]], ring = [[Interface\Minimap\MiniMap-TrackingBorder]],
    glow = [[Interface\Minimap\UI-Minimap-ZoomButton-Highlight]], on = [[Interface\Minimap\UI-Minimap-ZoomButton-Toggle]],
}

local format, floor, tonumber, tostring = string.format, math.floor, tonumber, tostring
local T, Env, Ledger, Driver = ns.T, ns.Env, ns.Ledger, ns.Driver

local button, lit
local ready = false              -- the login work is done
local armed = false
local list, facts, args = {}, {}, {}

local function Say(text)
    print(T.CHAT_PREFIX .. text)
end

-- A title is at most 60 characters, never cut inside one (INTERFACES 3.3).
local function Go(kind, ref, uiMap, mx, my, title)
    local ok, reason = Driver.Go(kind, ref, uiMap, mx, my, title and Driver.Title(title), "hand")
    return ok or Say(T[reason])
end

-- Picking on the map
local function Disarm()
    armed = false
    lit:Hide()
end

-- The button hides with the map and that ends the arming; armed with the map closed, it therefore lasts until
-- the map has been shown and hidden again.
local function Arm()
    armed = true
    lit:Show()
    if not WorldMapFrame:IsShown() then
        Say(T.ARMED_OPEN)
    end
end

local function OnMapClick(map, mouse)
    if mouse ~= "LeftButton" or not (armed or IsAltKeyDown()) or not Driver.Snapshot().options.planner then
        return
    end
    Disarm()
    local mx, my = map:GetNormalizedCursorPosition()
    Go("point", 0, map:GetMapID(), mx, my, T.DEST_SPOT)
    return true
end

-- A left click on one of the map's own pins never reaches the canvas handlers (MapCanvas_DataProviderBase.lua:233).
local function OnPinAction(map, action, mouse)
    if action == MapCanvasMixin.MouseAction.Click then
        return OnMapClick(map, mouse)
    end
    return mouse == "LeftButton" and (armed or IsAltKeyDown()) and Driver.Snapshot().options.planner == true
end

local function OnMapCursor()
    return armed and "MAP_PIN_CURSOR" or nil
end

local function Tip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(armed and T.TIP_ARMED or T.TIP_BUTTON)
    GameTooltip:Show()
end

-- Whether another shown button of the map's top-right column, the map's own or another addon's, stands within 32 of y.
local function Taken(y, f, ...)
    if not f then return false end
    if f ~= button and not f:IsForbidden() and f:IsShown() then
        local point, rel, _, x, fy = f:GetPoint(1)
        if point == "TOPRIGHT" and rel == WorldMapFrame.ScrollContainer and x > -36 and fy > y - 32 and fy < y + 32 then
            return true
        end
    end
    return Taken(y, ...)
end

-- The column's first free place from its top, 32 apart as the map's own are (Blizzard_WorldMap.lua:310-322): never
-- over another button, and the same place each time while the others stand.
local function Place()
    local y = -2
    while Taken(y, WorldMapFrame:GetChildren()) do y = y - 32 end
    button:SetPoint("TOPRIGHT", WorldMapFrame.ScrollContainer, "TOPRIGHT", -4, y)
end

local function Art(layer, level, size, x, y, file)
    local tex = button:CreateTexture(nil, layer, nil, level)
    tex:SetSize(size, size)
    tex:SetPoint("TOPLEFT", x, y)
    tex:SetTexture(file)
    return tex
end

local function CreateButton()
    button = CreateFrame("Button", "FerrymanMapButton", WorldMapFrame)
    button:SetSize(32, 32)
    Place()
    button:SetFrameStrata("HIGH")
    Art("BACKGROUND", 0, 25, 3, -4, M.FILE.back)
    Art("ARTWORK", 0, 20, 7, -6):SetAtlas(M.ATLAS.icon)
    Art("OVERLAY", 1, 54, 0, 0, M.FILE.ring)
    lit = Art("OVERLAY", 2, 37, -2, 1, M.FILE.on)
    lit:SetBlendMode("ADD")
    lit:Hide()
    button:SetHighlightTexture(M.FILE.glow, "ADD")
    button:EnableMouse(true)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetScript("OnClick", function(self, mouse)
        if mouse == "RightButton" then
            Disarm()
        else
            M.Menu(self)
        end
    end)
    button:SetScript("OnEnter", Tip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnShow", function() Place(); Driver.Prepare() end)
    button:SetScript("OnHide", Disarm)
    -- The map refreshes its own corner buttons on a map change, with the map open.
    if type(WorldMapFrame.RefreshOverlayFrames) == "function" then hooksecurefunc(WorldMapFrame, "RefreshOverlayFrames", Place) end
end

-- "Where to?"
local function GoDoor(map)
    Go("entrance", map, nil, nil, nil, Env.InstanceName(map))
end

local function GoPin()
    if not Env.Pin() then
        return Say(T.E_NOPIN)
    end
    Go("pin", 0, nil, nil, nil, T.DEST_PIN)
end

local function GoQuest(quest)
    local title = Env.QuestTitle(quest)
    Go("quest", quest, nil, nil, nil, title ~= "" and title or T.MENU_QUEST)
end

local function GoParty(i)
    Go("party", i, nil, nil, nil, Env.Party(i) or format(T.MENU_PARTY_N, i))
end

local function Stop()
    Say(Driver.Stop("hand") and T.STOPPED or T.NO_TRIP)
end

local function Options()
    return ns.Options.Open() or Say(T.OPTIONS_COMBAT)
end

local function Build(_, root)
    root:CreateTitle(T.MENU_TITLE)
    root:CreateButton(T.MENU_PICK, Arm)
    local doors = root:CreateButton(T.MENU_ENTRANCES)
    doors:SetScrollMode(400)
    for i = 1, Driver.Entrances(list) do
        local e = list[i]
        local name = Env.InstanceName(e.map) or tostring(e.map)
        if not e.known then
            doors:CreateButton(format(T.MENU_DOOR_UNKNOWN, name)):SetEnabled(false)
        elseif e.seconds then
            doors:CreateButton(format("%s  %s", name, T.Time(e.seconds)), GoDoor, e.map)
        else
            doors:CreateButton(name, GoDoor, e.map)
        end
    end
    root:CreateButton(T.MENU_PIN, GoPin):SetEnabled(Env.Pin() ~= nil)
    local quest = Env.Quest()
    if not quest then
        root:CreateButton(T.MENU_QUEST):SetEnabled(false)
    elseif Env.QuestPlace(quest) then
        root:CreateButton(T.MENU_QUEST, GoQuest, quest)
    elseif Ledger.Knowledge().quests[quest] then
        root:CreateButton(T.MENU_QUEST_BACK, GoQuest, quest)
    else
        root:CreateButton(T.MENU_QUEST_NONE):SetEnabled(false)
    end
    local party = root:CreateButton(T.MENU_PARTY)
    local members = 0
    for i = 1, 4 do
        local name, landmass = Env.Party(i)
        if landmass then
            members = members + 1
            party:CreateButton(name or format(T.MENU_PARTY_N, i), GoParty, i)
        end
    end
    party:SetEnabled(members > 0)
    root:CreateDivider()
    root:CreateButton(T.MENU_STOP, Stop):SetEnabled(Driver.Snapshot().state ~= "idle")
    root:CreateButton(T.MENU_OPTIONS, Options)
end

-- A context menu opens at the cursor whatever its owner.
function M.Menu(owner)
    Driver.Prepare()
    MenuUtil.CreateContextMenu(owner or UIParent, Build)
end

-- Commands
-- [#uiMapID or zone name] x y [title] (INTERFACES 10.1)
local function Destination(text)
    local uiMap, rest
    local id = text:match("^#(%d+)")
    if text == "" then
        return Say(T.E_USAGE)
    elseif id then
        uiMap, rest = tonumber(id), text:match("^#%d+(.*)$")
        if not Env.MapName(uiMap) then
            return Say(format(T.E_ZONE, "#" .. id))
        end
    elseif text:match("^%d") then
        uiMap, rest = Env.now.uiMap, text
        if not uiMap then
            return Say(T.E_NOMAP)
        end
    else
        uiMap, rest = Env.FindMap(text)
        if not uiMap then
            return Say(format(T.E_ZONE, (text:match("^(.-)[%s,]*%d") or text)))
        end
    end
    -- Decimal commas, "42,5 65,3", are read as fractions; a lone one, "42 65,3" or "42,5 65", is refused, not misread.
    rest = rest:gsub("^([%s,]*%d+),(%d+)(%s+%d+),(%d+)", "%1.%2%3.%4")
    local a, gap, b, title = rest:match("^%s*,?%s*(%d+%.?%d*)%%?([%s,]+)(%d+%.?%d*)%%?(.*)$")
    if not a or gap:find(",.*,") or title:find("^[%s,]*%d*,%d") or (gap == "," and title:find("^%s+%d"))
        or (title ~= "" and not title:find("^[%s,]")) then
        return Say(T.E_USAGE)
    end
    local x, y = tonumber(a), tonumber(b)
    if x > 100 or y > 100 then
        return Say(T.E_RANGE)
    end
    title = title:match("^[%s,]*(.-)%s*$")
    Go("point", 0, uiMap, x / 100, y / 100, title ~= "" and title or format(T.DEST_COORDS, Env.MapName(uiMap), a, b))
end

local function Learned(rest)
    local word, key = rest:match("^(%S*)%s*(.-)$")
    if word:lower() == "forget" then
        if key == "" then
            return Say(T.L_FORGET_HOW)
        end
        local n = Ledger.Forget(key:lower() ~= "all" and key or nil)
        if n == 0 and key:lower() ~= "all" then
            return Say(format(T.L_FORGET_WHAT, key))
        end
        return Say(format(T.L_FORGOT, n))
    end
    Say(T.L_HEAD)
    local n = Ledger.Describe(facts)
    if n == 0 then
        Say(T.L_NONE)
    end
    for i = 1, n do
        local f = facts[i]
        local text, a, b = f.text, f.a, f.b
        -- The Ledger gives seconds, speeds and leg kinds as they are; the words for them are here.
        if text == "L_VESSEL" or text == "L_PHASE" or text == "L_PHASE_ABOUT" or text == "L_ERROR" then
            b = T.Time(b)
        end
        if text == "L_LOADING" then
            a = T.Time(a)
        elseif text == "L_FLY" then
            a = format("%.1f", a)
        elseif text == "L_ERROR" then
            a = T["KIND_" .. string.upper(a)] or a
        elseif text == "L_LANDING" then
            a = T.SpellName(a)
        end
        Say(format(T.L_LINE, format(T[text], a, b, f.c) .. (f.confirmed and "" or T.L_UNCONFIRMED), f.key))
    end
end

-- Each line is { key = a key of ns.T, its arguments... }; a figure with a fraction is shown to two places.
local function Bench(lines)
    for i = 1, #lines do
        local line = lines[i]
        local n = #line
        for k = 1, n do
            args[k] = (type(line[k]) == "number" and line[k] ~= floor(line[k])) and format("%.2f", line[k]) or line[k]
        end
        Say(format(T[line.key], unpack(args, 1, n)))
    end
end

local function Check()
    local _, key = Env.Check()
    Say(T[key])
    if Env.Secure(WorldMapFrame, "ScrollContainer") == nil then
        return Say(T.CHECK_UNAVAILABLE)
    end
    local clean = true
    local function Sweep(name, frame)
        for k in pairs(frame) do
            if not Env.Secure(frame, k) then
                clean = false
                Say(format(T.CHECK_DIRTY, name, tostring(k)))
            end
        end
    end
    Sweep("WorldMapFrame", WorldMapFrame)
    Sweep("WorldMapFrame.ScrollContainer", WorldMapFrame.ScrollContainer)
    Sweep("Minimap", Minimap)
    Sweep("TaxiFrame", TaxiFrame)
    if clean then
        Say(T.CHECK_CLEAN)
    end
end

-- Flips the arrow or the steps and says how the switch now stands: with no trip, nothing on screen shows it.
local function Toggle(key)
    if key == "steps" then
        ns.Steps.Toggle()
    else
        Driver.SetOption(key, not Driver.Snapshot().options[key])
    end
    Say(T[key:upper() .. (Driver.Snapshot().options[key] and "_ON" or "_OFF")])
end

-- The slash key that owns /way: one the chat box already moved into its hash (ChatFrameUtil.lua:809-827), else
-- one still in SlashCmdList (INTERFACES 10.2).
local function WayOwner()
    local filed = hash_ChatTypeInfoList and hash_ChatTypeInfoList["/WAY"]
    if filed and filed ~= "FERRYMANWAY" then
        return filed
    end
    for name in pairs(SlashCmdList) do
        local i = 1
        while name ~= "FERRYMANWAY" and type(_G["SLASH_" .. name .. i]) == "string" do
            if string.lower(_G["SLASH_" .. name .. i]) == "/way" then
                return name
            end
            i = i + 1
        end
    end
end

local COMMANDS = {
    [""] = function() M.Menu() end,
    stop = Stop,
    options = Options,
    learned = Learned,
    bench = function() Driver.Bench(Bench) end,
    check = Check,
    steps = function() Toggle("steps") end,
    arrow = function() Toggle("arrow") end,
    guide = function() Toggle("followGuide") end,
    pin = GoPin,
    find = function(rest) ns.FindBox.Open(rest) end,
    help = function()
        for i = 1, 4 do
            Say(T["HELP_" .. i])
        end
        local owner = WayOwner()
        Say(T.Way(owner))
    end,
}

local function Command(msg)
    if not Driver.Snapshot().options.planner then return Options() end
    msg = msg:match("^%s*(.-)%s*$")
    local word, rest = msg:match("^(%S*)%s*(.*)$")
    word = word:lower()
    local fn = COMMANDS[word]
    if fn then
        return fn(rest)
    end
    Destination(word == "to" and rest or msg)
end

-- Key bindings and the addon compartment
BINDING_HEADER_FERRYMAN = T.BINDING_HEADER
BINDING_NAME_FERRYMAN_WHERETO = T.BINDING_WHERETO
BINDING_NAME_FERRYMAN_CURSOR = T.BINDING_CURSOR
BINDING_NAME_FERRYMAN_PIN = T.BINDING_PIN
BINDING_NAME_FERRYMAN_STOP = T.BINDING_STOP
BINDING_NAME_FERRYMAN_STEPS = T.BINDING_STEPS
BINDING_NAME_FERRYMAN_FIND = T.BINDING_FIND

-- The compartment calls with the addon's name.
function Ferryman_Key(action)
    if not ready then
        Say(T.E_OFF)
    elseif not Driver.Snapshot().options.planner then Options()
    elseif action == "WHERETO" or action == ADDON then
        M.Menu()
    elseif action == "CURSOR" then
        if WorldMapFrame:IsShown() and WorldMapFrame:IsCanvasMouseFocusOrPinFocus() then
            local mx, my = WorldMapFrame:GetNormalizedCursorPosition()
            Go("point", 0, WorldMapFrame:GetMapID(), mx, my, T.DEST_SPOT)
        else
            Say(T.E_CURSOR)
        end
    elseif action == "PIN" then
        GoPin()
    elseif action == "STOP" then
        Stop()
    elseif action == "STEPS" then
        Toggle("steps")
    elseif action == "FIND" then
        ns.FindBox.Toggle()
    end
end

-- A frame after the login, when every addon's login handler has run; then the hello, until a first destination.
local function TakeWay()
    local owner = WayOwner()
    if not owner then
        SLASH_FERRYMANWAY1 = "/way"
        SlashCmdList.FERRYMANWAY = function(msg) Command("to " .. msg) end
    end
    if Ledger.Hello() or not Driver.Snapshot().options.planner then return end
    Say(format(ns.Guide.Active() and T.HELLO_GUIDE or T.HELLO, T.Way(owner)))
end

local function Login()
    ready = true
    SLASH_FERRYMAN1, SLASH_FERRYMAN2 = "/ferryman", "/ferry"
    SlashCmdList.FERRYMAN = Command
    Env.After(0, TakeWay)
    WorldMapFrame:AddCanvasClickHandler(OnMapClick, 100)
    WorldMapFrame:AddGlobalPinMouseActionHandler(OnPinAction, 100)
    WorldMapFrame:AddCursorHandler(OnMapCursor, 100)
    CreateButton()
end

-- The first publish that carries the options is the login's; without one the data did not load. The finder's
-- button hears of the options here: a subscriber of its own would make a tick's spread a frame longer.
function M.OnChange(snapshot, what)
    if not ready and next(snapshot.options) then
        Login()
    end
    if what ~= "option" then return end
    ns.FindBox.OnChange(snapshot)
    if button then button:SetShown(snapshot.options.planner == true) end
    if button and not snapshot.options.planner then Disarm() end
end

Driver.Subscribe(M.OnChange)
