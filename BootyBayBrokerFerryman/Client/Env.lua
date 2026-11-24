local ADDON, ns = ...

-- The one reader of where the player is and what the client says about maps, names, speed, casts and the
-- map pin. It keeps no trip state.
local M = {}
ns.Env = M

local sqrt, abs = math.sqrt, math.abs
local now = { ok = false, landmass = 0, x = 0, y = 0, z = false, uiMap = false, indoors = false, taxi = false,
    dead = false, swimming = false, falling = false, flying = false, mounted = false, instance = false,
    instanceMap = 0, combat = false, now = 0, dt = 0, moved = 0, jump = false, still = 0, speed = false,
    run = false, swimSpeed = false, ghost = false }
M.now = now

local function Hidden(v) return issecretvalue(v) or v == nil end
local function Text(s) if not Hidden(s) and s ~= "" then return s end end
local function Guard(fn) local ok, err = pcall(fn); if not ok then geterrorhandler()(err) end end

-- Server time: one GetServerTime anchor plus the GetTime elapsed since, re-anchored when they drift apart.
local baseServer, baseTime = false, 0
function M.Now()
    local t, s = GetTime(), GetServerTime()
    if not baseServer or abs(baseServer + (t - baseTime) - s) > 1.5 then baseServer, baseTime = s, t end
    return baseServer + (t - baseTime)
end

local lastT, lastOk, lastMass, lastX, lastY, okMass = false, false, 0, 0, 0, false
local restX, restY = 0, 0       -- where the position came to rest: still counts while it stays within half a yard
function M.Read()
    local t = GetTime()
    now.dt = lastT and t - lastT or 0
    lastT, now.now = t, M.Now()
    local x, y, _, m = UnitPosition("player")
    local ok = not (Hidden(x) or Hidden(y) or Hidden(m))
    local moved, jump = 0, false
    if ok then
        now.landmass, now.x, now.y = m, x, y
        if lastOk and lastMass == m then moved = sqrt((x - lastX) ^ 2 + (y - lastY) ^ 2) end
        jump = (okMass ~= false and okMass ~= m) or (moved > 500 and moved > now.dt * 100)
        okMass, lastMass, lastX, lastY = m, m, x, y
    end
    now.ok, lastOk, now.moved, now.jump = ok, ok, moved, jump
    if ok and not jump and (x - restX) ^ 2 + (y - restY) ^ 2 < 0.25 then
        now.still = now.still + now.dt
    else
        now.still = 0
        if ok then restX, restY = x, y end
    end
    local uiMap = C_Map.GetBestMapForUnit("player")
    now.uiMap = not Hidden(uiMap) and uiMap or false
    now.indoors, now.taxi = IsIndoors() == true, UnitOnTaxi("player") == true
    now.dead, now.ghost, now.swimming = UnitIsDeadOrGhost("player") == true, UnitIsGhost("player") == true, IsSwimming() == true
    now.falling, now.flying, now.mounted = IsFalling() == true, IsFlying() == true, IsMounted() == true
    now.instance = IsInInstance() == true
    local im = now.instance and select(8, GetInstanceInfo()) or 0
    now.instanceMap = not Hidden(im) and im or 0
    now.combat = InCombatLockdown() == true
    local speed, run, _, swim = GetUnitSpeed("player")
    if C_Secrets.ShouldUnitStatsBeSecret() then speed, run, swim = nil, nil, nil end
    now.speed, now.run = not Hidden(speed) and speed or false, not Hidden(run) and run or false
    now.swimSpeed = not Hidden(swim) and swim or false
    return now
end

function M.Position()
    local x, y, _, m = UnitPosition("player")
    if not (Hidden(x) or Hidden(y) or Hidden(m)) then return m, x, y end
end
function M.Facing() local f = GetPlayerFacing(); if not Hidden(f) then return f end end

local FACTION = { Alliance = 1, Horde = 2 }
-- The realm is the id the player GUID carries; GetRealmID's, unless it answers nothing, where there is none (132).
local realmKey, realmOf = false, 0
function M.Character()
    local guid = UnitGUID("player"); if Hidden(guid) then guid = false end
    if guid ~= realmOf then
        local id, r = guid and string.match(guid, "^Player%-(%d+)%-"), GetRealmID()
        realmOf, realmKey = guid, id or (Hidden(r) or r == 0) and (realmKey or "0") or tostring(r)
    end
    local f, level, class = UnitFactionGroup("player"), UnitLevel("player"), UnitClassBase("player")
    return guid, realmKey, not Hidden(f) and FACTION[f] or 0,
        not Hidden(level) and level or 0, not Hidden(class) and class or false
