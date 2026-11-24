local ADDON, ns = ...

-- Every string Ferryman shows, by key. A translation replaces values of ns.T in a file loaded after this one.
local T = {}
ns.T = T

local format, floor, max = string.format, math.floor, math.max

-- Steps, and the arrow while waiting
T.STEP_WALK_GOAL = "Walk to your destination"
T.STEP_WALK_DOOR = "Walk to the entrance"
T.STEP_WALK_SPOT = "Walk to the closest spot"
T.STEP_SWIM_GOAL = "Swim to your destination, %s"
T.STEP_SWIM_SHORE = "Swim to the shore, %s"
T.STEP_FLIGHT = "Take the flight to %s"
T.STEP_BOAT = "Board the boat to %s"
T.STEP_ZEPPELIN = "Board the zeppelin to %s"
T.STEP_TRAM = "Ride the Deeprun Tram to %s"
T.STEP_LIFT = "Take the lift"
T.STEP_PORTAL = "Take the portal to %s"
T.STEP_HEARTH = "Use your Hearthstone"
T.STEP_SPELL = "Cast %s"
T.STEP_ITEM = "Use %s"
T.STEP_WAIT = "wait %s"
T.STEP_AFTER_WALK = "after a %s walk"
T.STEP_DECLINED = "Skipped: %s. Click to undo."
T.STEP_SKIP_FLIGHT = "flights from %s"
T.TAG_UNCONFIRMED = "route not confirmed"
T.TAG_LANDING = "landing estimated"
T.TAG_DEPARTURE = "departure estimated"
T.PIER_EVERY = "every %s, not timed yet"
T.PIER_ARRIVES = "arrives in %s"
T.PIER_ARRIVING = "arriving now"
T.PIER_BOARD = "boarding, leaves in %s"
T.LEAVES_NOW = "leaving now"
T.PIER_ARRIVES_ABOUT = "arrives in about %s"
T.PIER_ARRIVING_ABOUT = "arriving any moment"
T.PIER_LEAVES_ABOUT = "leaves in about %s"
T.LEAVES_ABOUT = "leaves any moment"
T.KIND_FLIGHT = "flights"
T.KIND_BOAT = "boats"
T.KIND_ZEPPELIN = "zeppelins"
T.KIND_TRAM = "the tram"
T.KIND_LIFT = "lifts"
T.KIND_PORTAL = "portals"
T.KIND_HEARTH = "your Hearthstone"
T.KIND_SPELL = "travel spells"
T.KIND_WALK = "walks"

-- Arrow
T.ARROW_OPEN = "Open the flight map"
T.RIDE_FLIGHT = "Flying to %s"
T.RIDE_BOAT = "On the boat to %s"
T.RIDE_ZEPPELIN = "On the zeppelin to %s"
T.RIDE_TRAM = "On the tram to %s"
T.RIDE_LIFT = "On the lift"
T.RIDE_PORTAL = "Through the portal to %s"
T.RIDE_CAST = "On the way to %s"
T.LANDS_IN = "lands in %s"
T.LANDS_NOW = "landing now"
T.DOCK_BOAT = "Boat to %s"
T.DOCK_ZEPPELIN = "Zeppelin to %s"
T.DOCK_TRAM = "Tram to %s"
T.DOCK_LINE = "%s: %s"
T.ARROW_BODY = "%s to your body"

-- Header and notices
T.HEAD_TO = "To %s"
T.HEAD_ARRIVE = "Arrive %s (%s)"
T.HEAD_PLANNING = "Planning... (%s)"
T.HEAD_PLANNING0 = "Planning..."
T.DEST_SPOT = "the spot you picked"
T.DEST_PIN = "your map pin"
T.DEST_COORDS = "%s %s, %s"
T.N_HEARTH = "Hearthstone available: saves %s."
T.N_REPLAN = "Finding a new way..."
T.N_CLOSEST = "This is the closest spot Ferryman can reach."
T.N_UNREAD = "Flight points on %s not read yet. Open the flight map at any flight master there."
T.N_UNREAD_SAVE = "Flight points on %s not read yet. With them this trip could be up to %s shorter."
T.N_NEAREST_FM = "Nearest flight master: %s, %s. Go there first"
T.N_OPEN_FLIGHTS = "Open the flight map so Ferryman can read your flight points."
T.N_NEW_PIN = "Go to the new map pin"
T.N_RISK = "This trip crosses dangerous ground."
T.N_SAFER = "The safest way would take %s longer."
T.N_SAVES = "The first step saves %s."
T.N_NO_SHOW = "You have waited longer than the time between departures. This route may not be running."
T.N_AFTER_FIGHT = "Cast it when the fight ends."
T.N_NO_HEARTH = "Ferryman will learn where your Hearthstone lands the next time you use it."
T.N_NO_GROUND = "Walking data for %s is missing, disabled or of another version: trips there can start and end only at its flight masters, docks and portals."
T.N_STOP = "End the trip"

