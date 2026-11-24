local ADDON, ns = ...

-- A binary min-heap with decrease-key over ids 1 to capacity; ties go to the smaller id.
local M = {}
ns.Heap = M

function M.New(capacity)
    local heap, key, pos = {}, {}, {}
    for i = 1, capacity do
        heap[i], key[i], pos[i] = 0, 0, 0
    end
    return { n = 0, heap = heap, key = key, pos = pos }
end

function M.Clear(h)
    local heap, pos = h.heap, h.pos
    for i = 1, h.n do
        pos[heap[i]] = 0
    end
    h.n = 0
end

function M.Size(h)
    return h.n
end

function M.Push(h, id, k)
    local heap, key, pos = h.heap, h.key, h.pos
    local i = pos[id]
    if i > 0 then
        if k >= key[id] then
            return
        end
    else
        i = h.n + 1
        h.n = i
    end
    key[id] = k
    while i > 1 do
        local parent = (i - i % 2) / 2
        local up = heap[parent]
        local ku = key[up]
        if ku < k or (ku == k and up < id) then
            break
        end
        heap[i] = up
        pos[up] = i
        i = parent
    end
    heap[i] = id
    pos[id] = i
end

function M.Pop(h)
    local n = h.n
    if n == 0 then
        return nil
    end
    local heap, key, pos = h.heap, h.key, h.pos
    local top = heap[1]
    pos[top] = 0
    n = n - 1
    h.n = n
    if n > 0 then
        local id = heap[n + 1]
        local k = key[id]
        local i = 1
        while true do
            local c = i * 2
            if c > n then
                break
            end
            local child, kc = heap[c], key[heap[c]]
            if c < n then
                local r = heap[c + 1]
                local kr = key[r]
                if kr < kc or (kr == kc and r < child) then
                    c, child, kc = c + 1, r, kr
                end
            end
            if k < kc or (k == kc and id < child) then
                break
            end
            heap[i] = child
            pos[child] = i
            i = c
        end
        heap[i] = id
        pos[id] = i
    end
    return top, key[top]
end
