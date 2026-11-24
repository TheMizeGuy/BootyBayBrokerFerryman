local ADDON, ns = ...

-- The finder's index and query (INTERFACES 4.8): every place is one folded line of text, " name \1 kind words \2
-- area words ", and a query is a scan of those lines with string.find, which creates nothing. A token matches a
-- word by its beginning; where it matched gives a tier, and inside a tier the earlier arrival comes first.
local M = {}
ns.Find = M

local byte, find, lower, gsub, sub, gmatch = string.byte, string.find, string.lower, string.gsub, string.sub, string.gmatch
local sqrt = math.sqrt

M.ROWS, M.TOKENS, M.UNIT, M.SAME_KIND, M.SAME_NAME = 6, 4, 64, 40, 150
M.TYPO_MIN, M.KIND_MIN, M.NEAR_ENTRANCE = 5, 3, 1500
M.article, M.stop = nil, {}
local ROWS, TOKENS, UNIT, TYPO_MIN, KIND_MIN = M.ROWS, M.TOKENS, M.UNIT, M.TYPO_MIN, M.KIND_MIN
local FAR = 1e9

-- M2: lower case, Latin-1 letters to their base letter, apostrophes dropped, everything else that is not a letter
-- or a digit a space. Bytes of other scripts are compared as typed.
local LATIN, c = { ["\195\159"] = "ss" }, 0xC0 -- the letters of code points 0xC0 to 0xDD and 0xE0 to 0xFD
for b in ("a,a,a,a,a,a,ae,c,e,e,e,e,i,i,i,i,-,n,o,o,o,o,o,-,o,u,u,u,u,y"):gmatch("[^,]+") do
    if b ~= "-" then LATIN[string.char(0xC3, c - 0x40)], LATIN[string.char(0xC3, c - 0x20)] = b, b end
    c = c + 1
end
function M.Fold(s)
    s = lower(s)
    if find(s, "\195", 1, true) then s = gsub(s, "\195[\128-\191]", LATIN) end
    s = gsub(s, "'", "")
    if find(s, "\226\128\153", 1, true) then s = gsub(s, "\226\128\153", "") end
    s = gsub(s, "[%z\1-\47\58-\64\91-\96\123-\127]+", " ")
    return (gsub(gsub(s, "^ +", ""), " +$", ""))
end
local Fold = M.Fold

-- The entries, as parallel arrays; mass, x and y are also the points of the estimate request. meta[e] packs what
-- Add is given: meta + 512 * kind + 65536 * zone.
local doc, name, meta, mass, px, py, ent, weak
local n, ne, nc, lastN = 0, 0, 0, 0
M.points = { n = 0 }
function M.Reset()
    doc, name, meta, mass, px, py, ent, weak = {}, {}, {}, {}, {}, {}, {}, {}
    n, ne, nc, lastN = 0, 0, 0, 0
    M.points.n, M.points.mass, M.points.x, M.points.y, M.name = 0, mass, px, py, name
end
M.Reset()

