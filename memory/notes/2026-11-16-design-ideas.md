# Design exploration in `design-ideas/` (2026-11-16)

Look-only mockups of the Today screen. Nothing here is in the app; an idea is built in `ios/` only after the user picks it.

| folder | idea | state |
|---|---|---|
| `v1-original/` | the app as built: 12 Simulator screenshots and a web page recreation | reference |
| `v2-halo/` | ring-of-light sun and moon, glow and shimmer | tried, tweaked once |
| `v3-cyclo/` | navy sky, small sun/moon on a drawn arc, symbols upper left | tried |
| `v4-cartography/` | off-white paper by day, charcoal at night, weather as a sign | tried |
| `v5-hud/` | fixed dial; warm colours by day, aqua to white at night | tried |
| `v6-hud2/` | rotating portal ring with beams and swirling dust | refined over many rounds; base for v7 |
| `v7-firmament/` | v6 without the ring and beams: open sky of slowly wheeling stars, sun and moon on a tall arc that rises from and sets into the sea | refined over many rounds on 2026-11-17 (section below); saved as it stood on 2026-11-18; base for v8 |
| `v8-lemuria/` | v7 pushed towards a restrained HUD: one ink colour per screen, hairline button frame, sun and moon as light, bracket and tag on the body, rise and set marks on the horizon | refined through #100–#122 on 2026-11-18; the user then said "this one is done" |
| `v9-pangea/` | clean slate: vintage machine screen (segment read-outs, ruled tables, wire-mesh scope, meters, keycaps) from the user's references in its `ref-img/` | first pass 2026-11-18 (#123) |
| `v10-simplify/` | clean slate: very simplified Japanese-print look (paper, flat red sun or cream moon, solid indigo sea with wave lines, upright date column, red seal) | two rounds 2026-11-18 (#124–#126) |
| `v11-artemis/` | copy of v8 with v7's header (date, day, temperature, events box) | started 2026-11-18 (#131); the version the user is iterating on |
| `v0-version-landing-page/` | index page: a thumbnail per version that opens it | made 2026-11-17 |

How the mockups are made, so the next session can continue:

- Each version is one self-contained `index.html` (canvas scene, HTML text on top, seeded random numbers, no CDN). `?state=<id>&bare&still` draws one frame; v6 also takes `&t=<seconds>`.
- The twelve state ids: `sunrise, mid-day, sunset, clouds, rain, snow, moon-rise, mid-night, moon-waxing, moon-waning, moon-full, moon-set`. Stills are `01-sunrise.png` … `12-moon-set.png`.
- Stills are rendered with headless Chrome at 393×852, device scale 3 (`--headless=new --force-device-scale-factor=3 --window-size=393,852 --virtual-time-budget=4000 --screenshot=...`). The helper scripts lived in the session scratchpad and are gone; rewrite them from this line.
- Motion cannot be watched from the agent side. Check it by rendering two frames a couple of seconds apart and comparing.
- In v6, add new random values with a separate `prng(...)` or `hash(...)`: drawing more numbers from the shared `rnd` shifts every list created after it and changes the beams and ring pieces the user approved.

What the user has settled for v6 (see `design-ideas/v6-hud2/README.md` for the full description):

- Straight sea horizon; no staggered side panels (those were an artefact of the reference image).
- Soft, realistic light: glow, blur, grain, uneven pieces; not clean vector shapes.
- Very slow clockwise ring; dust spirals slowly outward; beams infrequent and subtle, shooting straight out.
- Accents (buttons, highlighted text) warm by day and cool at night, never mixed.
- Header: month and day only, day name, then weather sign, temperature, condition. No year and no time.
- Buttons in one column at the right: settings above the horizon, list centred on it, saved below.

Open in v6: the beams keep a teal core and yellow glow in every state (the user was asked whether they should follow the warm/cool rule and has not answered). v2, v3 and v4 draw the settings, list and saved symbols from memory; v1, v5 and v6 use the app's real ones.

## 2026-11-17: v7-firmament and the landing page

`v7-firmament/` is now the version the user is refining (tasks #45–#97); `v0-version-landing-page/` (#98) is an index page with a thumbnail per version. The full description of v7 is in `design-ideas/v7-firmament/README.md`; read it before changing anything.

What the user has settled for v7:

- No portal ring and no beams. Open sky of stars on one very slow wheel; horizon at y 376; everything below is placed from the horizon.
- Sun and moon follow a low path (100 points high) left of centre. They are far larger at rise and set (about 100 points across) than high in the sky (24). The line of the path is currently switched off (`?arc` shows it); the user wanted to see the look without it and has not said whether it stays off.
- Sun: solid edge, with a see-through, glowing, uneven dark orange line rippling outside it near the horizon. Moon: rough face with irregular craters and grain.
- Sky gradients by day (blue), sunrise (yellow, peach, light blue) and sunset (orange, red, pink): the user called these "perfect"; do not change them.
- Header: left-aligned with the clock (x 34). Date, condensed light day name as wide as the date, temperature only (no weather symbol, no condition word). Events in spaced Jost capitals at 11 points, 12-hour times, AM/PM/ALL in one aligned column. The date block's top and bottom are level with the events' text.
- Article titles: serif (Iowan Old Style), sentence case, no numbers, left edge at x 34.
- Buttons: flat colour per state (yellow-orange by day, #ffffcc at sunrise, #ffcdba at sunset, aqua at night) on a dark blue see-through panel with a top glow (dark pink at sunset) and bottom shadow. `∀` (all publications) is at the bottom right, centred under the column.
- Header accents are yellow in mid-day, clouds, rain and snow; orange at sunrise and sunset; cool at night.
- Gulls crossing once a minute (one to three) were tried on 2026-11-17 and removed on 2026-11-18: the user found them too much.

Tried and rejected by the user (do not repeat): signal-yellow and strong-blue buttons; a separate colour for the list button; drop shadows on the three right-hand buttons; the panel wholly above the horizon with a reversed gradient; a rippling edge on the sun itself; serif for calendar events.

Working method that held up: positions and gaps were set by measuring rendered stills (pixel rows of the text), not by eye. `?nobtn` draws a frame without buttons for measuring what is behind them. The landing page's thumbnails are copies of each version's `02-mid-day.png` and `08-mid-night.png` and must be remade when stills change.

## 2026-11-18: v8-lemuria

The user said v7 still felt like a cartoon or video game and asked for a v8 pushed towards a futuristic HUD, "but keep it constrained"; some of their references (`design-ideas/v8-lemuria/ref-img/`) they called much too busy. They like the grain, the burning sun and the shimmering water. v7 is frozen; work continues in v8. First pass: see `design-ideas/v8-lemuria/README.md` for what changed and what was kept from v7's settled decisions (serif titles, 12-hour times, no condition word at the top, no title numbers, path line off, sky gradients).

Second pass the same day (#101), after "push v8 further - think from first principles": the view now fills the screen (sky to the top, sea with faint wave lights to the bottom, grain over everything); the button column is gone and the four controls are a labelled row along the bottom; the sun and moon's path is centred and wider; the header is a large thin day name and temperature under small date and place labels, then the events across the full width. This gave up several of v7's settled layout choices on purpose (listed in the v8 README); the user had invited a rethink.

Third pass (#102), "make the top a little more technical looking": boxed mono date and place labels, large light mono day and temperature with small two-line notes (week and day of year; latitude and longitude), and the bar as a seven-segment week ruler with today in ink.

The week ruler was removed at the user's request straight after (#103); the header now has no bar.

The boxed date and place labels were then moved below the day and temperature at the user's request (#104).

Then (#105) the user had the right column stacked as boxed date, boxed place, temperature, with the coordinates removed; the day name and its week/day note stay at the top left.

Then (#106): the large temperature went; the place box reads `CHICAGO · 55°F`, and the date and place boxes together are exactly as tall as the day name. Events moved up to y 118.

Then (#107, #108): the second control is labelled `LIST`; the button bar moved from the bottom to just under the events, the horizon went down to y 404 (path top 88) to clear it, and the list shows seven titles.

Then (#109–#111): control labels removed; a hairline from the day number to the place box, level with the box's bottom; no stars on the mid-day screen (v7 had them by day at the user's earlier request, so this applies to v8 mid-day only unless they say more).

Then (#112, #113): the header line stops short of the place box; away from the horizon the sun's tag drops the word SUN and every tag sits level with the body (never above it); rise and set tags unchanged.

Then (#114): settings, list, saved became a column at the right of the events; a smaller `∀` went to the lower left corner; horizon back up to y 386.

Then (#115–#120): bare button column, muted to 38%, 36 points apart, centred on x 331 above the setting sun or moon; small numbers `01`… before the article titles (the user asked for them back); event times shortened to `6:45p` / `TUE` (a stacked hour-over-PM form was tried and dropped).

Then (#121, #122): more space between the events and the buttons; `∀` raised 18 points. After that the user said of v8: "great this one is done". Treat v8 as finished as it stands at the #122 commit; the full current state is in `design-ideas/v8-lemuria/README.md`. They have not yet said whether to build it in `ios/`.

## 2026-11-18: v9-pangea

After calling v8 done the user asked for "a few more designs first" and a clean-slate v9: "design a vintage computer interface that shows all the relevant info", from five references in `design-ideas/v9-pangea/ref-img/`. First pass built (#123); see its README. Nothing is being built in `ios/` yet.

## 2026-11-18: v10-simplify

"ok one more - v10 - look at the reference images - make a very simplified japanese art inspired version". First pass built (#124); see its README for what is shown and what was left out on purpose.

Second round on v10 (#125): bolder, larger bottom marks; titles higher; fainter wave lines that roll like waves; rain and snow start below the events and are more see-through; events in the medium weight.

## 2026-11-18: back to v7, then v11-artemis

After v10 the user went back to v7 for small changes (#127–#130: no stars at mid-day, muted panel buttons, panel almost solid, extra glow round the panel at sunset), then asked to copy v8 into v11 "and then we'll iterate on it there", with v7's date/day/temperature and calendar layout at the top (#131). v11 is now the working version.

## 2026-11-19: v11 after the app build

- The user had the rise and set tags removed (mockup and app, tasks #148 and #149); the wind line now shows on every screen. v11 stills `01`, `03`, `07`, `12` re-rendered.
- The mockup helper was rewritten once more: a loop over the twelve state ids calling headless Chrome with `--headless=new --hide-scrollbars --force-device-scale-factor=3 --window-size=393,852 --virtual-time-budget=4000 --screenshot=<folder>/NN-<state>.png "file://<folder>/index.html?state=<state>&bare&still"`. Unchanged screens render byte-identical, so `git status` shows exactly which stills a change touched.
