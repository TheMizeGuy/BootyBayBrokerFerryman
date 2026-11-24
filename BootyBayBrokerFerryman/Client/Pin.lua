local ADDON, ns = ...

-- The game's own map pin (INTERFACES 5.5.9). Following: a pin the player places becomes a destination.
-- Driving: Ferryman points the pin at each step of a trip and puts the player's own back afterwards. The
-- two never feed each other: a pin Ferryman wrote is never followed, and a pin trip is never driven. The
-- client places a pin untracked, so a pin is followed when it is placed or moved, or when it is tracked.
local M = {}
ns.Pin = M

M.driving = false       -- Ferryman is writing the pin for the trip on screen
M.offer = false         -- a new pin waits behind the notice "Go to the new map pin"

local abs = math.abs
local stopped, saved, back, sMap, sX, sY = false, false, false, 0, 0, 0     -- back: the player's pin is put back
local seenMap, seenX, seenY, seenTracked = false, 0, 0, false             -- the player's pin as last seen

local function Same(m1, x1, y1, m2, x2, y2)
    return m1 == m2 and abs(x1 - x2) <= 0.0005 and abs(y1 - y2) <= 0.0005
end
-- Ferryman's own pin. Env remembers the player's pin put back as written by Ferryman; it is theirs.
local function Ours()
    local E = ns.Env
    if not E.PinIsOurs() then return false end
    local uiMap, mx, my = E.Pin()
    return not (back and Same(uiMap, mx, my, sMap, sX, sY))
end
-- The pin there now counts as seen: only one placed, moved or tracked after this is followed.
function M.Seen()
    local uiMap, mx, my, tracked = ns.Env.Pin()
    seenMap, seenX, seenY, seenTracked = uiMap or false, mx, my, tracked
end

-- What a change of the pin asks of the Driver: "go", "clear", "notice" (the offer changed) or nil.
function M.Changed(dest)
    local E, was = ns.Env, M.offer
    if Ours() then return nil end
    if M.driving then M.driving, stopped, saved = false, true, false end
    local uiMap, mx, my, tracked = E.Pin()
    local first = uiMap and not (seenMap and Same(uiMap, mx, my, seenMap, seenX, seenY))
    local new = first or tracked and not seenTracked
    M.Seen()
    if first and tracked and ns.Guide.Active() then return nil end   -- RestedXP's own pin, set and tracked at once
    local o = ns.Ledger.Options()
    if not (uiMap and o.followPin and o.planner and E.PinSupported()) then
        M.offer = false
        return not uiMap and dest and dest.kind == "pin" and "clear" or was and "notice" or nil
    end
    if not new or dest and dest.kind == "pin" and Same(uiMap, mx, my, dest.uiMap, dest.mx, dest.my) then return nil end
    if not dest or dest.kind == "pin" or dest.source == "guide" then return "go" end
    M.offer = true
    return not was and "notice" or nil
end

-- A trip is adopted: driving begins unless another writer stopped it, and the player's own pin is kept.
function M.Adopt(dest)
    local E = ns.Env
    if M.driving or stopped or dest.kind == "pin" or dest.kind == "corpse" or not (ns.Ledger.Options().drivePin and E.PinSupported()) then
        return
    end
    local uiMap, mx, my = E.Pin()
    M.driving, saved = true, uiMap ~= nil and not Ours()
    if saved then sMap, sX, sY = uiMap, mx, my end
end

-- The pin goes to where the leg is boarded or, for a walk, where it ends; never over another writer's pin.
function M.Enter(leg)
    local E = ns.Env
    local pin, px, py = E.Pin()
    local taken = pin and not Ours() and not (saved and Same(pin, px, py, sMap, sX, sY))
    if not M.driving or taken then return end
    local at = leg.kind == "walk" and leg.to or leg.from
    local uiMap = E.ZoneAt(at.landmass, at.x, at.y)
    local mx, my
    if uiMap then mx, my = E.WorldToMap(uiMap, at.landmass, at.x, at.y) end
    if mx and E.WritePin(uiMap, mx, my) then back = false end
end

-- The trip ended: Ferryman's pin goes and the player's own comes back.
function M.End()
    local E = ns.Env
    if M.driving then
        E.ClearPin()
        if saved then back = E.WritePin(sMap, sX, sY) end
        M.Seen()
    end
    M.driving, M.offer, stopped, saved = false, false, false, false
end
