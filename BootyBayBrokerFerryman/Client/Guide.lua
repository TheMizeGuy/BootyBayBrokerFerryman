local ADDON, ns = ...

-- Following RestedXP (INTERFACES 5.5.10): the target of its arrow becomes a quiet destination. RestedXP's frame
-- is read on the frame after each assignment of its arrow; nothing of it is written but the two post-hooks and
-- three on its window's Show, Hide and SetShown. Its window closed, nothing of it is followed.
local M = {}
ns.Guide = M

M.SOURCE, M.HOLD, M.SAME = "guide", 1.5, 0.0005
M.present = false       -- RestedXP's arrow was there at login

local abs, max, huge = math.abs, math.max, math.huge
local Env, Lead, Driver = ns.Env, ns.Lead, ns.Driver
local arrow, window, soon, later, was = false, false, false, false, false
local gMap, gX, gY = -1, 0, 0               -- the target given: -1 none yet, false "no target"
local cMap, cX, cY, cT = -1, 0, 0, 0        -- the target waiting out the hold, since cT
local dismissed, lastGo = false, -huge      -- the step the player ended a trip on; the last Driver.Go
local wMap, wX, wY, wOk = false, 0, 0, false    -- the last place whose world was looked up

local function Same(m1, x1, y1, m2, x2, y2)
    return m1 == m2 and (not m1 or abs(x1 - x2) <= M.SAME and abs(y1 - y2) <= M.SAME)
end

-- RestedXP's own rule for an arrow target, on a landmass with walking data: uiMap, mx, my and its step; or false.
local function Target(e)
    if type(e) ~= "table" then return false end
    local step, parent, map, x, y = e.step, e.parent, e.zone, e.x, e.y
    if not e.arrow or e.generated or e.skip or e.hidden or (e.completed and e.text) or type(step) ~= "table"
        or not step.active or type(parent) == "table" and (parent.completed or parent.skip)
        or type(map) ~= "number" or type(x) ~= "number" or type(y) ~= "number"
        or x < 0 or x > 100 or y < 0 or y > 100 then return false end
    if map ~= wMap or x ~= wX or y ~= wY then
        local m = Env.MapToWorld(map, x / 100, y / 100)
        wMap, wX, wY, wOk = map, x, y, m ~= nil and Env.HasCompanion(m)
    end
    if not wOk then return false end
    return map, x / 100, y / 100, step
end

-- Within the arrival distance of the player, on the same landmass.
local function Near(snap, map, mx, my)
    local m, x, y = Env.MapToWorld(map, mx, my)
    local pm, px, py = Env.Position()
    return m ~= nil and m == pm and (x - px) ^ 2 + (y - py) ^ 2 <= snap.options.arriveYards ^ 2
end

local Look
local function Later() later = false Look() end
-- One timer at a time for each: the next frame's look, and the end of a wait.
local function Wait(seconds) if not later then later = true Env.After(seconds, Later) end end
local function Soon() if not soon then soon = true Env.After(0, Look) end end

-- The look: its order fixes every rule's precedence (5.5.10).
Look = function()
    soon = false
    local snap = Driver.Snapshot()
    local dest, on = snap.dest, snap.options.followGuide and snap.options.planner
    local mine = dest and dest.source == M.SOURCE
    local shown = on and arrow:IsShown() == true
    if shown ~= snap.guideArrow then
        snap.guideArrow = shown
        if mine or dest and dest.kind == "corpse" then Lead.Mark("notice") Lead.Flush() end
    end
    if mine and (not on or snap.state == "failed") then return Driver.Stop(M.SOURCE) end
    if dest and not mine then gMap, cMap = -1, -1 return end
    if not on or snap.combat or snap.state == "riding" then return end
    if not window and type(RXPFrame) == "table" and type(RXPFrame.IsShown) == "function" then window = RXPFrame
        for _, k in ipairs({ "Show", "Hide", "SetShown" }) do pcall(hooksecurefunc, window, k, Soon) end end
    local map, mx, my, step = Target(arrow.element)
    if window and not window:IsShown() then     -- closed: ended at once, its target the candidate for when it opens
        if not Same(map, mx, my, cMap, cX, cY) then cMap, cX, cY, cT = map, mx, my, Env.Now() end
        gMap = false return mine and Driver.Stop(M.SOURCE)
    end
    if step and step == dismissed or Same(map, mx, my, gMap, gX, gY) then cMap = -1 return end
    if mine and Same(map, mx, my, dest.uiMap, dest.mx, dest.my) then gMap, gX, gY = map, mx, my return end
    local now = Env.Now()
    if not Same(map, mx, my, cMap, cX, cY) then
        cMap, cX, cY, cT = map, mx, my, now
        return Wait(M.HOLD)
    end
    local wait = max(cT + M.HOLD, lastGo + Driver.REPLAN_GAP) - now
    if wait > 0 then return Wait(wait) end
    gMap, gX, gY, cMap, dismissed = map, mx, my, -1, false
    if not map or Near(snap, map, mx, my) then return mine and Driver.Stop(M.SOURCE) end
    lastGo = now
    if not Driver.Go("point", 0, map, mx, my, nil, M.SOURCE) and mine then Driver.Stop(M.SOURCE) end
end

-- After a "state" or "option" publish: the hooks go in once the option is on; turned on, it forgets what was
-- given and dismissed.
function M.OnChange(snapshot, what)
    if what ~= "state" and what ~= "option" then return end
    local on = snapshot.options.followGuide and snapshot.options.planner
    if on and not arrow then
        arrow = RXPG_ARROW
        hooksecurefunc(arrow, "SetShown", Soon)
        hooksecurefunc(arrow, "Hide", Soon)
    end
    if on and not was then gMap, cMap, dismissed = -1, -1, false end
    was = on
    Soon()
end
function M.Active() local o = Driver.Snapshot().options return M.present and o.followGuide == true and o.planner == true end
function M.Login()
    local a = type(RXPG_ARROW) == "table" and RXPG_ARROW
    M.present = a and type(a.SetShown) == "function" and type(a.Hide) == "function" and type(a.IsShown) == "function"
        or false
    if M.present then Driver.Subscribe(M.OnChange) end
end
-- The player ended a trip (Driver.Stop "hand"): the step RestedXP shows now is not followed (G6).
function M.Stopped()
    local e = arrow and arrow.element
    dismissed = type(e) == "table" and e.step or false
end
