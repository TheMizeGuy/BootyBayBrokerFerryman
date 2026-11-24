local ADDON, ns = ...

-- The settings page and its two buttons.
local M = {}
ns.Options = M

local floor, format = math.floor, string.format
local T, Ledger, Driver = ns.T, ns.Ledger, ns.Driver

local function Percent(v)
    return format("%d%%", floor(v * 100 + 0.5))
end

local function Minutes(v)
    return format(T.FMT_MIN, v)
end

local function Yards(v)
    return T.Yards(v)
end

-- INTERFACES section 9, in the order of the page: key, default, then for a number its range, step and label;
-- under names the switch a row hangs under.
local ROWS = {
    { "planner", true },
    { "arrow", true },
    { "arrowScale", 1, 0.5, 2, 0.05, Percent, under = "arrow" },
    { "arrowLock", false, under = "arrow" },
    { "steps", true },
    { "stepsScale", 1, 0.5, 2, 0.05, Percent, under = "steps" },
    { "stepsLock", false, under = "steps" },
    { "mapTrail", true },
    { "miniTrail", true },
    { "findButton", true },
    { "flightTimes", true },
    { "marks", true },
    { "arriveYards", 15, 5, 50, 1, Yards },
    { "hearth", true },
    { "hearthMinSave", 5, 1, 30, 1, Minutes, under = "hearth" },
    { "spells", true },
    { "splitFlights", false },
    { "splitMinSave", 1, 1, 10, 1, Minutes, under = "splitFlights" },
    { "caution", 0, 0, 2, 1 },
    { "followPin", true },
    { "followGuide", true },
    { "corpseRun", true },
    { "drivePin", false },
    { "arriveSound", false },
}

local category
local pending = false            -- Open was asked for in combat

local function Live()
    return Driver.Snapshot().options
end

-- A row the client cannot honour is not built.
local function Supported(key)
    if key == "followPin" or key == "drivePin" then
        -- Only the game's own switch: whether the map in view takes a pin is asked each time it is used (Pin).
        local rule = Enum.GameRule and Enum.GameRule.WorldMapTrackingPinDisabled
        return not (rule and C_GameRules.IsGameRuleActive(rule))
    elseif key == "followGuide" then
        return ns.Guide.present
    elseif key == "caution" then
        -- The walking data tells risky ground apart; it loads with the first trip, so a companion that is
        -- installed (not yet refused) offers the option.
        return ns.Env.GroundOffered()
    end
    return true
end

local function Cautions()
    local container = Settings.CreateControlTextContainer()
    container:Add(0, T.OPT_CAUTION_0)
    container:Add(1, T.OPT_CAUTION_1)
    container:Add(2, T.OPT_CAUTION_2)
    return container:GetData()
end

local function Reset()
    Ledger.ResetFrames()
    -- Setting an option to what it is publishes, and the frames place themselves again.
    Driver.SetOption("arrow", Live().arrow)
end

local function Forgotten()
    print(T.CHAT_PREFIX .. format(T.L_FORGOT, Ledger.Forget(nil)))
end

-- The settings row draws its label once, so the question is asked in the client's own dialog.
local function Forget()
    StaticPopup_ShowGenericConfirmation(T.OPT_FORGET_SURE, Forgotten)
end

local function Build()
    local ranges = {}
    -- The page's settings live in the Driver's options: reads see them, writes go through Driver.SetOption.
    local store = setmetatable({}, {
        __index = function(_, key)
            return Live()[key]
        end,
        __newindex = function(_, key, value)
            local range = ranges[key]
            if range then
                value = floor(value / range[5] + 0.5) * range[5]
                value = value < range[3] and range[3] or value > range[4] and range[4] or value
            else
                value = value and true or false
            end
            -- The panel may report one change twice.
            if Live()[key] ~= value then
                Driver.SetOption(key, value)
            end
        end,
    })
    category = Settings.RegisterVerticalLayoutCategory(T.OPT_TITLE)
    local made = {}
    for i = 1, #ROWS do
        local row = ROWS[i]
        local key, default = row[1], row[2]
        if Supported(key) then
            local upper = key:upper()
            local variable = "Ferryman_" .. key
            local label, tip = T["OPT_" .. upper], T["OPT_" .. upper .. "_TIP"]
            if row[3] then
                ranges[key] = row
            end
            local setting = Settings.RegisterAddOnSetting(category, variable, key, store, type(default), label, default)
            -- For a variable another addon holds, the client hands back whatever its last registration made
            -- (a setting of ours, or a row): only a setting of this variable is used.
            if setting and setting.GetVariable and setting:GetVariable() == variable then
                local init
                if key == "caution" then
                    init = Settings.CreateDropdown(category, setting, Cautions, tip)
                elseif row[3] then
                    local slider = Settings.CreateSliderOptions(row[3], row[4], row[5])
                    slider:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, row[6])
                    init = Settings.CreateSlider(category, setting, slider, tip)
                else
                    init = Settings.CreateCheckbox(category, setting, tip)
                end
                made[key] = init
                local under = row.under
                if under and made[under] then
                    init:SetParentInitializer(made[under], function() return Live()[under] end)
                end
            end
        end
    end
    Settings.RegisterInitializer(category, CreateSettingsButtonInitializer("", T.OPT_RESET, Reset, nil, true))
    Settings.RegisterInitializer(category, CreateSettingsButtonInitializer("", T.OPT_FORGET, Forget, nil, false))
    Settings.RegisterAddOnCategory(category)
end

-- True when the page opened; false in combat, where it opens at the next publish outside a fight.
function M.Open()
    if Driver.Snapshot().combat then
        pending = true
        return false
    end
    Settings.OpenToCategory(category:GetID())
    return true
end

-- The first publish that carries the options is the login's; without one the data did not load.
function M.OnChange(snapshot)
    if not category and next(snapshot.options) then
        Build()
    end
    if pending and not snapshot.combat then
        pending = false
        Settings.OpenToCategory(category:GetID())
    end
end

Driver.Subscribe(M.OnChange)
