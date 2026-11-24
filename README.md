# BootyBayBroker Ferryman

Ferryman is an addon for World of Warcraft: Forever (interface 16001). It works out the fastest way from where
your character stands to where you want to go, over walking and swimming, the flight paths this character has
learned, boats and zeppelins with their waits, the Deeprun Tram, lifts, portals, the Hearthstone and the class
spells that move you. Then it leads you there with an arrow, a trail on the minimap and the world map, and a
short list of steps. Nothing of it is on screen while no trip is set, except what a boat or zeppelin does next
while you stand at its dock or ride it, and a side trail, a round, an arrow or places another addon asked for; the
trip's own marks go away when you arrive.

It is built from the game's own client data and from measurements taken in play, and it depends on no other
addon.

## Install

Copy the three folders of this repository into `Interface\AddOns` under your WoW Forever install: the addon,
`BootyBayBrokerFerryman`, and its two walking-map folders, `BootyBayBrokerFerryman_EasternKingdoms` and
`BootyBayBrokerFerryman_Kalimdor`, one per continent. Then type `/reload` in game, or start the game. Each
released version is also a zip on this repository's Releases page, holding the same three folders.

## Use

- Alt-click a spot on the world map to plan a trip there.
- `/ferry`, the Ferryman button on the world map, the addon compartment or a key binding opens "Where to?":
  pick a spot on the map, a dungeon or raid entrance (sorted by travel time from where you are), your map pin,
  your tracked quest, a party member, end the trip, or the options.
- Type a place: `/ferry Elwynn Forest 42 65 Goldshire`, or `/ferry 42 65` for the zone you are in.
- Search for a place: click the round search button (drag it anywhere; an option hides it), or type `/ferry find`,
  and start typing: `inn`, `bank`, `auc`, `fm`, a town, a zone, a dungeon. Up to six places are listed, the best
  match first and then the nearest by travel time, each with its time once it is planned. Enter or a click starts
  the trip; Escape or a click on the world closes the box. The places come from the game's own files and from
  the windows you open: once you have used an auctioneer, a banker, a trainer, a mailbox and so on, the finder
  lists them by name, for every character of your account. Asking a city guard for directions teaches the place
  the guard points to, and an NPC with a title that you target or put the cursor on is listed as "seen near here".
  A service none of whose places is known in your zone says so, and so does a kind of trainer your game has not
  shown you yet; a trainer whose window you open is listed from then on as your game saw it.
- At a flight master, the flights to take are drawn on the flight map and the destination is ringed. You
  click; Ferryman never takes a flight for you.
- Point at a flight point on the flight map and its tooltip says how long the flight takes ("Flight: 3 min"), the
  time Ferryman plans it at; an option turns it off.
- Right-click a step for "Plan without this". Walking away from a step's boarding point or cast also drops it
  for this trip, and clicking the "Skipped" line brings it back.
- Drag the arrow by any part of it, the arrow or its two lines, to move it; right-click it, or click the red X on
  the steps, to end the trip.
- Standing within 60 yd of a boat or zeppelin dock, with no trip or on the way to it, the arrow's two lines show
  where it goes and what it does next there, counted down to the second once Ferryman has timed a ride of it:
  "arrives in 48 sec", "boarding, leaves in 3:20", "leaving now". Later, while the timetable is only an estimate,
  in whole minutes: "leaves in about 3 min", "leaves any moment". Before any ride, "every 5 min, not
  timed yet", which never counts: ride it once and the times are known. On the deck the lines say "On the boat to
  Powderfuse Port" over "arrives in 1:13".
- Ferryman keeps one timetable a boat and realm, across days, restarts and new game builds: rides close together
  sharpen it, a later one keeps it on that ride's departure, and one that does not fit starts it again. On a new game build it is an estimate until
  you ride once on that build. Where the addon's data carries a measured period for the route, a single ride keeps
  an estimate for about two weeks; on the other routes for about four hours. The realm runs several copies (layers)
  of each zone; the game gives no way to tell which you are on, and Ferryman does not try.
- On any flight, the arrow's two lines show where it lands and when: "Flying to Lakeshire" over "lands in 2:05",
  through a middle stop too.
- Inside the Deeprun Tram, the arrow's two lines show where the platform's train goes and how often one leaves:
  "Tram to Ironforge" over "every 72 sec, not timed yet". On the train they say "On the tram to Ironforge" over
  "arrives in 42 sec". A destination given there is planned from the door you leave by.
- Dead and released, a ghost is led back to its body on foot at the ghost's own speed, the arrow's second line
  saying "45 sec to your body". `/ferry stop` ends that for one death; Settings turns it off.
- A destination on an island no walk reaches, or out in the water, is led to the nearest ground within 1,000 yd
  that a walk reaches; where that is in the water, the last step says how far is left to swim. From such an
  island the first step is the swim to the shore.
- With RestedXP running a guide, Ferryman draws the way to its next step on the minimap and the world map, and
  shows the steps when a flight, boat, tram or portal is faster than walking, or when your Hearthstone would save
  time ("Hearthstone available: saves 11 min."). Its own arrow shows only where RestedXP's cannot lead, such
  as across the sea. `/ferry stop` ends it for that step. While RestedXP's guide window is hidden, Ferryman
  follows nothing of it.
- Another addon can ask Ferryman for a side trail: a walk to one spot nearby, such as a node it found, drawn as a
  separate line of small blue dots on the minimap and the world map. It stands beside your trip without changing
  it, and goes when you reach the spot or that addon takes it away, and also when you go far from it, take a
  flight, die or pass a loading screen.