-- kindWords and areaWords come folded (M1); the shown name is folded here, a leading article moved to its end (M3).
-- yields: a place the files only suggest, which gives its row to any other source at its own rank (K6).
function M.Add(shown, kindWords, areaWords, kind, landmass, x, y, mt, zone, yields)
    n = n + 1
    if yields then weak[n] = true end
    local folded, art = Fold(shown), M.article
    if art and sub(folded, 1, #art + 1) == art .. " " then folded = sub(folded, #art + 2) .. " " .. art end
    doc[n] = " " .. folded .. " \1 " .. kindWords .. " \2 " .. areaWords .. " "
    name[n], meta[n], mass[n], px[n], py[n] = shown, mt + 512 * kind + 65536 * (zone or 0), landmass, x, y
    if kind == 90 or kind == 91 then ne, ent[ne + 1] = ne + 1, n end
    M.points.n, lastN = n, 0
    return n
end

local function KindOf(e) local v = meta[e]; return (v - v % 512) / 512 % 128 end
local function Rank(e) local v = meta[e]; return (v - v % 64) / 64 % 4 end
function M.Entry(e)
    local v = meta[e]
    local mt = v % 512
    return name[e], KindOf(e), mass[e], px[e], py[e], mt % 4, (mt - mt % 4) / 4 % 16, Rank(e), mt >= 256,
        (v - v % 65536) / 65536
end

-- M9: q within one edit (a letter changed, missing, added, or two swapped) of a beginning of the word at w of d.
-- A word ends before the next byte under 33 (a space or a separator); the edit is counted in bytes.
local function Rest(q, d, qi, wi)
    for i = qi, #q do
        local b = byte(d, wi)
        if not b or b < 33 or b ~= byte(q, i) then return false end
        wi = wi + 1
    end
    return true
end
local function Near(q, d, w)
    local i, nq = 1, #q
    while i <= nq do
        local b = byte(d, w + i - 1)
        if not b or b < 33 or b ~= byte(q, i) then break end
        i = i + 1
    end
    if i > nq then return true end
    local at = w + i - 1
    if Rest(q, d, i + 1, at) then return true end
    local b = byte(d, at)
    if not b or b < 33 then return false end
    return Rest(q, d, i + 1, at + 1) or Rest(q, d, i, at + 1)
        or (i < nq and byte(q, i) == byte(d, at + 1) and byte(q, i + 1) == b and Rest(q, d, i + 2, at + 2))
end
M.Near = Near

local tok, needle, whole, one, two, typo, pre, post = {}, {}, {}, {}, {}, {}, {}, {}
local ntok, lastTok, unheld, lastTypo = 0, {}, {}, false
local cand, rows = {}, { n = 0, e = {}, tier = {}, secs = {} }
M.rows = rows

-- Where a word of d beginning with the token's first or second letter is within one edit of it: 2 in the name or
-- the kind's words (before s2), 1 only in the area's, 0 nowhere. One edit leaves the token's first h - 1 letters
-- or its letters after h whole, h = #q / 2 + 1, so a line holding neither (pre, post) is passed at once.
local function NearWord(d, t, s2)
    if not find(d, pre[t], 1, true) and not find(d, post[t], 1, true) then return 0 end
    local got = 0
    for pass = 1, 2 do
        local nd = pass == 1 and one[t] or two[t]
        if pass == 1 or nd ~= one[t] then
            local p = find(d, nd, 1, true)
            while p do
                if Near(tok[t], d, p + 1) then
                    if p < s2 then return 2 end
                    got = 1
                end
                p = find(d, nd, p + 1, true)
            end
        end
    end
    return got
end

-- M5: the folded text's words, less stop words unless nothing else remains, at most TOKENS.
local function Tokens(text)
    local q, stop, kept = Fold(text), M.stop, 0
    for w in gmatch(q, "[^ ]+") do
        if not stop[w] then kept = kept + 1 end
    end
    ntok = 0
    for w in gmatch(q, "[^ ]+") do
        if ntok < TOKENS and (kept == 0 or not stop[w]) then
            ntok = ntok + 1
            tok[ntok], needle[ntok], whole[ntok], typo[ntok] = w, " " .. w, " " .. w .. " ", false
            one[ntok], two[ntok] = " " .. sub(w, 1, 1), " " .. sub(w, 2, 2)
        end
    end
    return ntok
end

-- How entry e answers the tokens: its tier, or nil (M6, M7, K1 to K4).
local function Tier(e, ctx)
    local d = doc[e]
    local s1 = find(d, "\1", 1, true)
    local s2 = find(d, "\2", s1, true)
    local own, first, near, allKindWhole, allWhole, allKind, anyKind = false, false, false, true, true, true, false
    for t = 1, ntok do
        if typo[t] then
            local w = NearWord(d, t, s2)
            if w == 0 then return nil end
            own = own or w == 2
            near = true
        else
            local nd = needle[t]
            local p = find(d, nd, 1, true)
            if not p then return nil end
            if p < s2 then own = true end
            if t == 1 and p == 1 then first = true end
            local k = p > s1 and p or find(d, nd, s1, true)
            if not k or k > s2 then
                allKind, allKindWhole = false, false
            else
                local w = allKindWhole and find(d, whole[t], s1, true)
                if allKindWhole and (not w or w > s2) then allKindWhole = false end
                anyKind = true
            end
            if allWhole and not find(d, whole[t], 1, true) then allWhole = false end
        end
    end
    if not own then return nil end
    local tier = near and 3 or allKindWhole and 0 or (first or allWhole or allKind) and 1 or 2
    -- K2: a boat or a zeppelin named after where it goes is not that place
    if not anyKind and (KindOf(e) == 87 or KindOf(e) == 88) then tier = tier + 1 end
    local mt = meta[e] % 512
    local class = (mt - mt % 4) / 4 % 16
    if class > 0 then
        if class == ctx.class then
            if tier < 2 then tier = tier - 1 end
        else
            local word, named = ctx.classWord and ctx.classWord[class], false
            for t = 1, word and ntok or 0 do
                if find(word, tok[t], 1, true) == 1 then named = true end
            end
            if not named then tier = tier + 4 end
        end
    end
    return tier
end

-- K5: the estimate when it is in, else the straight line at the run speed on the player's landmass. H8: with no
-- position, rows go by tier and name.
local byName = false
local function Secs(e, ctx)
    if byName then return 0 end
    local f = ctx.fig and ctx.fig[e]
    if f then return f end
    if f == false or mass[e] ~= ctx.mass then return FAR end
    local dx, dy = px[e] - ctx.x, py[e] - ctx.y
    return sqrt(dx * dx + dy * dy) / ctx.v
end
local function Before(t1, s1, e1, t2, s2, e2)
    if t1 ~= t2 then return t1 < t2 end
    if s1 ~= s2 then return s1 < s2 end
    if byName and name[e1] ~= name[e2] then return name[e1] < name[e2] end
    return e1 < e2
end

-- Last: where the folded name of a line ends, its moved article left out.
local function Last(d)
    local last, art = find(d, "\1", 1, true) - 2, M.article
    local k = art and last - #art
    if not k or k < 2 or byte(d, k) ~= 32 then return last end
    for i = 1, #art do
        if byte(d, k + i) ~= byte(art, i) then return last end
    end
    return k - 1
end
-- whether lines d and g have one folded name, their moved articles left out
local function OneName(d, g)
    local last, k = Last(d), 2
    if Last(g) ~= last then return false end
    while k <= last and byte(g, k) == byte(d, k) do k = k + 1 end
    return k > last
end
-- K6: one service within SAME_KIND yards (a sighting and another source of one within SAME_NAME, as a look is made
-- from afar, but for a merchant or a trainer; auctioneers within SAME_NAME, who stand round one house: 2 where that
-- alone joins them; trainers of one class only), or one folded name, the article aside, within SAME_NAME, is one place.
local function Same(a, b)
    if mass[a] ~= mass[b] then return false end
    local dx, dy = px[a] - px[b], py[a] - py[b]
    local d2, k = dx * dx + dy * dy, KindOf(a)
    local r = k ~= 5 and k ~= 7 and (Rank(a) == 3) ~= (Rank(b) == 3) and M.SAME_NAME or k == 21 and M.SAME_NAME or M.SAME_KIND
    if k >= 5 and k <= 73 and k == KindOf(b) and d2 <= r * r and (k ~= 7 or meta[a] % 64 - meta[a] % 4 == meta[b] % 64 - meta[b] % 4) then
        return k ~= 21 or d2 <= M.SAME_KIND * M.SAME_KIND or (Rank(a) == 3) ~= (Rank(b) == 3) or 2
    end
    return d2 <= M.SAME_NAME * M.SAME_NAME and OneName(doc[a], doc[b])
end
-- M4: a zone, area, building or town named as a dungeon or raid entrance near it, the article aside, is that
-- entrance.
local function Shadowed(e)
    for i = 1, ne do
        local f = ent[i]
        local dx, dy = px[f] - px[e], py[f] - py[e]
        if mass[f] == mass[e] and dx * dx + dy * dy <= M.NEAR_ENTRANCE * M.NEAR_ENTRANCE and OneName(doc[e], doc[f]) then
            return true
        end
    end
    return false
end

-- K6, K7: the best ROWS places. A place met again keeps its better source (rank: a window, a guard's point, the files
-- or the network, what they only suggest, a sighting; of one house's auctioneers the better key) and its better tier.
local function Offer(e, tier, secs)
    local re, rt, rs, nr = rows.e, rows.tier, rows.secs, rows.n
    for i = 1, nr do
        local o = re[i]
        local same = Same(o, e)
        if same then
            local ro, rk = Rank(o) + (weak[o] and 0.5 or 0), Rank(e) + (weak[e] and 0.5 or 0)
            if same == 2 and ro % 1 + rk % 1 == 0 then ro, rk = 0, 0 end
            local t = tier < rt[i] and tier or rt[i]
            if not (rk < ro or (rk == ro and Before(tier, secs, e, rt[i], rs[i], o))) then e, secs = o, rs[i] end
            tier = t
            for j = i, nr - 1 do re[j], rt[j], rs[j] = re[j + 1], rt[j + 1], rs[j + 1] end
            nr = nr - 1
            break
        end
    end
    local i = nr
    if i == ROWS then
        if not Before(tier, secs, e, rt[i], rs[i], re[i]) then return end
        i = i - 1
    end
    while i >= 1 and Before(tier, secs, e, rt[i], rs[i], re[i]) do
        re[i + 1], rt[i + 1], rs[i + 1] = re[i], rt[i], rs[i]
        i = i - 1
    end
    re[i + 1], rt[i + 1], rs[i + 1] = e, tier, secs
    rows.n = nr < ROWS and nr + 1 or ROWS
end

local function Pass(ctx, all, pause)
    local kept, faction = 0, ctx.faction
    rows.n, byName = 0, not ctx.x
    for i = 1, all and n or nc do
        local e = all and i or cand[i]
        local tier = Tier(e, ctx)
        if tier then
            kept = kept + 1
            cand[kept] = e
            local v = meta[e]
            local k, f = (v - v % 512) / 512 % 128, v % 4
            -- M10: the other faction's services are never listed; its places are
            if (k < 5 or k > 73 or f == 0 or f == 3 or not faction or f == faction)
                and not ((k >= 81 and k <= 83 or k == 85 or k == 86) and Shadowed(e)) then
                Offer(e, tier, Secs(e, ctx))
            end
        end
        if pause and i % UNIT == 0 then pause() end
    end
    nc = kept
    return kept
end

-- The rows for a text, best first: M.rows.n of them in M.rows.e, .tier, .secs. ctx: faction, class, classWord
-- (folded class names by class id), mass, x, y, v (where the player stands and the run speed; x nil: no position),
-- fig (seconds by entry, false where nothing leads; nil before the estimates). Returns the number of matches.
function M.Query(text, ctx, pause)
    if Tokens(text) == 0 then
        rows.n, nc, lastN = 0, 0, 0
        return 0
    end
    -- M8: tokens that each extend the last text's own are matched only among what it matched
    local narrow = lastN == ntok
    for t = 1, narrow and ntok or 0 do
        if find(tok[t], lastTok[t], 1, true) ~= 1 then narrow = false end
    end
    local afterTypo = narrow and lastTypo
    for t = 1, ntok do lastTok[t] = tok[t] end
    lastN, lastTypo = ntok, false
    if not afterTypo then
        local kept = Pass(ctx, not narrow, pause)
        if kept > 0 then return kept end
    end
    -- M9: nothing matched: a token of TYPO_MIN letters or more that no line holds is tried within one edit. A
    -- token that extends one no line held is held by none; when no other token joins them, what the last text
    -- matched within one edit holds all this one can.
    local any, grew = false, not afterTypo
    for t = 1, ntok do
        local q = tok[t]
        if afterTypo and unheld[t] then
            typo[t], any = true, true
        elseif #q >= TYPO_MIN then
            local held = false
            for e = 1, n do
                if find(doc[e], needle[t], 1, true) then
                    held = true
                    break
                end
                if pause and e % UNIT == 0 then pause() end
            end
            if not held then typo[t], any, grew = true, true, true end
        end
        unheld[t] = typo[t]
        if typo[t] then
            local h = (#q - #q % 2) / 2 + 1
            pre[t], post[t] = " " .. sub(q, 1, h - 1), sub(q, h + 1)
        end
    end
    if not any then
        rows.n, nc = 0, 0
        return 0
    end
    lastTypo = true
    return Pass(ctx, grew, pause)
end

-- H1: whether an entry of a kind (of a class, that repairs) stands in a zone (with none, on a landmass), and
-- whether one stands anywhere; entries of the other faction count not.
function M.Has(kind, class, repair, zone, faction, landmass)
    local anywhere = false
    for e = 1, n do
        local v = meta[e]
        if (v - v % 512) / 512 % 128 == kind then
            local mt = v % 512
            local f = mt % 4
            if (not faction or f == 0 or f == 3 or f == faction) and (not class or (mt - mt % 4) / 4 % 16 == class)
                and (not repair or mt >= 256) then
                if zone and zone > 0 and (v - v % 65536) / 65536 == zone or not zone and mass[e] == landmass then
                    return true, true
                end
                anywhere = true
            end
        end
    end
    return false, anywhere
end

-- whether the text holds a word that is no stop word, and every such word is a word of words (padded with spaces):
-- H1's class trainer's words alone, H3's profession named alone
function M.Only(text, words)
    local any = false
    for w in gmatch(Fold(text), "[^ ]+") do
        if not M.stop[w] then
            if not find(words, " " .. w .. " ", 1, true) then return false end
            any = true
        end
    end
    return any
end

-- whether w begins a word of line (whole: is a word of it); words are split at spaces
local function Word(line, w, whole)
    local p = find(line, w, 1, true)
    while p do
        local a, b = byte(line, p - 1), byte(line, p + #w)
        if (not a or a == 32) and (not whole or not b or b == 32) then return true end
        p = find(line, w, p + 1, true)
    end
    return false
end

-- whether q is within one edit of a beginning of a word of line that begins with q's first or second letter (M9)
local function Edited(line, q)
    local p, a, b = 0, byte(q, 1), byte(q, 2)
    repeat
        if (byte(line, p + 1) == a or byte(line, p + 1) == b) and Near(q, line, p + 1) then return true end
        p = find(line, " ", p + 1, true)
    until not p
end

-- M11: what the text asks for, over lines (the folded words of each kind, in order): the one of whose words the
-- most tokens are whole words, a token of TYPO_MIN letters that begins no word of any line and that the last
-- Query of the same text found no place to hold counting where it is within one edit of one, the first of those
-- tied, else, for a text of one token of KIND_MIN letters or more, the only one of whose words it begins one. Also
-- the class a token of KIND_MIN letters begins the name of (classWord: folded names by class id), and whether a
-- token is a whole word of the folded repair word.
local far = {}
function M.Kind(text, lines, classWord, repairWord)
    Tokens(text)
    local kind, class, repair, most = nil, nil, false, 0
    for t = 1, ntok do
        far[t] = #tok[t] >= TYPO_MIN and lastTypo and unheld[t] and lastTok[t] == tok[t]
        for i = 1, far[t] and #lines or 0 do far[t] = far[t] and not Word(lines[i], tok[t], false) end
    end
    for i = 1, #lines do
        local got = 0
        for t = 1, ntok do
            if Word(lines[i], tok[t], true) or far[t] and Edited(lines[i], tok[t]) then got = got + 1 end
        end
        if got > most then kind, most = i, got end
    end
    if not kind and ntok == 1 and #tok[1] >= KIND_MIN then
        local only = 0
        for i = 1, #lines do
            if Word(lines[i], tok[1], false) then only = only == 0 and i or -1 end
        end
        if only > 0 then kind = only end
    end
    for id = 1, classWord and 31 or 0 do
        local w = classWord[id]
        for t = 1, w and not class and ntok or 0 do
            if #tok[t] >= KIND_MIN and find(w, tok[t], 1, true) == 1 then class = id end
        end
    end
    for t = 1, repairWord and ntok or 0 do
        if Word(repairWord, tok[t], true) then repair = true end
    end
    return kind, class, repair
end