-- States
T.S_DEAD = "Resumes when you are alive"
T.S_LOADING = "Waiting for the world..."
T.S_INSTANCE = "Planning resumes outside"
T.S_AIR = "Planning resumes when you land"
T.S_CARRIED = "Planning resumes when you get off"
T.S_TRAM = "Planning resumes when you leave the tram"
T.S_LOST = "Looking for where you are..."
T.S_NODATA = "Walking data for this land is missing or disabled: go to a flight master, dock or portal"
T.F_NOWAY = "No way there"
T.F_NOGROUND = "Ferryman has no map of that place yet"
T.F_TOOFAR = "Ferryman cannot reach anywhere near that spot"
T.F_ERROR = "Something went wrong and the trip was stopped"

-- Menu, tooltips, chat
T.CHAT_PREFIX = "Ferryman: "
T.HELLO = "Alt-click the world map, or type /ferry, to plan a trip. %s"
T.HELLO_GUIDE = "Ferryman draws the way to RestedXP's next step on the minimap: /ferry stop ends it for this step, /ferry guide turns it off. Alt-click the world map, or type /ferry, for a trip of your own. %s"
T.MENU_TITLE = "Where to?"
T.MENU_PICK = "Pick on the map"
T.MENU_ENTRANCES = "Dungeon and raid entrances"
T.MENU_DOOR_UNKNOWN = "%s (enter once to learn it)"
T.MENU_PIN = "My map pin"
T.MENU_QUEST = "My tracked quest"
T.MENU_QUEST_BACK = "Back to where I accepted my tracked quest"
T.MENU_QUEST_NONE = "The game has no location for this quest"
T.MENU_PARTY = "Party members"
T.MENU_PARTY_N = "Party member %d"
T.MENU_STOP = "End the trip"
T.MENU_OPTIONS = "Options"
T.CTX_WITHOUT = "Plan without this"
T.TIP_BUTTON = "Ferryman: Where to?"
T.TIP_ARMED = "Click a spot on the map"
T.TIP_MOVE = "Drag to move."
T.TIP_END = "Right-click to end the trip."
T.ARMED_OPEN = "Open the world map and click a spot."
T.TIP_PIN_NEXT = "Next: %s"
T.TIP_FLIGHT = "Flight: %s"
T.E_USAGE = "Type /ferry [zone] x y [title], for example /ferry Elwynn Forest 42 65"
T.E_ZONE = "No zone is called \"%s\"."
T.E_RANGE = "Coordinates run from 0 to 100."
T.E_NOPLACE = "There is nowhere to go for that right now."
T.E_NOPIN = "You have no map pin."
T.E_NOMAP = "Ferryman cannot tell which zone you are in: name one, for example /ferry Elwynn Forest 42 65"
T.E_OFF = "Ferryman is not running: its data did not load."
T.E_NOWORLD = "That map has no place Ferryman can lead to."
T.E_CURSOR = "Open the world map and point at a spot first."
T.STOPPED = "Trip ended."
T.NO_TRIP = "There is no trip to end."
T.OPTIONS_COMBAT = "The options open when the fight ends."
T.HELP_1 = "/ferry - Where to?"
T.HELP_2 = "/ferry [zone] x y [title] - plan a trip"
T.HELP_3 = "/ferry stop, steps, arrow, guide, pin, options, learned, bench, check"
T.HELP_4 = "/ferry find [text] - search for a place"
T.WAY_OURS = "/way plans a Ferryman trip."
T.WAY_OTHER = "/way belongs to another addon (%s)."
T.WAY_GAME = "/way is the game's own: /way <map id> <x> <y> places a map pin, which Ferryman can follow."
T.STEPS_ON = "The steps are shown during a trip."
T.STEPS_OFF = "The steps are hidden. /ferry steps shows them again."
T.ARROW_ON = "The arrow is shown during a trip."
T.ARROW_OFF = "The arrow is hidden. /ferry arrow shows it again."
T.FOLLOWGUIDE_ON = "Ferryman shows the way to RestedXP's next step."
T.FOLLOWGUIDE_OFF = "Ferryman no longer follows RestedXP. /ferry guide turns it back on."

