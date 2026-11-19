# v9 — Pangea

Look-only mockup; nothing here is part of the app. A clean slate: it does not build on v1–v8. The user asked for "a vintage computer interface that shows all the relevant info", from the references in `ref-img/`: a yellow-green wire-mesh terrain display, a white-on-black terminal collage (tables, a scope trace, diagrams), a printed specification table (Rhodia), a flat drawing of a keyboard with cream, orange and teal keys, and a glowing stereo display (segment digits, bar meters, small teal labels, a red zone).

Open `index.html`. Address switches: `?state=<id>` (the same twelve ids as the other versions), `&bare`, `&still`, `&t=<seconds>`, `&nobtn`.

## What is on the screen, top to bottom

1. **Title strip**, reversed out like a terminal's status line: `SEASIGN · 16 NOV 2026` and the place.
2. **Two lit read-outs** drawn segment by segment, with the unlit segments faintly visible as on a glass display: the day name in amber (fourteen-segment letters) and the temperature in cream. Small teal names under them.
3. **Events table**: a ruled table with a headed row; times in amber (`6:45p`, `TUE`), titles in Jost capitals.
4. **The scope**: a line drawing behind rounded glass, the only moving part.
   - The sun or moon on a dotted arc (dots already passed are brighter), with hour marks on the horizon. It is larger near the horizon.
   - The sun is a lit disc in a ring with short turning rays. The moon is an outlined disc, lit part filled, dark part hatched.
   - The sea is a wire mesh running to the horizon, its lines rising and falling, brighter in a lane under the sun or moon.
   - Clouds are stacked strokes, rain is dashes, snow is small crosses, stars are points and crosses (night; a few at sunrise and sunset; none by day).
   - Top left: four weather lamps, `CLEAR CLOUD RAIN SNOW`; one is lit and the others stay faintly visible. Top right: what is tracked (`MOON 50%`, `SUNRISE`, `MOONSET` …); nothing for a high sun, which needs no name.
   - The trace colour is the only thing that changes with the time and weather: yellow-green by day, amber at sunrise, red-orange at sunset, paler in cloud, grey-blue in rain, near white in snow, teal at night.
5. **Meters**: a thirty-segment bar for how far the sun or moon is along its path (`DAYLIGHT` or `MOON UP`), amber with the last four segments red, and the rise and set times under its ends. Then two small teal bars: wind (full scale 30 mph) and cloud cover.
6. **Reading table**: seven numbered article titles in a ruled table, Jost in sentence case.
7. **Four keys** with their names printed above: settings and list in cream, saved in teal, all publications in orange.

Over everything: fine scan lines, darker corners, and a soft glow round whatever is lit on the canvas.

## Decided without being asked

- Fixed machine colours (cream, amber, teal, red-orange); only the scope's trace changes by state.
- Jost for the tables (close to the printed table in the references), system mono for labels; no new fonts.
- Wind and cloud figures are sample values; the app has both from its weather source. Nothing invented is shown.
- The teal and orange keys are decoration from the keyboard reference; which key gets which colour carries no meaning yet.
- Seven titles, as in v8.

Stills `01-sunrise.png` … `12-moon-set.png` are rendered at 3× with headless Chrome, as for the other versions.
