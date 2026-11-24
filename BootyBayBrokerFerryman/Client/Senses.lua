local ADDON, ns = ...

-- Client events turned into facts. It owns the addon's only event frame.
local M = {}
ns.Senses = M

M.CARRY_REACH, M.moving, M.carried, M.loading = 40, false, false, false
M.held = false      -- the taxi flag still reads true after a landing

local FLIGHT_REACH, SWEPT_TICKS, STILL, THAW, OWN = 100, 3, 0.5, 5, 2
local CARRY_KINDS = { [2] = true, [3] = true, [5] = true }
local FLIGHT_KINDS, TRAM = { [1] = true }, { [3] = true }

local frame, sink
local onFlight, looks, deadSeen = false, 0, false     -- looks: reads of the taxi flag due after a loss of control
-- thaw: carried through a loading screen, the read it closed on can stand still for most of a second; ownT: since
local thaw, ownT = false, false     -- when a carried player has moved at their own pace by a dock, platform or lift
local pewLogin, pewReload, pewDone = false, false, false
local zoneTime, pinDue, spellsDue, taxiDue = false, false, false, false

local function Emit(fact, a, b, c)
    local ok, err = pcall(sink, fact, a, b, c)
    if not ok then geterrorhandler()(err) end
end

local function NearestAnchor(kinds, reach, m, x, y)
    local Net = ns.Net
    if not m then m, x, y = ns.Env.Position() end
    return m and Net.Nearest and Net.Nearest(m, x, y, kinds, reach) or 0
end

local function FlushPin()
    pinDue = false
    Emit("pin")
end

local function FlushSpells()
    spellsDue = false
    Emit("spells")
end

local function FlushTaxi()
    if taxiDue then
        taxiDue = false
        Emit("taxiOpen")
    end
end
-- A node chosen in the flight window, by its button or any caller of TakeTaxiNode (5.5.13): the window is read
-- first when it opened this frame.
local function Chose(slot) FlushTaxi(); Emit("chose", slot) end

local LATER = {
    "PLAYER_LOGOUT", "PLAYER_ENTERING_WORLD", "LOADING_SCREEN_ENABLED", "LOADING_SCREEN_DISABLED",
    "PLAYER_CONTROL_LOST", "PLAYER_CONTROL_GAINED", "TAXIMAP_OPENED", "TAXIMAP_CLOSED", "TAXI_NODE_STATUS_CHANGED",
    "HEARTHSTONE_BOUND", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED", "PLAYER_STARTED_MOVING", "PLAYER_STOPPED_MOVING", "PLAYER_LEVEL_UP", "SPELLS_CHANGED",
    "PLAYER_TALENT_UPDATE", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "PLAYER_MAP_CHANGED",
    "USER_WAYPOINT_UPDATED", "SUPER_TRACKING_CHANGED", "QUEST_ACCEPTED", "QUEST_REMOVED", "CORPSE_OUT_OF_RANGE",
    "ADDON_RESTRICTION_STATE_CHANGED", "GROUP_ROSTER_UPDATE", "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED",
    "MINIMAP_UPDATE_ZOOM", "CONFIRM_SUMMON", "CORPSE_IN_RANGE", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT",
    "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "TRAINER_SHOW", "BARBER_SHOP_OPEN", "PET_STABLE_SHOW", "CONFIRM_BINDER",
    "BATTLEFIELDS_SHOW", "GOSSIP_SHOW", "GOSSIP_CLOSED", "DYNAMIC_GOSSIP_POI_UPDATED",
}

local H = {}
function H.ADDON_LOADED(name) if name == ADDON then Emit("loaded") end end

function H.PLAYER_LOGIN()
    for _, event in ipairs(LATER) do frame:RegisterEvent(event) end
    frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    deadSeen = UnitIsDeadOrGhost("player") == true
    Emit("login")
end

function H.PLAYER_LOGOUT() Emit("logout") end
function H.LOADING_SCREEN_ENABLED()
    M.loading, pewLogin, pewReload, pewDone = true, false, false, false
    Emit("loadStart")
end