-- The finder: its rows, and the words a text is matched by beside the client's own
T.FIND_HINT = "Type a place, a service or a name"
T.FIND_NONE_HERE = "None seen in %s yet"
T.FIND_NONE = "None seen yet"
T.FIND_NOTHING = "Nothing found"
T.FIND_ASK = "Ask a guard once and Ferryman keeps it"
T.FIND_SEEN = "seen near here"
T.FIND_NO_WAY = "No way there"
T.FIND_LINE = "%s, %s"
T.FIND_TRAINER = "%s Trainer"
T.FIND_BOAT = "Boat to %s"
T.FIND_ZEPPELIN = "Zeppelin to %s"
T.FIND_TRAM = "Deeprun Tram"
T.FIND_ARTICLE = "the"
T.FIND_STOP = "the a an to in at of near nearest closest where is find"
T.FIND_WORDS_MERCHANT = "vendor shop"
T.FIND_WORDS_FLIGHT = "fm fp taxi path gryphon"
T.FIND_WORDS_TRAINER = "trainer trainers"
T.FIND_WORDS_GUILDBANK = "gbank"
T.FIND_WORDS_MAIL = "mail"
T.FIND_WORDS_INN = "inn tavern"
T.FIND_WORDS_AUCTION = "ah"
T.FIND_WORDS_STABLE = "stable"
T.FIND_WORDS_BATTLE = "bg"
T.FIND_WORDS_TRANSMOG = "transmog"
T.FIND_WORDS_BARBER = "barbershop"
T.FIND_WORDS_BOAT = "boat ship dock"
T.FIND_WORDS_ZEPPELIN = "zeppelin zep dock"
T.FIND_WORDS_TRAM = "tram"
T.TIP_FIND = "Search for a place. Drag to move."

-- What Ferryman has learned, bench, check
T.L_HEAD = "What Ferryman has learned:"
T.L_NONE = "Nothing yet."
T.L_LINE = "%s  [%s]"
T.L_FLIGHTS = "Flight points on %s: %d"
T.L_FLIGHTS_UNREAD = "Flight points on %s: not read yet"
T.L_CHAINS = "Flight routes seen: %d"
T.L_BIND = "Hearthstone lands in %s"
T.L_SPEED = "Travel speed: %d%% on land, %d%% swimming"
T.L_FLY = "Flight speed: %s yd/s from %d flights"
T.L_VESSEL = "%s: running; a round trip takes %s"
T.L_VESSEL_OFF = "%s: its ride ran %s sec off Ferryman's data, so its times are not used"
T.L_PHASE = "%s: next departure known to within %s"
T.L_PHASE_ABOUT = "%s: next departure estimated to within %s"
T.L_PHASE_KEPT = "%s: departure times kept, not usable now"
T.L_LANDING = "%s lands in %s"
T.L_DOOR = "Entrance of %s"
T.L_PORTAL = "Portal from %s to %s"
T.L_QUESTS = "Quest places: %d"
T.L_PLACES = "Places: %d"
T.L_LOADING = "Loading screens take %s"
T.L_ERROR = "Estimates for %s were off by %s on average (%d timed)"
T.L_UNCONFIRMED = " (not confirmed)"
T.L_FORGOT = "Facts forgotten: %d."
T.L_FORGET_WHAT = "Nothing learned is called \"%s\"."
T.L_FORGET_HOW = "Type /ferry learned forget and a key from the brackets, or /ferry learned forget all."
T.BENCH_RUN = "Timing %d plans..."
T.BENCH_GROUND = "Walking data, %s: loaded in %s ms"
T.BENCH_NO_GROUND = "Walking data, %s: not loaded"
T.BENCH_PLAN = "Plans: first step after %d slices (worst %d), proven after %d (worst %d), %s ms of CPU at worst"
T.BENCH_SLICE = "Longest slice %s ms; frames over 5 ms: %d; peak frame %s ms"
T.BENCH_LEAD = "Leading: %s ms per frame on average"
T.BENCH_RATIO = "Lua here takes %s times as long as on the build machine"
T.CHECK_COORDS_OK = "Map coordinates agree with the client."
T.CHECK_COORDS_BAD = "Map coordinates do not agree with the client."
T.CHECK_COORDS_NONE = "There is no map here to check against."
T.CHECK_CLEAN = "The map, the minimap and the flight window are untouched."
T.CHECK_DIRTY = "Not secure: %s.%s"
T.CHECK_UNAVAILABLE = "This client cannot check that."

