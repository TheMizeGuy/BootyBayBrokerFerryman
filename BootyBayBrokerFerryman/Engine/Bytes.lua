local ADDON, ns = ...

-- Readers over the strings the data ships as (tools/network/FORMAT.md and the walking data's binary fields).
local M = {}
ns.Bytes = M

local byte = string.byte

-- Unsigned base-91 field of w digits (1 to 4), most significant first; the alphabet skips the backslash.
function M.U(s, o, w)
    local v = 0
    for k = o, o + w - 1 do
        local b = byte(s, k)
        if b > 92 then
            v = v * 91 + b - 36
        else
            v = v * 91 + b - 35
        end
    end
    return v
end

local U = M.U

function M.C(s, o)
    return (U(s, o, 3) - 376785) / 10
end

function M.Count(s, width)
    local n = #s / width
    if n ~= n - n % 1 then
        error("Bytes.Count: " .. #s .. " % " .. width, 2)
    end
    return n
end

-- Runs of varints {map, count, x1, y1, dx2, dy2, ...}; coordinates zigzag coded, in multiples of quantum.
function M.Shape(s, quantum, out)
    local map, first, count, X, Y = out.map, out.first, out.count, out.x, out.y
    if not map then
        map, first, count, X, Y = {}, {}, {}, {}, {}
        out.map, out.first, out.count, out.x, out.y = map, first, count, X, Y
    end
    local runs, points, step, left, x, y = 0, 0, 0, 0, 0, 0
    local value, scale = 0, 1
    for k = 1, #s do
        local d = byte(s, k)
        if d > 92 then d = d - 36 else d = d - 35 end
        if d >= 45 then
            value = value + (d - 45) * scale
            scale = scale * 45
        else
            local v = value + d * scale
            value, scale = 0, 1
            if step == 0 then
                runs = runs + 1
                map[runs], first[runs], count[runs] = v, points + 1, 0
                step = 1
            elseif step == 1 then
                count[runs], left, x, y = v, v, 0, 0
                step = v > 0 and 2 or 0
            else
                if v % 2 == 0 then v = v / 2 else v = -(v + 1) / 2 end
                if step == 2 then
                    x, step = x + v, 3
                else
                    y = y + v
                    points = points + 1
                    X[points], Y[points] = x * quantum, y * quantum
                    left = left - 1
                    step = left > 0 and 2 or 0
                end
            end
        end
    end
    return runs, points
end

-- Little-endian binary fields of the walking data.
function M.u8(s, o)
    return byte(s, o) + 0
end

function M.u16(s, o)
    local a, b = byte(s, o, o + 1)
    return a + b * 256
end

function M.u24(s, o)
    local a, b, c = byte(s, o, o + 2)
    return a + b * 256 + c * 65536
end

function M.i16(s, o)
    local a, b = byte(s, o, o + 1)
    local v = a + b * 256
    if v >= 32768 then
        return v - 65536
    end
    return v
end