end
function M.Build() local version, build = GetBuildInfo(); return version .. "." .. build end

-- Map conversion: one reused vector for the client's calls, one rectangle per map for arithmetic.
local vec
local function Vec(x, y) vec = vec or CreateVector2D(0, 0); vec:SetXY(x, y); return vec end
function M.MapToWorld(uiMap, mx, my)
    if type(uiMap) ~= "number" then return nil end
    local m, pos = C_Map.GetWorldPosFromMapPos(uiMap, Vec(mx, my))
    if m and pos then
        local x, y = pos.x, pos.y
        return m, x, y
    end
end
local rects = {}
function M.MapRect(uiMap)
    local r = rects[uiMap]
    if r == nil then
        local m, xTop, yLeft = M.MapToWorld(uiMap, 0, 0)
        local m2, xBottom, yRight = M.MapToWorld(uiMap, 1, 1)
        r = m and m == m2 and xTop ~= xBottom and yLeft ~= yRight and { m, xTop, yLeft, xBottom, yRight } or false
        rects[uiMap] = r
    end
    if r then return r[1], r[2], r[3], r[4], r[5] end
end
function M.WorldToMap(uiMap, landmass, x, y)
    local m, xTop, yLeft, xBottom, yRight = M.MapRect(uiMap)
    local mx, my
    if m == landmass then
        mx, my = (yLeft - y) / (yLeft - yRight), (xTop - x) / (xTop - xBottom)
    else
        local id, pos = C_Map.GetMapPosFromWorldPos(landmass, Vec(x, y), uiMap)
        if id ~= uiMap or not pos then return nil end
        mx, my = pos.x, pos.y
    end
    if mx >= 0 and mx <= 1 and my >= 0 and my <= 1 then return mx, my end
end

local function Continent(uiMap)
    local info = C_Map.GetMapInfo(uiMap)
    while info and info.mapType ~= 2 do info = info.parentMapID and C_Map.GetMapInfo(info.parentMapID) end
    return info and info.mapID
end
local continents = {}
function M.ZoneAt(landmass, x, y)
    local id = C_Map.GetMapPosFromWorldPos(landmass, Vec(x, y))
    if not id then return nil end
    local cont = continents[landmass]
    if cont == nil then
        cont = Continent(id) or false
        continents[landmass] = cont
    end
    local mx, my
    if cont then mx, my = M.WorldToMap(cont, landmass, x, y) end
    local info = mx and C_Map.GetMapInfoAtPosition(cont, mx, my)
    return info and info.mapID or id
end

function M.MapName(uiMap)
    local info = uiMap and C_Map.GetMapInfo(uiMap)
    return info and Text(info.name)
end
function M.AreaName(areaID) if areaID and areaID ~= 0 then return Text(C_Map.GetAreaInfo(areaID)) end end
function M.InstanceName(instanceMap) return Text(GetRealZoneText(instanceMap)) end
local function ZoneName(landmass, x, y)
    local zone = landmass and M.ZoneAt(landmass, x, y)
    return zone and M.MapName(zone)
end
local massNames = {}
function M.LandmassName(landmass)
    local name = massNames[landmass]
    if name == nil then
        name = false
        local Net = ns.Net
        for a = 1, Net.A or 0 do
            local m, x, y = Net.Anchor(a)
            if m == landmass then
                local zone = M.ZoneAt(m, x, y)
                local cont = zone and Continent(zone)
                name = cont and M.MapName(cont) or false
                break
            end
        end
        massNames[landmass] = name
    end
    return name or nil
end

-- A flight master is named by the client once its window has shown it; a dock whose area is water or a
-- whole zone takes a town point's name: a city's (AreaPOI icon 5) before a town's (4), then the nearest.
local nodeNames, stopNames, PLACE_NEAR, RANK = {}, {}, 600, { [5] = 1, [4] = 2 }
local function StopName(i)
    local Net = ns.Net
    local kind, m, x, y, _, _, ref, area = Net.Stop(i)
    if kind == 1 then return nodeNames[ref] or M.AreaName(area) or ZoneName(m, x, y) end
    local name = stopNames[i]
    if name == nil then
        name = M.AreaName(area) or false
        local best, bestR, bestD, same = false, 4, PLACE_NEAR, false
        for k = 1, kind == 2 and Net.PlaceCount or 0 do
            local pa, pm, px, py, icon, english = Net.Place(k)
            local d = pm == m and sqrt((px - x) ^ 2 + (py - y) ^ 2) or PLACE_NEAR + 1
            local pname, r = d <= PLACE_NEAR and (M.AreaName(pa) or english), RANK[icon] or 3
            same = same or (pname and pname == name)
            if pname and (r < bestR or (r == bestR and d <= bestD)) then best, bestR, bestD = pname, r, d end
        end
        if not same and best then name = best end
        name = name or ZoneName(m, x, y) or false
        stopNames[i] = name
    end
    return name or nil
