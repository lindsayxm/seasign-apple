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
| `v8-lemuria/` | v7 pushed towards a restrained HUD: one ink colour per screen, hairline button frame, sun and moon as light, bracket and tag on the body, rise and set marks on the horizon | first pass 2026-11-18 (#100); awaiting the user's reaction |
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
