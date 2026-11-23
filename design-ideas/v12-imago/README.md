# v12 — Imago

Look-only mockup; nothing here is part of the app. The user (2026-11-22): "use v11 as the starting point, but redesign the buttons and text around the reference image instead". The reference is `nasa.png` in this folder: two phone screens with a black ground, orange-red line work and mono type. It is used for its visual language only. No name, logo, wordmark or mission words from it appear here, and every word on the screen is Seasign's own.

Open `index.html`. It keeps v11's address switches: `?state=<id>`, `&bare`, `&still`, `&t=<seconds>`, `&nobtn`, `&arc` and `&nohud`. It adds two:

- **`&ink=v11`** uses v11's ink for each screen (pale yellow by day, peach at sunset, aqua at night) in place of the reference's orange-red, on the same elements, so the two can be compared. A link under the state list switches it on and off.
- **`&norim`** hides the thin outline round the screen (see below).

## What stays from v11

The whole scene is v11's, unchanged: sky, sea, the sun and moon on their path, the dotted drop line, the small square under the sun or moon, the rise and set marks on the horizon (`6:41 AM`, `4:31 PM`), grain and the twelve states. The page is v11's `index.html` with the CSS, the markup and the state code after `draw()` replaced. `draw()` itself is copied verbatim. Checked on the stills: the sky band from y 225 to the horizon matches v11 pixel for pixel, apart from the place where v11's three buttons stood.

The date, temperature and wind are v11's sample data. The events and titles are the ones in the user's mockup (below).

## The layout follows the user's own mockup (2026-11-23)

The user drew `mockup-1.png` in this folder and asked for v12 to be edited to match it. The first round's layout (four tiles at the top, events as leader rows under the view, fading titles, four filled tiles at the bottom) is replaced; it is in git history up to the commit for task 188. Positions were taken from the mockup by measuring it (it is at 2× with a phone bezel).

- **One mono face** (`ui-monospace`, which is SF Mono on Apple systems, then Menlo) for every word. No font is bundled. The status-bar clock stays in the system face.
- **Top row (y 52, 24 points tall):** at the left the mark in white: a frame with rounded upper-left and lower-right corners, a middle line and the S curve, as lines of one width. It was redrawn after the user's `logo-upper-left.png`. At the right, in the accent: the place name in capitals (`CHICAGO`) and settings, which is the app's settings symbol inside the same frame as the mark, so the two match in size and line.
- **Date tile** (white, x 34 to 111, y 91 to 169): `Mon` at the top, `/` and `Nov 16` at the bottom.
- **Events box** (accent outline, x 117 to 359, same height): the next four events, one per row. Every row is 34 characters: the time right-aligned, `A` or `P`, dashes, the title, a slash (`11:00 A ----------- Hanna’s Show /`). A title too long for the row is cut and ends in the slash with no space (`1:00 P - Wearables and sensing d/`).
- **The frame:** four white corner brackets round the view (x 34 to 359, y 180 to 426). Inside the top left, in white: the temperature over the wind (`55°F`, `wind 8/`; the wind follows the state). Inside the top right, in the accent: how long the sun or moon is up (`Daylight`, `9h 50m/`; `Moon up` at night).
- **Five titles on a dark plate** (x 29 to 364, y 445 to 728): numbers `01` to `05` at x 32, titles at x 68 on up to two lines at 10.5 points with wide spacing, all at full strength. The first row's band is a shade lighter, as in the mockup.
- **Four tiles at the bottom** (y 734 to 812), labels in capitals, a slash at the bottom left and a line icon at the bottom right: `DAY` filled with the accent (square with a ring), then outlined `LIST` (circle with a bar between two arcs), `SAVE` (eight-point star) and `LISTEN` (a wave on a dotted line).
- **A thin rounded outline in the accent** round the screen, 7 points in from the edge, broken down both sides from y 176 to 440 where the view is. `&norim` hides it.

## Where this differs from the mockup, on purpose

- Spelling in two titles is corrected: `its uses` (the mockup has `it's`) and `decisions` (`descisions`).
- The second event's letter is `P` (the mockup has a small `p`).
- The full titles behind the two cut events are invented (`Wearables and sensing demo`, `Submit hours for studio payroll`); only the visible part is the user's.
- The icons are redrawn from the mockup's small ones and are close, not traced.

## Open

- `LISTEN` is new: the app has no such feature yet. `History` (the app's ∀ button) has no tile in this layout, and the weather word and the moon's phase, which the first round showed on tiles, are not on the screen.
- The accent is `rgb(235, 78, 39)`, sampled from `nasa.png`. With `&ink=v11` at sunrise the ink is a pale cream, so the white date tile and the filled `DAY` tile look almost alike.

Stills `01-sunrise.png` to `12-moon-set.png` are rendered at 3× with headless Chrome (`--headless=new --hide-scrollbars --force-device-scale-factor=3 --window-size=393,852 --virtual-time-budget=4000`, address `?state=<id>&bare&still`), as for the other versions.