-- Options page: a label and a one-sentence tooltip per option key (INTERFACES section 9)
T.OPT_TITLE = "Ferryman"
T.OPT_PLANNER = "Travel planner"
T.OPT_PLANNER_TIP = "Plans trips from the map button, the search, Alt-click, a map pin, RestedXP and /ferry; off, Ferryman shows only what other addons ask it to."
T.OPT_ARROW = "Show the arrow, distance and time"
T.OPT_ARROW_TIP = "Shows an arrow that points along the trip while you walk, with the distance and time under it, the next arrival or departure of a boat or zeppelin while you stand at its dock, and where and when a flight or a boat lands."
T.OPT_ARROWSCALE = "Arrow size"
T.OPT_ARROWSCALE_TIP = "Makes the arrow and its text larger or smaller."
T.OPT_ARROWLOCK = "Lock the arrow in place"
T.OPT_ARROWLOCK_TIP = "Stops the arrow and its text from taking the mouse, so clicks pass through."
T.OPT_STEPS = "Show the steps"
T.OPT_STEPS_TIP = "Shows the list of steps with their times and the arrival time."
T.OPT_STEPSSCALE = "Steps size"
T.OPT_STEPSSCALE_TIP = "Makes the list of steps larger or smaller."
T.OPT_STEPSLOCK = "Lock the steps in place"
T.OPT_STEPSLOCK_TIP = "Stops the list of steps from being dragged by accident."
T.OPT_MAPTRAIL = "Draw the trip on the world map"
T.OPT_MAPTRAIL_TIP = "Draws every step of the trip on the world map while it is open."
T.OPT_MINITRAIL = "Draw the trip on the minimap"
T.OPT_MINITRAIL_TIP = "Marks the way ahead on the minimap while you walk."
T.OPT_FINDBUTTON = "Show the search button"
T.OPT_FINDBUTTON_TIP = "Shows a button that opens a box where you type where you want to go."
T.OPT_FLIGHTTIMES = "Show flight times on the flight map"
T.OPT_FLIGHTTIMES_TIP = "Adds the time of the flight to a flight master's tooltip when you point at it on the flight map."
T.OPT_MARKS = "Show other addons' places on the maps"
T.OPT_MARKS_TIP = "Draws the places other addons hand to Ferryman on the world map and the minimap."
T.OPT_ARRIVEYARDS = "Clear the trip when I am within this many yards"
T.OPT_ARRIVEYARDS_TIP = "The trip ends when you come this close to the destination."
T.OPT_HEARTH = "Suggest my Hearthstone"
T.OPT_HEARTH_TIP = "Lets a trip start with your Hearthstone when it is ready and gets you there sooner."
T.OPT_HEARTHMINSAVE = "Only when it saves at least this many minutes"
T.OPT_HEARTHMINSAVE_TIP = "The Hearthstone is suggested only when it saves at least this much time."
T.OPT_SPELLS = "Use my travel spells"
T.OPT_SPELLS_TIP = "Lets a trip start with a teleport or another travel spell you know."
T.OPT_SPLITFLIGHTS = "Change flights on the way"
T.OPT_SPLITFLIGHTS_TIP = "Lets a trip land at a flight master and take another flight there when that gets you there sooner."
T.OPT_SPLITMINSAVE = "Only when it saves at least this many minutes"
T.OPT_SPLITMINSAVE_TIP = "A change of flights is planned only when it saves at least this much time."
T.OPT_CAUTION = "Avoid enemy towns and areas too high for my level"
T.OPT_CAUTION_TIP = "Prefers ways that keep away from the other faction's towns and from areas well above your level."
T.OPT_FOLLOWPIN = "Plan a trip when I place a map pin"
T.OPT_FOLLOWPIN_TIP = "Plans a trip to the game's map pin as soon as you place one."
T.OPT_FOLLOWGUIDE = "Show the way to RestedXP's next step"
T.OPT_FOLLOWGUIDE_TIP = "While RestedXP's arrow points somewhere, Ferryman draws the way there on the minimap and shows the steps when a flight or a boat is faster; /ferry stop ends it for one step."
T.OPT_CORPSERUN = "Show the way back to my body"
T.OPT_CORPSERUN_TIP = "While you are a ghost, shows the walk back to your body."
T.OPT_DRIVEPIN = "Also point the game's own map pin at each step"
T.OPT_DRIVEPIN_TIP = "Moves the game's map pin to where each step begins or ends, and puts yours back when the trip ends."
T.OPT_ARRIVESOUND = "Arrival sound"
T.OPT_ARRIVESOUND_TIP = "Plays a sound when you arrive."
T.OPT_CAUTION_0 = "Off"
T.OPT_CAUTION_1 = "Prefer safer ways"
T.OPT_CAUTION_2 = "Strongly prefer safer ways"
T.OPT_RESET = "Reset positions"
T.OPT_FORGET = "Forget what Ferryman has learned"
T.OPT_FORGET_SURE = "Forget everything Ferryman has learned, for all your characters? Their flight points will have to be read again at a flight master."

