# v7 — Firmament

Today as an open night-black sky over the sea. Built from `v6-hud2/` with the portal ring and its beams taken out. Look only; no app code. There is no reference image for this version.

- The horizon is at the middle of the screen. The sun and moon travel one low glowing arc that stays close to it (its top is about a quarter of the way from the horizon to the top of the screen), leaving the upper sky open. It rises out of the water at the left and sets into the water at the right, so the path crosses the sea's horizon at both ends. At sunrise, sunset, moon rise and moon set the sun or moon sits half in the water, with its light spilling down the sea below it.
- The arc keeps v6's light: it thickens and thins along its length, a pulse runs along it, and it is brightest near the sun or moon.
- Stars and thin haze fill the whole sky. They sit on one wheel centred on the middle of the horizon and turn very slowly clockwise (about one turn in 70 minutes), so they rise at the left and set at the right like the sun. They twinkle; they leave no trails.
- Clouds, rain and snow are gathered round the sun or moon and thin out away from it.
- Kept from v6 unchanged: the sun's burning-gas face and the moon's craters and phases, the soft light and film grain, the straight horizon and sea glints, the header (date, day, weather sign, temperature, condition), the three events, the button column at the right (moved up with the horizon, list still centred on it), `»`, the article titles (now six, in the larger sea), and warm accents by day with cool accents at night.
- `index.html` is the animated mockup. Open it in a browser (`open design-ideas/v7-firmament/index.html`) and pick a state, or step through with the arrow keys. `?state=<id>&bare&still&t=<seconds>` draws one frame.
- `01-sunrise.png` … `12-moon-set.png` are stills of the same twelve states as `design-ideas/v1-original/`, at iPhone size.
- `fonts/` holds a copy of the app's Jost font so the page works offline.

Decided without being asked: the arc carries on faintly under the water for a short way; the band of white light that sat inside the portal went with the portal; the arc is narrower than the screen so the setting sun clears the button column; the sea glints and the light on the water follow the sun or moon; the star field is new (spread over the whole sky), not v6's dust.