function H.PLAYER_ENTERING_WORLD(isLogin, isReload)
    isLogin, isReload = isLogin == true, isReload == true
    -- the screen is still up (it comes down at LOADING_SCREEN_DISABLED): the walking data entered loads behind it
    if M.loading or isLogin or isReload then ns.Env.LoadEntered() end
    if M.loading then
        pewLogin, pewReload = isLogin, isReload
    else
        pewDone = true
        Emit("loadEnd", isLogin, isReload)
    end
end

function H.LOADING_SCREEN_DISABLED()
    if M.loading then
        M.loading, thaw = false, M.carried
        Emit("loadEnd", pewLogin, pewReload)
    elseif pewDone then
        pewDone = false
    else
        Emit("loadEnd", false, false)
    end
end

-- The client sets the taxi flag a moment after the loss of control and clears it a moment after the gain.
local function TookOff(m, x, y)
    onFlight = true
    Emit("tookOff", NearestAnchor(FLIGHT_KINDS, FLIGHT_REACH, m, x, y))
end
local function Look()
    looks = looks - 1
    if looks < 0 or onFlight then return end
    if UnitOnTaxi("player") then return TookOff() end
    if looks > 0 then ns.Env.After(0.25, Look) end
end

function H.PLAYER_CONTROL_LOST()
    if UnitOnTaxi("player") then return TookOff() end
    looks = 4
    ns.Env.After(0.25, Look)
end

function H.PLAYER_CONTROL_GAINED()
    looks = 0
    if onFlight then
        M.held = true
        onFlight = false
        Emit("landed", NearestAnchor(FLIGHT_KINDS, FLIGHT_REACH))
    end
end

function H.UNIT_SPELLCAST_SUCCEEDED(_, _, spellID)
    local Net = ns.Net
    if not issecretvalue(spellID) and type(spellID) == "number" and Net.SpellByID
        and Net.SpellByID(spellID) then
        Emit("cast", spellID)
    end
end

function H.HEARTHSTONE_BOUND() Emit("bound") end
function H.CONFIRM_SUMMON() Emit("summon") end
function H.PLAYER_DEAD() deadSeen = true; Emit("died") end

local function Released() if deadSeen and UnitIsGhost("player") then Emit("ghost") end end
local function Alive()
    if deadSeen and not UnitIsDeadOrGhost("player") then
        deadSeen = false
        Emit("alive")
    elseif deadSeen then
        Released()      -- PLAYER_ALIVE while still a ghost; once more a second on, for a body not given at once
        ns.Env.After(1, Released)
    end
end
H.PLAYER_ALIVE, H.PLAYER_UNGHOST = Alive, Alive
function H.CORPSE_IN_RANGE() Emit("corpseNear") end
function H.CORPSE_OUT_OF_RANGE() Emit("corpseFar") end
-- The body (5.5.14) on the player's map, else its continent's: uiMap, mx, my; nil for none (or one in an instance).
function M.Body()
    local uiMap = C_Map.GetBestMapForUnit("player")
    while uiMap and not issecretvalue(uiMap) do
        local pos = C_DeathInfo.GetCorpseMapPosition(uiMap)
        if pos and not (issecretvalue(pos.x) or issecretvalue(pos.y)) then return uiMap, pos.x, pos.y end
        local info = C_Map.GetMapInfo(uiMap)
        uiMap = info and info.mapType > 2 and info.parentMapID > 0 and info.parentMapID
    end
end

function H.PLAYER_REGEN_DISABLED() Emit("combat", true) end
function H.PLAYER_REGEN_ENABLED() Emit("combat", false) end
function H.TAXIMAP_OPENED()
    taxiDue = true
    ns.Env.After(0, FlushTaxi)
end

function H.TAXIMAP_CLOSED()
    taxiDue = false
    Emit("taxiClosed")
end

function H.TAXI_NODE_STATUS_CHANGED() Emit("taxiNodes") end
local function Zone()
    local t = ns.Env.Now()
    if t ~= zoneTime then
        zoneTime = t
        Emit("zone")
    end
end
H.ZONE_CHANGED_NEW_AREA, H.ZONE_CHANGED, H.ZONE_CHANGED_INDOORS, H.PLAYER_MAP_CHANGED = Zone, Zone, Zone, Zone

function H.PLAYER_STARTED_MOVING() M.moving = true; Emit("moved", true) end
function H.PLAYER_STOPPED_MOVING() M.moving = false; Emit("moved", false) end