-- Key bindings
T.BINDING_HEADER = "Ferryman"
T.BINDING_WHERETO = "Open \"Where to?\""
T.BINDING_CURSOR = "Plan a trip to the spot under the map cursor"
T.BINDING_PIN = "Plan a trip to my map pin"
T.BINDING_STOP = "End the trip"
T.BINDING_STEPS = "Show or hide the steps"
T.BINDING_FIND = "Search for a place"

-- Number formats
T.FMT_SEC = "%d sec"
T.FMT_MIN = "%d min"
T.FMT_HOUR = "%d h %d min"
T.FMT_YD = "%d yd"
T.FMT_COUNT = "%d:%02d"
T.FMT_COUNT_H = "%d:%02d:%02d"

local function Round(x, step)
    return floor(x / step + 0.5) * step
end

-- Under 90 s in seconds; under 90 min in whole minutes (at least 2); else hours and minutes.
function T.Time(seconds)
    seconds = max(seconds, 0)
    if seconds < 90 then
        return format(T.FMT_SEC, Round(seconds, 1))
    end
    local minutes = Round(seconds / 60, 1)
    if seconds < 5400 then
        return format(T.FMT_MIN, max(minutes, 2))
    end
    return format(T.FMT_HOUR, floor(minutes / 60), minutes % 60)
end

-- A countdown, to the second: under a minute in seconds, then minutes and seconds, from an hour hours too.
function T.Count(seconds)
    seconds = Round(max(seconds, 0), 1)
    if seconds < 60 then return format(T.FMT_SEC, seconds) end
    if seconds < 3600 then return format(T.FMT_COUNT, floor(seconds / 60), seconds % 60) end
    return format(T.FMT_COUNT_H, floor(seconds / 3600), floor(seconds / 60) % 60, seconds % 60)
end

function T.Yards(yards)
    yards = max(yards, 0)
    return format(T.FMT_YD, Round(yards, yards < 100 and 1 or yards < 1000 and 5 or 50))
end

-- The local time of day of a server-time moment, in the player's 12 or 24 hour setting.
function T.Clock(moment)
    local d = date("*t", floor(moment))
    return GameTime_GetFormattedTime(d.hour, d.min, true)
end

local RIDE = {
    flight = "RIDE_FLIGHT", boat = "RIDE_BOAT", zeppelin = "RIDE_ZEPPELIN", tram = "RIDE_TRAM", portal = "RIDE_PORTAL",
    hearth = "RIDE_CAST", spell = "RIDE_CAST",
}

local function ShownTrip()
    local driver = ns.Driver
    local snapshot = driver and driver.Snapshot and driver.Snapshot()
    return snapshot and snapshot.trip or nil
end

