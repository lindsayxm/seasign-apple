# v6 — HUD 2

Today as a second head-up display, after `design-ideas/ref-img/v6-hud2/hud2.png`. Look only; no app code.

- A ring in the middle turns very slowly clockwise (about one turn in twelve minutes). The pieces round it overlap, vary in width and brightness, and are broken and uneven along their length. Star dust is born at its edge and circles it clockwise, quickly at first and more slowly as it works its way outward, and teal beams shoot outward until they leave the screen (those heading down pass behind the horizon).
- Each beam fires in a new direction with its own start, length, width and brightness, and its light is uneven along its length. A blurred copy of the picture is laid over it for soft light, with film grain on top. The horizon is one straight line.
- The window inside the ring stays level. A band of white light fills its lower part; the sun rises where that band meets the ring on the left, crosses a low glowing arc, and sets where the band meets the ring on the right. The moon takes the same path and shows its phase. Clouds, rain and snow are drawn inside the window.
- Upper left: date, day, a weather sign, temperature and condition (the time is left to the phone's own clock). Upper right: the next three events. Below the horizon: the three symbols and `»`. Lower sea: five article titles.
- Buttons and highlighted text are warm by day (amber, orange, peach) and cool at night (aqua, blue, ice); the two sets are never mixed.
- `index.html` is the animated mockup. Open it in a browser (`open design-ideas/v6-hud2/index.html`) and pick a state, or step through with the arrow keys. `?state=<id>&bare&still&t=<seconds>` draws one frame.
- `01-sunrise.png` … `12-moon-set.png` are stills of the same twelve states as `design-ideas/v1-original/`, at iPhone size.
- `fonts/` holds a copy of the app's Jost font so the page works offline.

Decided without being asked: the scene stays black and silver in every state, and only the sun or moon, the band of light and the weather change; the phone's clock shows a sample time that matches each state.
