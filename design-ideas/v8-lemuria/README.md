# v8 — Lemuria

Look-only mockup; nothing here is part of the app. Made from `v7-firmament/` as it stood on 2026-11-18 (v7 is left untouched). The user found v7 still a little cartoon or video game and asked for a push towards a futuristic HUD that stays restrained. Their references are in `ref-img/`: `hud1.png`, `horizon-hud.png` and `organic-hud.png` are the calm ones; `organic-hud-2.png` shows the kind of screen that is too busy.

Open `index.html`. Same address switches as v7: `?state=<id>`, `&bare`, `&still`, `&t=<seconds>`, `&nobtn`, `&arc`. New: `&nohud` hides the bracket, tag and horizon marks.

## The reasoning (second pass, 2026-11-18)

The user asked to push further and to think from first principles. A head-up display is a view of the world with a thin layer of read-outs over it. That gives five rules, and each one changed something:

1. **The view fills the screen.** Before, the scene was a strip between two black blocks of text, like a picture set into a page. Now the sky runs to the top (stars show faintly behind the header) and the sea runs to the bottom, with faint wave lights all the way down, brighter in a lane under the sun or moon. Dark is laid over both ends so the words read, but never to black. The film grain covers the whole screen.
2. **Nothing stands in the view.** The button column and its plate stood on the horizon and pushed the sun and moon's path to the left. The four controls (settings, list, saved, all publications; the second was labelled `DO · GET` at first and the user changed it to `LIST`) are now one row along the bottom, within thumb reach, hung from a hairline, each with its name under it. The path is centred and wider (its ends at x 62 and 331), and the horizon is clear from edge to edge.
3. **Rank by size and brightness, not by colour or boxes.** The header is two large thin read-outs, the day at the left in the ink colour and the temperature at the right in white, each under a small label (date; place). A hairline with ink ends closes it, and the three events run under it across the full width, with no box and no rule lines.
4. **Two voices.** The instrument speaks in small mono capitals and thin numerals (date, place, times, tag, control names). What people wrote keeps its own voice: event titles in Jost capitals, article titles in the serif.
5. **Every mark shows something the app knows.** Nothing decorative was added. The place name (from the zip code) is new; the rest was already in the first pass.

Also in this pass: the moon is softer (fainter craters, no pale rims, a fainter edge line), and the horizon moved down 12 points to y 388 with the top of the path 96 above it.

Given up on purpose from v7's settled layout, since the user invited a rethink: the date block beside the events, the day name sized to the date's width, the button column, `∀` in the lower right corner (it is now the fourth control), and the place name is added. Kept: serif titles without numbers, 12-hour times, no condition word or symbol at the top, the path line off, the sky gradients.

## The header as an instrument read-out (third pass, 2026-11-18)

The user asked for the part above the horizontal bar to look more technical. It replaces the header described in rule 3 above; the events under the bar are unchanged.