function T.SpellName(id) return C_Spell.GetSpellName(id) or ("#" .. tostring(id)) end
-- A spell leg names the item it uses, else the spell; both names come from the client.
local function CastName(leg)
    if leg.item and leg.item > 0 then
        local name = C_Item.GetItemNameByID(leg.item)
        if name then
            return T.STEP_ITEM, name
        end
    end
    return T.STEP_SPELL, T.SpellName(leg.ref)
end

-- trip is optional: the trip the leg belongs to, else the trip on screen. A walk is named by what it leads to:
-- the ride or lift after it, the spot where the ground ends before the swim that ends the trip, or the trip's end.
function T.Step(leg, isLast, trip)
    local kind, name = leg.kind, leg.toName or ""
    if kind == "walk" then
        trip = trip or ShownTrip()
        if trip and trip.shore and leg == trip.legs[1] then
            return format(T.STEP_SWIM_SHORE, T.Yards(leg.swim))
        end
        for k = 1, trip and not isLast and trip.n - 1 or 0 do
            if trip.legs[k] == leg then
                local after = trip.legs[k + 1]
                return after.kind == "walk" and T.STEP_WALK_SPOT or T.Step(after, k + 1 == trip.n, trip)
            end
        end
        if trip and trip.swim then
            return format(T.STEP_SWIM_GOAL, T.Yards(leg.swim))
        elseif trip and trip.moved then
            return T.STEP_WALK_SPOT
        elseif trip and trip.dest and trip.dest.kind == "entrance" then
            return T.STEP_WALK_DOOR
        end
        return T.STEP_WALK_GOAL
    elseif kind == "lift" then
        return T.STEP_LIFT
    elseif kind == "hearth" then
        return T.STEP_HEARTH
    elseif kind == "spell" then
        local text, spellName = CastName(leg)
        return format(text, spellName)
    end
    return format(T["STEP_" .. string.upper(kind)], name)
end

function T.Riding(leg)
    local kind = leg.kind
    if kind == "lift" then
        return T.RIDE_LIFT
    elseif RIDE[kind] then
        return format(T[RIDE[kind]], leg.toName or "")
    end
    return T.Step(leg, false)
end

-- "phase": a crossing whose phase is unknown waits half a period (INTERFACES 4.4.3), so the period is twice the wait.
function T.Tag(leg)
    local tag = leg.tag
    if tag == "unconfirmed" then
        return T.TAG_UNCONFIRMED
    elseif tag == "landing" then
        return T.TAG_LANDING
    elseif tag == "estimate" then
        return T.TAG_DEPARTURE
    elseif tag == "phase" then
        return T.Pier(2 * (leg.wait or 0), "every")
    end
    return ""
end

-- What comes next at a pier (INTERFACES 5.5.11): an arrival or a departure counted down, about so many minutes when
-- estimated ("any moment" under 45 s), or only how often.
function T.Pier(seconds, what)
    if what == "every" then return format(T.PIER_EVERY, T.Time(seconds)) end
    if what == "arrives" then return T.Lands(seconds, true) end
    local a = what == "aboutArrives"
    if a or what == "aboutLeaves" then
        if seconds < 45 then return a and T.PIER_ARRIVING_ABOUT or T.LEAVES_ABOUT end
        return format(a and T.PIER_ARRIVES_ABOUT or T.PIER_LEAVES_ABOUT, format(T.FMT_MIN, max(1, Round(seconds / 60, 1))))
    end
    return seconds < 0.5 and T.LEAVES_NOW or format(T.PIER_BOARD, T.Count(seconds))
end

-- A flight's landing (INTERFACES 5.5.13), or a vessel's arrival at its next call, counted down.
function T.Lands(seconds, vessel)
    if seconds < 0.5 then return vessel and T.PIER_ARRIVING or T.LANDS_NOW end
    return format(vessel and T.PIER_ARRIVES or T.LANDS_IN, T.Count(seconds))
end

-- Who has /way (INTERFACES 10.2): Ferryman, the game's own map pin command, or another addon.
function T.Way(owner)
    if owner == "MAPPIN" then return T.WAY_GAME end
    return owner and format(T.WAY_OTHER, owner) or T.WAY_OURS
end

local DOCK = { boat = "DOCK_BOAT", zeppelin = "DOCK_ZEPPELIN", tram = "DOCK_TRAM" }
function T.Dock(entry) return format(T[DOCK[entry.kind]], entry.name) end
