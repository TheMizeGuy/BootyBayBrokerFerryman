local ADDON, ns = ...

-- The loop (INTERFACES 5.5.16, 6.11) on the world map: dots along the whole closed way, under the trip's lines
-- and the side trail's dots, in a pool of lines of its own on MapTrail's frame. It does not subscribe: MapTrail lays
-- it when it draws and when the loop changes, and sets its thickness when a zoom settles.
local M = {}
ns.MapLoop = M

M.LINES = 400           -- dots at most: a longer loop has them farther apart
M.DOT = 3               -- physical pixels a dot is long
M.PITCH = 8             -- physical pixels from the start of one dot to the next, at least
M.PIXELS = 3            -- physical pixels thick
M.ALPHA = 1
M.n = 0                 -- the dots laid

local sqrt, floor, min = math.sqrt, math.floor, math.min
local lines, thickOf, on, made = {}, {}, {}, 0

local function Thickness(thick) return M.PIXELS * thick / ns.MapTrail.PIXELS end

-- A dot from (x1, y1) to (x2, y2) in canvas units, t thick, unless both ends lie past one side of the canvas.
local function Put(f, x1, y1, x2, y2, t, cw, ch)
    local lo, hi = -ns.MapTrail.MARGIN, 1 + ns.MapTrail.MARGIN
    if x1 < lo * cw and x2 < lo * cw or x1 > hi * cw and x2 > hi * cw or y1 < lo * ch and y2 < lo * ch
        or y1 > hi * ch and y2 > hi * ch then return end
    local k = M.n + 1
    M.n = k
    if k > made then
        made = k
        local c, line = ns.MapTrail.COLOR.side, f:CreateLine(nil, "BORDER")
        line:SetColorTexture(1, 1, 1, 1)
        line:SetVertexColor(c[1], c[2], c[3], M.ALPHA)
        lines[k], thickOf[k], on[k] = line, 0, true
    end
    local line = lines[k]
    line:SetStartPoint("TOPLEFT", f, x1, -y1)
    line:SetEndPoint("TOPLEFT", f, x2, -y2)
    if thickOf[k] ~= t then
        line:SetThickness(t)
        thickOf[k] = t
    end
    if not on[k] then
        line:Show()
        on[k] = true
    end
end

-- The loop (3.10's loop, or false) on the map of MapPath's last build, thick the trip's line thickness: a dot every
-- pitch along the whole closed way from its first point, the pitch widened evenly until the loop fits the pool; a
-- point the map cannot place breaks it there. Only on a map that places its points by arithmetic: elsewhere each
-- would cost client calls. Dots not laid are hidden.
function M.Lay(f, loop, thick, cw, ch)
    M.n = 0
    local n, P = loop and loop.n or 0, ns.MapPath
    if n > 0 and P.Arith(loop.landmass, loop.x[1], loop.y[1]) then
        local To, m, x, y, u = P.ToCanvas, loop.landmass, loop.x, loop.y, thick / ns.MapTrail.PIXELS
        local total, ax, ay = 0, To(m, x[n], y[n])
        for i = 1, n do
            local bx, by = To(m, x[i], y[i])
            if ax and bx then total = total + sqrt((bx - ax) ^ 2 + (by - ay) ^ 2) end
            ax, ay = bx, by
        end
        local k = min(floor(total / (M.PITCH * u)), M.LINES)
        if k > 0 then
            local pitch, len, t = total / k, M.DOT * u, Thickness(thick)
            -- d: the way from point 1 to the next dot's start, or to its end once (x1, y1) is that start; e: to point i
            local d, e, dots, x1, y1 = 0, 0, 0, false, 0
            ax, ay = To(m, x[1], y[1])
            for i = 2, n + 1 do
                local j = i > n and 1 or i
                local bx, by = To(m, x[j], y[j])
                if ax and bx then
                    local dx, dy = bx - ax, by - ay
                    local l = sqrt(dx * dx + dy * dy)
                    while dots < k and d <= e + l do
                        local s = l > 0 and (d - e) / l or 0
                        if x1 then
                            Put(f, x1, y1, ax + dx * s, ay + dy * s, t, cw, ch)
                            x1, dots, d = false, dots + 1, d - len + pitch
                        else
                            x1, y1, d = ax + dx * s, ay + dy * s, d + len
                        end
                    end
                    e = e + l
                elseif x1 then
                    x1, d = false, e        -- a dot begun before a break begins again after it
                end
                ax, ay = bx, by
            end
        end
    end
    for k = M.n + 1, made do
        if on[k] then
            lines[k]:Hide()
            on[k] = false
        end
    end
end

-- MapTrail's settling: dot k at the trip's line thickness thick; 1 when it called the client.
function M.Thick(k, thick)
    local t = Thickness(thick)
    if thickOf[k] == t then return 0 end
    lines[k]:SetThickness(t)
    thickOf[k] = t
    return 1
end