local function Pin()
    if not pinDue then
        pinDue = true
        ns.Env.After(0, FlushPin)
    end
end
H.USER_WAYPOINT_UPDATED, H.SUPER_TRACKING_CHANGED = Pin, Pin

function H.QUEST_ACCEPTED(questID) Emit("quest", questID, true) end
function H.QUEST_REMOVED(questID) Emit("quest", questID, false) end
function H.PLAYER_LEVEL_UP(level) Emit("level", level) end
local function Spells()
    if not spellsDue then
        spellsDue = true
        ns.Env.After(0, FlushSpells)
    end
end
H.SPELLS_CHANGED, H.PLAYER_TALENT_UPDATE = Spells, Spells

function H.ADDON_RESTRICTION_STATE_CHANGED() Emit("restricted") end
function H.GROUP_ROSTER_UPDATE() Emit("party") end
function H.PLAYER_TARGET_CHANGED() ns.Seen.Sight("target") end
function H.UPDATE_MOUSEOVER_UNIT() ns.Seen.Sight("mouseover") end
-- A service window: Seen learns who stands there (INTERFACES 5.8); the client still sends these five by themselves.
function H.PLAYER_INTERACTION_MANAGER_FRAME_SHOW(kind) ns.Seen.Window(kind) end
for event, kind in pairs({ TRAINER_SHOW = 7, BARBER_SHOP_OPEN = 62, PET_STABLE_SHOW = 22, CONFIRM_BINDER = 20,
    BATTLEFIELDS_SHOW = 23 }) do
    H[event] = function() ns.Seen.Window(kind, true) end
end
-- A talk window, a guard's answer: Seen keeps the options and reads the point the answer may set.
function H.GOSSIP_SHOW() ns.Seen.Talk() end
function H.GOSSIP_CLOSED() ns.Seen.Talk(true) end
function H.DYNAMIC_GOSSIP_POI_UPDATED() ns.Seen.Guard() end
function H.UI_SCALE_CHANGED() Emit("scale") end
H.DISPLAY_SIZE_CHANGED = H.UI_SCALE_CHANGED
function H.MINIMAP_UPDATE_ZOOM() Emit("minimap") end

local function OnEvent(_, event, ...)
    local fn = H[event]
    if fn then
        local ok, err = pcall(fn, ...)
        if not ok then geterrorhandler()(err) end
    end
end

function M.Start(fn)
    sink = fn
    if not frame then
        frame = CreateFrame("Frame")
        frame:SetScript("OnEvent", OnEvent)
        frame:RegisterEvent("ADDON_LOADED")
        frame:RegisterEvent("PLAYER_LOGIN")
        hooksecurefunc("TakeTaxiNode", Chose)
        hooksecurefunc(C_GossipInfo, "SelectOptionByIndex", function(i) ns.Seen.Chose(i, true) end)
        hooksecurefunc(C_GossipInfo, "SelectOption", function(id) ns.Seen.Chose(id) end)
    end
end

