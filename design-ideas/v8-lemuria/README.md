# v8 — Lemuria

Look-only mockup; nothing here is part of the app. Made from `v7-firmament/` as it stood on 2026-11-18 (v7 is left untouched). The user found v7 still a little cartoon or video game and asked for a push towards a futuristic HUD that stays restrained. Their references are in `ref-img/`: `hud1.png`, `horizon-hud.png` and `organic-hud.png` are the calm ones; `organic-hud-2.png` shows the kind of screen that is too busy.

Open `index.html`. Same address switches as v7: `?state=<id>`, `&bare`, `&still`, `&t=<seconds>`, `&nobtn`, `&arc`. New: `&nohud` hides the bracket, tag and horizon marks.

## What changed from v7

- **One ink colour per screen.** The date, day name, event times, buttons and the tag's first line share one colour; everything else is white. Soft yellow by day and in weather, pale yellow at sunrise, pale peach at sunset, pale aqua at night. v7 used three colours per screen. The glow behind the day name is gone.
- **The sun reads as light, not as a drawn ball.** A near-white hot core, a warm limb, far fainter dark cells; its paler colours make the soft light round it stronger. It still churns and flickers, and the rippling outer line at rise and set is kept, thinner and paler. The rotating pale ring from v6 is gone.
- **Thinner weather.** Clouds are flatter, wider bands; rain is longer, finer lines; snow is smaller.
- **Button frame.** The rounded glowing panel is now a flat dark plate with a hairline edge, short ink-coloured corners and two faint dividers.
- **Three instrument marks, each showing something the app knows:**
  1. Corner brackets round the sun or moon (only the corners above the horizon), with a short leader to a two-line tag in small mono type. First line: `SUN`, or `MOON` with the lit percentage; on the horizon it becomes `SUNRISE 6:41 AM`, `SUNSET …`, `MOONRISE …`, `MOONSET …`. Second line: wind, with the cloud cover, `RAIN` or `SNOW` before it when there is any. The tag sits to the right of the body in the left half of the sky and to the left in the right half.
  2. The horizon as a scale: one small tick an hour between rising and setting, longer at the two ends, where the rise and set times are written under the horizon. When the body is on the horizon the time under it is hidden (the glare swallows it; the tag gives it instead).
  3. A small ink square on the horizon under the body, and a dotted drop line to it when the body is high.
  The marks are drawn after the soft light, so they stay crisp, and before the grain, so the grain lies over them.

## Kept from v7 on purpose

Layout (clock, date block, events, horizon at y 376, button column, `∀`, article list), serif article titles without numbers, 12-hour times, temperature only at the top, the path line off (`&arc` shows it), the sky gradients, the stars, grain, water glints, the moon, and the size of the sun and moon at rise and set.

## Decided without being asked

- The wind and cloud figures in the tag are sample values; the app has both from its weather source.
- Nothing invented is shown (no coordinates, angles or decorative read-outs).
- The moon's surface was not redrawn.

Stills `01-sunrise.png` … `12-moon-set.png` are rendered at 3× with headless Chrome, as for the other versions.
