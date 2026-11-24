local ADDON, ns = ...

-- Timetable arithmetic (INTERFACES 3.2 and 4.3). Moments are server-time seconds. A timetable's period and sigma are
-- what the player's rides proved; a prior { period, sigma } is the shipped row's claim, off once wide names its period.
local M = {}
ns.Clock = M

M.PHASE_U0 = 3
M.MISS = 15
M.SIGMA_TABLE = 0.005
M.SIGMA_DEFAULT = 0.15
M.STRIKES = 2
-- Whether a timetable known only as an estimate is shown as one ("about"); false shows it untimed (decision 137).
M.ESTIMATES = true
-- Seconds after the last ride that a prior no ride has confirmed carries an estimate.
M.UNSURE = 86400

local floor, huge, abs, max = math.floor, math.huge, math.abs, math.max

local function Finite(v)
    return type(v) == "number" and v == v and v ~= huge and v ~= -huge
end

function M.New(period, sigma, build)
    return { period = period, phase = false, sigma = sigma * period, seen = 0, count = 0, build = build }
end

function M.Valid(tt)
    if type(tt) ~= "table" then
        return false
    end
    local p, c, s = tt.period, tt.count, tt.strikes
    return Finite(p) and p >= 30 and p <= 3600 and Finite(tt.sigma) and tt.sigma > 0
        and Finite(c) and c >= 0 and c == floor(c) and Finite(tt.seen) and type(tt.build) == "string"
        and (tt.phase == false or Finite(tt.phase)) and (s == nil or Finite(s) and s >= 0 and s == floor(s))
        and (tt.wide == nil or Finite(tt.wide)) and (tt.off == nil or tt.off == true) and (tt.sure == nil or Finite(tt.sure))
end

-- The sigma a lap of a timetable the rides have not refined: the shipped table's doubt, or the prior's when wider.
function M.Start(period, prior) return max(M.SIGMA_TABLE * period, prior and prior.sigma or 0) end

-- The period and sigma a lap the clock goes by: the prior's while it is in force and surer than the rides.
function M.Best(tt, prior)
    if prior and tt.wide ~= prior.period and prior.sigma < tt.sigma then return prior.period, prior.sigma end
    return tt.period, tt.sigma
end
local Best = M.Best

function M.Uncertainty(tt, now, prior)
    if not tt.phase then return huge end
    local p, sigma = Best(tt, prior)
    return M.PHASE_U0 + sigma * max(0, now - tt.seen) / p
end

function M.Usable(tt, now)
    return M.Uncertainty(tt, now) <= tt.period / 4
end

-- What may be shown at now on client build: false, or { period, phase, u, tier, sigma, at } that Next and Arrive read
-- as a timetable. "count": the rides alone, on this build, within MISS a lap ahead; "about": the best within a quarter
-- period a lap ahead (M.ESTIMATES), on the prior only while no strike stands and, until a fit on its count confirmed
-- it (sure), for UNSURE after the last ride.
function M.View(tt, now, build, prior, out)
    if not tt.phase then return false end
    local age, p, sigma, tier = max(0, now - tt.seen), tt.period, tt.sigma, "count"
    if not (tt.build == build and M.PHASE_U0 + sigma * (age / p + 1) <= math.min(M.MISS, p / 4)) then
        local trusted = prior and not tt.strikes and (tt.sure == prior.period or age <= M.UNSURE)
        p, sigma = Best(tt, trusted and prior or nil)
        tier = M.ESTIMATES and "about"
    end
    local u = M.PHASE_U0 + sigma * age / p
    if not tier or u + sigma > p / 4 then return false end
    out = out or {}
    out.period, out.phase, out.u, out.tier, out.sigma, out.at = p, tt.phase, u, tier, sigma, now
    return out
end

-- A view's uncertainty at t (u0 its own when not given), grown from its moment at its sigma a lap; false once past a
-- quarter period.
function M.UAt(view, t, u0)
    local u = (u0 or view.u) + (view.at and view.sigma or 0) * max(0, t - (view.at or t)) / view.period
    return u <= view.period / 4 and u
end

-- The earliest phase + off + k * period at or after t; the two corrections absorb rounding of the division.
function M.Next(tt, off, t)
    local p = tt.period
    local base = tt.phase + off
    local d = base + math.ceil((t - base) / p) * p
    if d < t then
        d = d + p
    elseif d - p >= t then
        d = d - p
    end
    return d
end

local Next = M.Next

function M.Arrive(tt, off, ride, u, t)
    return Next(tt, off, t + u) + ride + u
end

function M.ArriveUnknown(period, ride, t)
    return t + period / 2 + ride
end

function M.SetPeriod(tt, period, sigmaFraction)
    tt.period = period
    tt.sigma = sigmaFraction * period
end

-- A ride's departure dep, observed at now on build. The laps are counted at Best's period. Only the rides earn the
-- count: a ride of another build, one too many laps on, or one that fits only because the prior counted its laps
-- anchors the phase alone (the last clears the strikes); one the rides alone can count refines, its period taken
-- when surer and inside lo .. hi; one that contradicts starts the rides again at the shipped period, a strike when
-- the prior counted it, and STRIKES of those put the prior out of force. Returns the result, the laps and the miss.
function M.Observe(tt, dep, now, build, prior, shipped, lo, hi)
    local was, u0 = tt.build, M.PHASE_U0
    tt.build = build
    if not tt.phase then tt.phase, tt.seen, tt.count = dep, now, 1 return "first", 0, 0 end
    local p, sigma = Best(tt, prior)
    local laps = floor((dep - tt.phase) / p + 0.5)
    local miss, spread, period = dep - (tt.phase + laps * p), sigma * laps + 2 * u0, (dep - tt.phase) / laps
    local fits, own = abs(miss) <= max(M.MISS, spread), tt.sigma * laps + 2 * u0 <= tt.period / 4
    if laps <= 0 or was ~= build or spread > p / 4 or fits and not own then
        if laps > 0 and was == build and fits and abs(miss) <= spread then tt.strikes, tt.sure = nil, prior and prior.period end
        tt.phase, tt.seen = dep, now
        if laps <= 0 then return "refined", 0, 0 end
        return "anchored", laps, miss
    end
    local better = 2 * u0 / laps < tt.sigma
    if fits and not (better and (period < (lo or 0) or period > (hi or period))) then
        if better then tt.period, tt.sigma = period, 2 * u0 / laps end
        tt.phase, tt.seen, tt.count = dep, now, tt.count + 1
        return "refined", laps, miss
    end
    shipped = shipped or tt.period
    tt.phase, tt.seen, tt.count = dep, now, 1
    if sigma ~= tt.sigma then tt.strikes, tt.sure = (tt.strikes or 0) + 1, nil end
    tt.period, tt.sigma = shipped, M.Start(shipped, prior)
    if prior and (tt.strikes or 0) >= M.STRIKES then tt.wide, tt.strikes = prior.period, nil end
    return "reset", laps, miss
end