-- Carried motion (INTERFACES 5.3 with 16.2): three swept reads in a row starting near a dock, platform or
-- lift. A read at rest breaks the run, so the single steps seen at portals and at zone-in never add up. The
-- ring keeps the reads of the last second; each step is measured from the previous tick's read, since other
-- callers read the position between ticks.
local RING, GAP, NEAR_WINDOW = 8, 1.5, 45
local rt, rx, ry, rm = {}, {}, {}, {}
for i = 1, RING do rt[i], rx[i], ry[i], rm[i] = -1e9, 0, 0, false end
local head, run, startM, startX, startY, gaveUp, blind = 1, 0, 0, 0, 0, false, false
-- The last anchor in reach of an unswept read: walking on a deck as the vessel gathers speed starts the run
-- out of reach of the dock. Only a run of readable steps on the ground out of a fight is taken for that walk
-- (blind: one was not): a charge, a knockback or a mount with its speed hidden is none.
local checkM, checkX, checkY, checkA, nearA, nearT, nearM = false, 0, 0, 0, 0, -1e9, false
-- The last read at rest that did not move (still counts a deck's first creep): a deck leaving from rest at a
-- steady acceleration left 2 d / v before a read d yards on.
local restM, restX, restY, restT = false, 0, 0, -1e9

local function MovedOverSecond(env, best)
    for i = 1, RING do
        local age = env.now - rt[i]
        if rm[i] == env.landmass and age > 0 and age <= 1.05 then
            local dx, dy = env.x - rx[i], env.y - ry[i]
            local d = math.sqrt(dx * dx + dy * dy)
            if d > best then best = d end
        end
    end
    return best
end

local function Near(env)
    local m, x, y = env.landmass, env.x, env.y
    if m ~= checkM or (x - checkX) ^ 2 + (y - checkY) ^ 2 > 25 then
        checkM, checkX, checkY = m, x, y
        checkA = NearestAnchor(CARRY_KINDS, M.CARRY_REACH, m, x, y)
    end
    if checkA > 0 then nearA, nearT, nearM = checkA, env.now, m end
end

function M.Feed(env, vMax)
    if M.loading then return end
    if env.ok and env.still >= 0.5 and env.moved < 0.05 then restM, restX, restY, restT = env.landmass, env.x, env.y, env.now end
    local was = M.carried
    local left = thaw and startM == ns.Net.TramMap and not (env.ok and env.landmass == startM)    -- no train leaves its map
    thaw = thaw and not (env.ok and env.moved >= STILL and not env.jump)
    local own = was and env.ok and (env.speed or 0) > 0 and not env.jump and env.moved <= 1.5 * math.max(vMax or 0, env.run or 0) * env.dt
    ownT = own and (env.landmass == ns.Net.TramMap or NearestAnchor(CARRY_KINDS, M.CARRY_REACH, env.landmass, env.x, env.y) > 0)
        and (ownT or env.now) or false
    if was and (left or env.taxi or env.dead or (env.ok and env.still >= (thaw and THAW or 1)) or ownT and env.now - ownT >= OWN) then
        M.carried, run, gaveUp, thaw, ownT = false, 0, false, false, false
        Emit("dropped")
    end
    M.held = M.held and env.taxi
    if env.taxi and not (onFlight or M.held) then TookOff(env.landmass, env.x, env.y) end
    if was then return end
    local swept, age, d = false, env.now - rt[head], 0
    local fresh = rm[head] == env.landmass and age > 0 and age <= GAP
    if env.ok and not env.taxi and not env.dead and not env.jump then
        d = fresh and math.sqrt((env.x - rx[head]) ^ 2 + (env.y - ry[head]) ^ 2) or env.moved
        if not fresh then age = env.dt end
        local fast = 1.5 * math.max(vMax or 0, env.run or 0)
        if age <= 0 or age > GAP or d > 500 then
            swept = false
        elseif fast > 0 and d / age > fast then
            swept = true
        elseif (env.speed == 0 or (env.speed == false and not M.moving))
            and d >= STILL and MovedOverSecond(env, d) > 3 then
            swept = true
        end
    end
    if env.ok then
        head = head % RING + 1
        rt[head], rx[head], ry[head], rm[head] = env.now, env.x, env.y, env.landmass
    end
    if not swept then
        if env.ok then Near(env) end
        run, gaveUp = 0, false
        return
    end
    run = run + 1
    blind = run > 1 and blind or env.combat or env.falling or not env.speed
    if run == 1 then
        local last = (head - 2) % RING + 1
        startM, startX, startY = env.landmass, fresh and rx[last] or env.x, fresh and ry[last] or env.y
    end
    if run >= SWEPT_TICKS and not gaveUp then
        local anchor = NearestAnchor(CARRY_KINDS, M.CARRY_REACH, startM, startX, startY)
        if anchor == 0 and not blind and nearM == env.landmass and env.now - nearT <= NEAR_WINDOW then anchor = nearA end
        -- the tram's own map has one line and no other ride: a run from rest there left the nearer platform
        if anchor == 0 and not blind and startM == ns.Net.TramMap and restM == startM and env.now - restT <= 25 then
            anchor = NearestAnchor(TRAM, math.huge, startM, startX, startY)
        end
        if anchor > 0 then
            local r, ago = math.sqrt((env.x - restX) ^ 2 + (env.y - restY) ^ 2), 2 * env.dt
            if restM == env.landmass and env.now - restT <= 25 then ago = math.min(2 * r * age / d, env.now - restT) end
            M.carried = true
            Emit("carried", anchor, ago)
        else
            gaveUp = true
        end
    end
end
