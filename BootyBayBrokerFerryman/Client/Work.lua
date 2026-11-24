local ADDON, ns = ...

-- Runs jobs a slice per frame: coroutines resumed under a deadline, one job at a time, by priority.
local M = {}
ns.Work = M

M.SLICE_MS = 1.5
M.COMBAT_SLICE_MS = 0.75
M.STRETCH_MS = 0.5
-- a plan is the wait a player feels, and lasts well under a second: its slice is longer
M.PLAN_SLICE_MS = 2.0
M.PLAN_COMBAT_SLICE_MS = 1.0

-- the stretch a slice allows for: the longest of the job's last WINDOW resumes, so one long resume is forgotten
local MIN_STRETCH, TRUSTED_RESUMES, WINDOW = 0.1, 8, 16
local PRIORITY = { find = 0, plan = 1, read = 2, trace = 2, side = 2, detail = 3, survey = 4, estimate = 5, prove = 6, bench = 7 }

local queue, count = {}, 0
local frame, running, combat = false, false, false
local slices, peakMs, totalMs = 0, 0, 0
local yield, resume, status, clock = coroutine.yield, coroutine.resume, coroutine.status, debugprofilestop

local function Report(err)
    geterrorhandler()(err)
end

local function Call(fn, a, b)
    local ok, err = pcall(fn, a, b)
    if not ok then
        Report(err)
    end
end

-- Records only; delivery waits for the end of the slice. Only the job being resumed can call it.
local function Emit(what, value)
    local job = running
    local n = job.n + 1
    job.n, job.what[n], job.value[n] = n, what, value
end

local function Remove(job)
    for i = 1, count do
        if queue[i] == job then
            table.remove(queue, i)
            count = count - 1
            break
        end
    end
    job.gone = true
    if count == 0 and frame then
        frame:SetScript("OnUpdate", nil)
    end
end

local function Pick()
    local best
    for i = 1, count do
        local job = queue[i]
        if not best or PRIORITY[job.kind] < PRIORITY[best.kind] then
            best = job
        end
    end
    return best
end

local function Deliver(job)
    local i = 0
    while i < job.n and not job.dropped do
        i = i + 1
        local what, value = job.what[i], job.value[i]
        job.what[i], job.value[i] = nil, nil
        Call(job.sink, what, value)
    end
    job.n = 0
end

-- The slice of a job of that kind, in or out of combat.
function M.Slice(kind, inCombat)
    if kind == "plan" then return inCombat and M.PLAN_COMBAT_SLICE_MS or M.PLAN_SLICE_MS end
    return inCombat and M.COMBAT_SLICE_MS or M.SLICE_MS
end

local function Slice()
    local job = Pick()
    if not job then
        frame:SetScript("OnUpdate", nil)
        return
    end
    local limit = M.Slice(job.kind, combat)
    local t0 = clock()
    local elapsed, failed, finished = 0, false, false
    running = job
    repeat
        local s0 = clock()
        local ok, err
        if job.started then
            ok, err = resume(job.co)
        else
            job.started = true
            ok, err = resume(job.co, job.arg, yield, Emit)
        end
        local s1 = clock()
        local n, last = job.resumes + 1, job.last
        job.resumes, last[n % WINDOW] = n, s1 - s0
        local longest = MIN_STRETCH
        for k = 0, WINDOW - 1 do
            if last[k] > longest then longest = last[k] end
        end
        elapsed = s1 - t0
        if not ok then
            failed = err
        elseif status(job.co) == "dead" then
            finished = true
        end
        local stretch = n >= TRUSTED_RESUMES and longest or M.STRETCH_MS
    until failed or finished or elapsed + stretch > limit
    running = false
    slices, totalMs = slices + 1, totalMs + elapsed
    if elapsed > peakMs then
        peakMs = elapsed
    end
    if failed or finished then
        Remove(job)
        if failed then
            Report(failed)
            if job.cleanup then
                Call(job.cleanup)
            end
        end
    end
    Deliver(job)
    if not job.dropped then
        if failed then
            Call(job.sink, "error", failed)
        elseif finished then
            Call(job.sink, "end")
        end
    end
end

local function OnUpdate()
    local ok, err = pcall(Slice)
    if not ok then
        Report(err)
    end
end

function M.Start(kind, fn, arg, sink, cleanup)
    assert(PRIORITY[kind])
    local job = { kind = kind, co = coroutine.create(fn), arg = arg, sink = sink, cleanup = cleanup or false,
        started = false, resumes = 0, last = {}, n = 0, what = {}, value = {}, dropped = false, gone = false }
    for k = 0, WINDOW - 1 do job.last[k] = 0 end
    count = count + 1
    queue[count] = job
    if not frame then
        frame = CreateFrame("Frame")
    end
    frame:SetScript("OnUpdate", OnUpdate)
    return job
end

function M.Cancel(job)
    if not job or job.dropped then
        return
    end
    job.dropped = true
    if job.gone then
        return
    end
    Remove(job)
    if job.started and job.cleanup then
        Call(job.cleanup)
    end
end

function M.Busy(kind)
    for i = 1, count do
        if kind == nil or queue[i].kind == kind then
            return true
        end
    end
    return false
end

function M.SetCombat(on)
    combat = on and true or false
end

function M.Stats()
    return slices, peakMs, totalMs
end

function M.ResetStats()
    slices, peakMs, totalMs = 0, 0, 0
end