end
function M.PlaceName(ref, title)
    local name, a = nil, ref.anchor or 0
    if ref.kind == "goal" then
        name = Text(title)
    elseif ref.kind == "stop" and a > 0 then
        name = StopName(a)
    elseif ref.kind == "landing" then
        local Ledger = ns.Ledger
        local know = Ledger.Knowledge and Ledger.Knowledge()
        local bind = know and know.bind
        if ref.key == "bind" or (bind and bind.landmass == ref.landmass and bind.x == ref.x and bind.y == ref.y) then
            name = Text(M.BindName())
        end
    end
    name = name or ZoneName(ref.landmass, ref.x, ref.y)
    if not name and a > 0 then name = ns.Net.EnglishName(a) end
    return name or ""
end

local mapNames
local function MapNames()
    if not mapNames then
        mapNames = {}
        for _, info in ipairs(C_Map.GetMapChildrenInfo(947, nil, true) or {}) do
            if Text(info.name) then mapNames[#mapNames + 1] = { info.name, info.mapID } end
        end
        table.sort(mapNames, function(p, q)
            if #p[1] ~= #q[1] then return #p[1] > #q[1] end
            return p[2] < q[2]
        end)
    end
    return mapNames
end
-- Case is folded by the client's UTF-8 aware compare: string.lower changes ASCII only.
function M.FindMap(text)
    for _, e in ipairs(MapNames()) do
        local name = e[1]
        local after = text:sub(#name + 1, #name + 1)
        if (after == "" or after == " " or after == ",") and strcmputf8i(text:sub(1, #name), name) == 0 then
            return e[2], (text:sub(#name + 1):gsub("^[%s,]+", ""))
        end
    end
    local words, rest = text:match("^([^%d]-)%s*(%d.*)$")
    words, rest = (words or text):gsub("^%s+", ""):gsub("[%s,]+$", ""), rest or ""
    if words == "" then return nil end
    local found
    for _, e in ipairs(MapNames()) do
        if strcmputf8i(e[1]:sub(1, #words), words) == 0 then
            if found then return nil end
            found = e[2]
        end
    end
    if found then return found, text:sub(#text - #rest + 1) end
end

-- The client reports whichever of the own and the global cooldown ends later, so a cooldown no longer than
-- the global one is not the spell's own. A hidden cooldown counts as the last one that could be read.
local spellBusy, itemBusy, NONE, GCD = {}, {}, {}, 1.5
local function SpellCooling(id)
    local cd = C_Spell.GetSpellCooldown(id)
    local active, duration = cd and cd.isActive, cd and cd.duration
    if not Hidden(active) and (active ~= true or not Hidden(duration)) then
        spellBusy[id] = active == true and duration > GCD
    end
    return spellBusy[id] == true
end
local function ItemCooling(id)
    local start, duration = C_Item.GetItemCooldown(id)
    if not Hidden(start) and not Hidden(duration) then
        itemBusy[id] = duration > GCD and start + duration > GetTime()
    end
    return itemBusy[id] == true
end
local function Count(id)
    local n = C_Item.GetItemCount(id)
    return not Hidden(n) and n or 0
end
-- A spell bound to areas (SpellCastingRequirements) is cast only in a zone or subzone of that name.
local function InAreas(areas)
    local zone, sub = Text(GetRealZoneText()), Text(GetSubZoneText())
    for k = 1, #areas do
        local name = M.AreaName(areas[k])
        if name and (name == zone or name == sub) then return true end
    end
    return false
end
function M.CastReady(spell)
    if InCombatLockdown() or (spell.areas and not InAreas(spell.areas)) then return false, 0 end
    if C_SpellBook.IsSpellKnown(spell.spell) and not SpellCooling(spell.spell)
        and (not spell.reagent or Count(spell.reagent) >= (spell.reagentCount or 1)) then
        return true, 0
    end
    local level = UnitLevel("player")
    level = not Hidden(level) and level or 0
    for _, item in ipairs(spell.items or NONE) do
        if Count(item[1]) > 0 and not ItemCooling(item[1]) and level >= (item[4] or 0) then return true, item[1] end
    end
    return false, 0
end

function M.BindName() return Text(GetBindLocation()) or "" end
function M.SubZone() return Text(GetSubZoneText()) or "" end
function M.FlightBonus()
    local Net, sum = ns.Net, 0
    for k = 1, Net.FlightBonusCount or 0 do
        local spell, bonus = Net.FlightBonus(k)
        if C_SpellBook.IsSpellKnown(spell) then sum = sum + bonus end
    end
    return sum
end

-- The game's map pin. Ferryman remembers the one point it wrote, so it never clears a pin it did not set.
function M.Pin()
    local wp = C_Map.GetUserWaypoint()
    if not (wp and wp.position) then return nil end
    local mx, my = wp.position.x, wp.position.y
    return wp.uiMapID, mx, my, C_SuperTrack.IsSuperTrackingUserWaypoint() == true
end
function M.PinSupported()
    local uiMap = C_Map.GetBestMapForUnit("player")
    local rule = Enum.GameRule and Enum.GameRule.WorldMapTrackingPinDisabled
    return not Hidden(uiMap) and C_Map.CanSetUserWaypointOnMap(uiMap) == true
        and not (rule and C_GameRules.IsGameRuleActive(rule))
end
local ourMap, ourX, ourY = false, 0, 0
function M.WritePin(uiMap, mx, my)
    if not C_Map.CanSetUserWaypointOnMap(uiMap) then return false end
    ourMap, ourX, ourY = uiMap, mx, my
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(uiMap, mx, my))
    return true
end
function M.PinIsOurs()
    local uiMap, mx, my = M.Pin()
    return uiMap ~= nil and uiMap == ourMap and abs(mx - ourX) <= 0.0005 and abs(my - ourY) <= 0.0005
end
function M.ClearPin() if M.PinIsOurs() then C_Map.ClearUserWaypoint() end end

function M.Quest()
    local id = C_SuperTrack.GetSuperTrackedQuestID()
    if Hidden(id) or id == 0 then id = C_QuestLog.GetQuestIDForQuestWatchIndex(1) end
    if not Hidden(id) and id ~= 0 then return id end
end
local function OnMapOf(uiMap, questID)
    for _, q in ipairs(C_QuestLog.GetQuestsOnMap(uiMap) or {}) do
        if q.questID == questID then return uiMap, q.x, q.y end
    end
end
function M.QuestPlace(questID)
    local uiMap, mx, my = C_QuestLog.GetNextWaypoint(questID)
    if uiMap and mx and my then return uiMap, mx, my end
    local here = C_Map.GetBestMapForUnit("player")
    if Hidden(here) then return nil end
    local a, b, c = OnMapOf(here, questID)
    local cont = Continent(here)
    for _, info in ipairs(not a and cont and C_Map.GetMapChildrenInfo(cont, 3, true) or {}) do
        a, b, c = OnMapOf(info.mapID, questID)
        if a then break end
    end
    return a, b, c
end
function M.QuestTitle(questID) return Text(C_QuestLog.GetTitleForQuestID(questID)) or "" end

local PARTY = { "party1", "party2", "party3", "party4" }
function M.Party(i)
    local unit = PARTY[i]
    local name = unit and UnitName(unit)
    if not issecretvalue(name) and not name then return nil end
    local x, y, _, m = UnitPosition(unit)
    if Hidden(x) or Hidden(y) or Hidden(m) then
        local here = C_Map.GetBestMapForUnit("player")
        local pos = not Hidden(here) and C_Map.GetPlayerMapPosition(here, unit)
        if not pos then return nil end
        m, x, y = M.MapToWorld(here, pos.x, pos.y)
        if not m then return nil end
    end
    return not issecretvalue(name) and name or false, m, x, y
end

-- The flight window: nodes in world coordinates, from the documented list or else the legacy functions.
local STATE, LEGACY = { [0] = "current", [1] = "reachable" }, { CURRENT = "current", REACHABLE = "reachable" }
local function Node(out, i, node, slot, state, uiMap, mx, my)
    local rec = out[i] or {}
    out[i] = rec
    local m, x, y = M.MapToWorld(uiMap, mx, my)
    rec.node, rec.slot, rec.state, rec.landmass, rec.x, rec.y = node, slot, state, m or false, x or 0, y or 0
end
function M.ReadTaxi(out)
    local uiMap, n = GetTaxiMapID(), 0
    for _, info in ipairs(not issecretvalue(uiMap) and uiMap and C_TaxiMap.GetAllTaxiNodes(uiMap) or {}) do
        local id, slot, state, p = info.nodeID, info.slotIndex, info.state, info.position
        if issecretvalue(id) or Hidden(slot) or issecretvalue(state) or Hidden(p) or Hidden(p.x) or Hidden(p.y) then return 0 end
        n = n + 1
        Node(out, n, id or 0, slot, STATE[state] or "other", uiMap, p.x, p.y)
        if id and Text(info.name) then nodeNames[id] = info.name end
    end
    local count = n == 0 and not issecretvalue(uiMap) and NumTaxiNodes() or 0
    for slot = 1, not issecretvalue(count) and count or 0 do
        local kind, mx, my = TaxiNodeGetType(slot), TaxiNodePosition(slot)
        if issecretvalue(kind) or issecretvalue(mx) or issecretvalue(my) then return 0 end
        if mx then n = n + 1; Node(out, n, 0, slot, LEGACY[kind] or "other", uiMap, mx, my) end
    end
    return n, uiMap
end
function M.TaxiHops(slot, out)
    local n = GetNumRoutes(slot)
    if Hidden(n) or n <= 0 then return 0 end
    for hop = 0, n do out[hop + 1] = TaxiGetNodeSlot(slot, hop == 0 and 1 or hop, hop == 0) end
    for hop = 1, n + 1 do if issecretvalue(out[hop]) then return 0 end end
    return n
end

function M.MinimapRadius() return C_Minimap.GetViewRadius() end
function M.MinimapRotates() return GetCVarBool("rotateMinimap") == true and not C_Minimap.IsRotateMinimapIgnored() end
function M.MinimapSquare() return type(GetMinimapShape) == "function" and GetMinimapShape() == "SQUARE" end
function M.After(seconds, fn) C_Timer.After(seconds, function() Guard(fn) end) end
function M.Sound(kit) PlaySound(kit) end
function M.Secure(tbl, key) if type(issecurevariable) == "function" then return (issecurevariable(tbl, key)) end end
-- Walking data: a load-on-demand companion per landmass (INTERFACES 16.7), loaded behind the loading screen that
-- enters it (LoadEntered), else when a trip first needs it. A load that fails in a fight is asked again (the next
-- request, the first tick after it: GroundRetry); a missing or disabled companion stays refused, until a reload or
-- until its data arrives another way (the AddOn list's Load); data that Ground does not take (another version) is
-- refused too. Attached data changes the landings. took: the milliseconds each landmass's load took.
local GROUND, refused, retry, tried, took = { [0] = "_EasternKingdoms", [1] = "_Kalimdor" }, {}, false, {}, {}
function M.LoadGround(m)
    local G, d = ns.Ground, ns.WalkData[m]
    if G.Has(m) or not GROUND[m] or refused[m] and (not d or tried[m] == d) then return G.Has(m) end
    local t, why = debugprofilestop(), not d and select(2, C_AddOns.LoadAddOn(ADDON .. GROUND[m])) or nil
    tried[m] = ns.WalkData[m]
    local _, err = G.Load(m)
    if err then geterrorhandler()(err) end
    if G.Has(m) then refused[m], took[m] = nil, debugprofilestop() - t; return ns.Ledger.GroundAttached() end
    if InCombatLockdown() and why ~= "MISSING" and why ~= "DISABLED" then retry = true
    else refused[m] = why or tried[m] and "VERSION" or "MISSING" end
    return false
end
-- At PLAYER_ENTERING_WORLD the world's map id names the landmass entered; a position may still be frozen, absent
-- or a deck's (16.1). An instance's id has no companion. Guarded: the event's facts follow whatever happens here.
local function Entered() local m = select(8, GetInstanceInfo()); if not Hidden(m) then M.LoadGround(m) end end
function M.LoadEntered() Guard(Entered) end
function M.GroundMs(m) return took[m] end
function M.GroundRetry() local was = retry; retry = false; return was end
function M.GroundRefused(m) return refused[m] ~= nil end
function M.HasCompanion(m) return GROUND[m] ~= nil end
function M.GroundOffered() return not (refused[0] and refused[1]) end
function M.Metric(name) return C_AddOnProfiler.GetAddOnMetric(ADDON, Enum.AddOnProfilerMetric[name]) end
function M.Check()
    local uiMap = C_Map.GetBestMapForUnit("player")
    local m, x, y = M.Position()
    local mx, my
    if m and not Hidden(uiMap) then mx, my = M.WorldToMap(uiMap, m, x, y) end
    local pos = mx and C_Map.GetPlayerMapPosition(uiMap, "player")
    if not pos then return false, "CHECK_COORDS_NONE" end
    local px, py = pos.x, pos.y
    local ok = abs(mx - px) <= 0.002 and abs(my - py) <= 0.002
    return ok, ok and "CHECK_COORDS_OK" or "CHECK_COORDS_BAD"
end
