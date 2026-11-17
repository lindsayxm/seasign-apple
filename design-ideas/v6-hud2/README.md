# v6 — HUD 2

Today as a second head-up display, after `design-ideas/ref-img/v6-hud2/hud2.png`. Look only; no app code.

- A ring in the middle turns very slowly clockwise (about one turn in twelve minutes). The pieces round it overlap, vary in width and brightness, and are broken and uneven along their length. Star dust drifts outward from it, and teal beams shoot outward until they leave the screen (those heading down pass behind the horizon).
- Each beam fires in a new direction with its own start, length, width and brightness, and its light is uneven along its length. A blurred copy of the picture is laid over it for soft light, with film grain on top. The horizon is one straight line.
- The window inside the ring stays level. A band of white light fills its lower part; the sun rises where that band meets the ring on the left, crosses a low glowing arc, and sets where the band meets the ring on the right. The moon takes the same path and shows its phase. Clouds, rain and snow are drawn inside the window.
- Upper left: date, day, time, temperature and a weather sign. Upper right: the next three events. Below the horizon: the three symbols and `»`. Lower sea: five article titles.
- `index.html` is the animated mockup. Open it in a browser (`open design-ideas/v6-hud2/index.html`) and pick a state, or step through with the arrow keys. `?state=<id>&bare&still&t=<seconds>` draws one frame.
- `01-sunrise.png` … `12-moon-set.png` are stills of the same twelve states as `design-ideas/v1-original/`, at iPhone size.
- `fonts/` holds a copy of the app's Jost font so the page works offline.

Decided without being asked: the palette stays as in the reference in every state (black and silver, amber accents, teal figures), and only the sun or moon, the band of light and the weather change; the time shown is a sample that matches each state.