- Another addon can also hand Ferryman a whole round, such as a farming route, drawn on the world map as blue dots
  under the side trail and, where it passes you, on the minimap as the same small blue dots, so you see the route and
  ride along it. Ferryman never follows it; it stays, whatever your trip and the side trail do, until that addon takes
  it away or an addon hands over another, and a reload drops it. While dots of its round are on the minimap, that
  addon's own side trail is not drawn there: the round is drawn once.
- That addon can also point Ferryman's arrow at a spot of its round: the arrow you know from trips, in the place you
  dragged it to, in blue, aimed straight at the spot with the yards to it. It shows while no trip of yours has the
  arrow and waits behind one; "Show the arrow, distance and time" hides it too.
- Another addon can ask Ferryman where the nearest trainer of a profession stands, or where an NPC it names stands,
  from the places your game has learned, and offer you the trip
  there with one click.
- Another addon can hand Ferryman places it keeps, such as where its players found treasure chests, in named sets:
  each is drawn as a small chest on the world map of its zone and on the minimap near you, the set's name shown when
  you point at one on the world map. A mark is a place where something was found, never a promise that it is there.
  An option turns them off; a reload drops them until that addon hands them over again.
- With "Plan a trip when I place a map pin" on, placing a map pin plans a trip to it, or, during a trip
  that did not come from a map pin, offers it as a one-click line in the steps.
- "Travel planner", the first row of the options, turns Ferryman's own navigation off and on again at once: off, the
  map button, the search button, Alt-click, following a map pin or RestedXP and the run back to your body are gone,
  and `/ferry`, `/way`, the key bindings and the addon compartment open the options. What another addon draws
  through Ferryman (its trips, side trail, round, arrow and places) still shows. Another addon can read and set it
  with `Ferryman.Planner()` and `Ferryman.SetPlanner(on)`.

## Commands

`/ferryman` and `/ferry` are the same command.

| Command | Does |
|---|---|
| `/ferry` | opens "Where to?" (with "Travel planner" off, every `/ferry` command opens the options) |
| `/ferry [#uiMapID or zone name] x y [title]` | plans a trip; also `/ferry to ...` |
| `/ferry find [text]` | opens the search box, with the text in it |
| `/ferry stop` | ends the trip |
| `/ferry options` | opens the options (in combat they open when the fight ends) |
| `/ferry learned` | prints what Ferryman has learned |
| `/ferry learned forget [fact]` | forgets one fact (its key is printed in brackets), or `all` |
| `/ferry steps`, `/ferry arrow` | shows or hides the steps, the arrow |
| `/ferry guide` | turns following RestedXP's next step on or off |
| `/ferry pin` | plans a trip to your map pin |
| `/ferry bench` | times the planner in the client and prints frame figures |
| `/ferry check` | reports whether the map, minimap and flight window are still untouched by addon code |
| `/ferry help` | lists the commands and says who owns `/way` |

Coordinates are two numbers from 0 to 100, separated by spaces or a comma, with or without a percent sign. A
zone name is matched against the game's own map names in your language. `/way` takes the same form when no
other addon has registered it.

Key bindings (under Ferryman, none set by default): open "Where to?", plan a trip to the spot under the map
cursor, plan a trip to my map pin, end the trip, show or hide the steps, search for a place.

## Options

One page in the game's Settings panel, under AddOns: show, size and lock the arrow and the steps; draw the trip
on the world map and the minimap; show the search button; show flight times on the flight map; show other addons'
places on the maps; how close counts as arrived (15 yards); suggest the Hearthstone only when it
saves at least 5 minutes; use travel spells; change flights on the way (off: a trip never lands at a flight master to
take another flight there; on, only when that saves at least 1 minute, up to 10); avoid enemy towns and areas too high for your level (off, prefer
safer ways, strongly prefer them); plan a trip when you place a map pin; show the way to RestedXP's next step
(when RestedXP is loaded); also point the game's own map pin at each step (off); the arrival sound; reset
positions; forget what Ferryman has learned.

## What it learns, and where

Some facts differ per character or change over time, so Ferryman learns them as you play:

- the flight points each character has, read when the flight map is opened at a flight master, per continent;
- the hops the game flies between two flight masters, from the flight map;
- where the Hearthstone lands, from a cast or from binding at an inn;
- how fast the character travels on land and in water;
- where in its round a boat or zeppelin is, from riding it, with or without a trip, one timetable a realm that lasts
  across game builds (the round trip
  itself and every crossing's time ship with the addon, worked out from the game's own path of each vessel);
- where a class teleport lands, an entrance the game files do not place, and a portal they do not list;
- corrections to flight speed, and how long loading screens take;
- for the finder, who serves where: each vendor (and whether it repairs), trainer, banker, auctioneer, mailbox,
  innkeeper, stable master, barber and guild vault whose window you open or who offers it when you talk to them,
  the places city guards point you to, and the titled NPCs you look at, at most 1,000 places for the account
  (`/ferry learned forget places` forgets them).

Everything is kept in the saved variable `FerrymanDB`: flight points, the Hearthstone, speeds, portals and the
current trip per character, departure times per realm, and corrections to shipped figures and the finder's
places per account. Facts
record the game build they were learned on, and anything that fails validation at login is dropped.
`/ferry learned` lists them; `/ferry learned forget` and a button in the options forget them. Nothing is sent
to other players.

## This repository

It holds the addon exactly as it is released: the three folders above, byte for byte the files of the release's
zip, one commit a release, tagged `v<version>`. Each release's zip is signed (minisign); its SHA-256 is in the
release notes.

## Problems

Report them at https://github.com/TheMizeGuy/BootyBayBrokerFerryman/issues

## Licence

All rights reserved. Copyright (c) 2026 TheMizeGuy. You may install and run the addon and read its source; copying
it elsewhere, publishing a changed version or using its code, artwork or data in another project needs written
permission. The terms are in `LICENSE`.
