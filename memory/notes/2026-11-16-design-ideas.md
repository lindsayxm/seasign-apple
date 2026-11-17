# Design exploration in `design-ideas/` (2026-11-16)

Look-only mockups of the Today screen. Nothing here is in the app; an idea is built in `ios/` only after the user picks it.

| folder | idea | state |
|---|---|---|
| `v1-original/` | the app as built: 12 Simulator screenshots and a web page recreation | reference |
| `v2-halo/` | ring-of-light sun and moon, glow and shimmer | tried, tweaked once |
| `v3-cyclo/` | navy sky, small sun/moon on a drawn arc, symbols upper left | tried |
| `v4-cartography/` | off-white paper by day, charcoal at night, weather as a sign | tried |
| `v5-hud/` | fixed dial; warm colours by day, aqua to white at night | tried |
| `v6-hud2/` | rotating portal ring with beams and swirling dust | the one the user is refining |

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