- The date (`2026 · NOV 16`, in ink) and the place (`CHICAGO · IL`, in white) are small mono labels in hairline boxes.
- The day name and the temperature are large light mono read-outs (the thin condensed face is gone).
- Each has a small two-line note beside it: week and day of the year next to the day (`WK 47`, `DAY 320`), latitude and longitude next to the temperature. All four come from what the app has: the date, and the place found from the zip code.
- The two boxed labels sit under the read-outs (date under the day, place under the temperature); they were above at first and the user had them moved.
- **Current arrangement (supersedes the lines above where they differ):** the day name with its week and day-of-year note is at the top left. At the top right are two boxes of equal width, one above the other: the date (`2026 · NOV 16`, ink) and the place with the temperature (`CHICAGO · 55°F`, white). Together the two boxes are exactly as tall as the day name's letters (y 64.7 to 93). The large temperature read-out, the state (`IL`) and the latitude and longitude note were removed at the user's request. The events start at y 118, 22 points under the header.
- A hairline runs from the end of the day-of-year number (`DAY 320`) towards the place box, stopping 4.7 points short of it (the same gap as at the number's end; the user asked that the line and box not touch), level with the box's bottom edge, which is also the foot of the day name. It ran through the middle of both at first; the user had it moved to the bottom. Its ends are fixed positions measured on a still, so it fits this sample text only.
- At mid-day the sky has no stars (the user asked). Clouds, rain, snow, sunrise, sunset and the night screens keep them; the faint drifting haze is kept everywhere.
- There is no bar under the header. A hairline, and then a ruler of the week (seven segments, today in ink), were tried there; the user had the ruler removed. The events sit 6 points higher to close the gap.

## Button bar under the events (2026-11-18)

At the user's request the row of four controls moved from the bottom of the screen to just under the calendar events (y 218), to leave more room for article titles. This supersedes rule 2 above where it says the controls are along the bottom. To keep the bar clear of the sun and moon's tag, the horizon moved down 16 points to y 404 and the top of the path is now 88 above it. The article list starts at y 504 and shows seven titles instead of six. The names under the four controls were then removed at the user's request; the symbols stand alone.

## Buttons beside the events (2026-11-18, supersedes "Button bar under the events" below)

At the user's request the row of four buttons was split. Settings, list and saved are one column at the right of the calendar events, 36 points apart (15.5, then 26, at first), so the column (y 118 to 247) runs a little below the events block; a vertical hairline with ink ends stood beside it at first and the user had it removed; the events are narrower (280 points) to make room. The three are muted to 38% of the ink colour at the user's request; `∀` keeps the full colour. `∀` (all publications) is smaller and sits in the lower left corner under the article list. With the row gone, the horizon moved back up to y 386 and the list starts at y 486, still with seven titles.

## Numbers on the article titles (2026-11-18)

Each title has a small mono number before it (`01`, `02`, …) in the ink colour, like a bullet; the titles start 23 points further right. v7 had dropped numbers at the user's request; the user asked for them back here in this smaller form.

## Tags on the sun and moon (2026-11-18, supersedes the tag description in the first pass below)

- On the horizon (sunrise, sunset, moonrise, moonset) nothing changed: the tag is above the body on a bent leader and reads `SUNRISE 6:41 AM` and so on, with the wind under it.
- Everywhere else the tag is level with the sun or moon, on a short straight leader out of the bracket's side, never above it.
- Away from the horizon the sun's tag no longer says `SUN` (the user: "that's obvious"); it is one line: the wind, with cloud cover, `RAIN` or `SNOW` before it. The moon's tag keeps `MOON` and the lit share on its first line.

## What changed from v7 (first pass)

- **One ink colour per screen.** The date, day name, event times, buttons and the tag's first line share one colour; everything else is white. Soft yellow by day and in weather, pale yellow at sunrise, pale peach at sunset, pale aqua at night. v7 used three colours per screen. The glow behind the day name is gone.
- **The sun reads as light, not as a drawn ball.** A near-white hot core, a warm limb, far fainter dark cells; its paler colours make the soft light round it stronger. It still churns and flickers, and the rippling outer line at rise and set is kept, thinner and paler. The rotating pale ring from v6 is gone.
- **Thinner weather.** Clouds are flatter, wider bands; rain is longer, finer lines; snow is smaller.
- **Three instrument marks, each showing something the app knows:**
  1. Corner brackets round the sun or moon (only the corners above the horizon), with a short leader to a two-line tag in small mono type. First line: `SUN`, or `MOON` with the lit percentage; on the horizon it becomes `SUNRISE 6:41 AM`, `SUNSET …`, `MOONRISE …`, `MOONSET …`. Second line: wind, with the cloud cover, `RAIN` or `SNOW` before it when there is any. The tag sits to the right of the body in the left half of the sky and to the left in the right half.
  2. The horizon as a scale: one small tick an hour between rising and setting, longer at the two ends, where the rise and set times are written under the horizon. When the body is on the horizon the time under it is hidden (the glare swallows it; the tag gives it instead).
  3. A small ink square on the horizon under the body, and a dotted drop line to it when the body is high.
  The marks are drawn after the soft light, so they stay crisp, and before the grain, so the grain lies over them.

## Kept from v7 on purpose

Serif article titles without numbers, 12-hour times, temperature only at the top, the path line off (`&arc` shows it), the sky gradients, the stars, grain, water glints, and the size of the sun and moon at rise and set.

## Decided without being asked

- The wind and cloud figures in the tag are sample values; the app has both from its weather source.
- Nothing invented is shown (no coordinates, angles or decorative read-outs).

Stills `01-sunrise.png` … `12-moon-set.png` are rendered at 3× with headless Chrome, as for the other versions.
