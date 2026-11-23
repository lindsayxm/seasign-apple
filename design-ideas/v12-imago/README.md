# v12 — Imago

Look-only mockup; nothing here is part of the app. The user (2026-11-22): "use v11 as the starting point, but redesign the buttons and text around the reference image instead". The reference is `nasa.png` in this folder: two phone screens with a black ground, orange-red line work and mono type. It is used for its visual language only. No name, logo, wordmark or mission words from it appear here, and every word on the screen is Seasign's own.

Open `index.html`. It keeps v11's address switches: `?state=<id>`, `&bare`, `&still`, `&t=<seconds>`, `&nobtn`, `&arc` and `&nohud`. It adds two:

- **`&ink=v11`** uses v11's ink for each screen (pale yellow by day, peach at sunset, aqua at night) in place of the reference's orange-red, on the same elements, so the two can be compared. A link under the state list switches it on and off.
- **`&norim`** hides the thin outline round the screen (see below).

## What stays from v11

The whole scene is v11's, unchanged: sky, sea, the sun and moon on their path, the dotted drop line, the small square under the sun or moon, the rise and set marks on the horizon (`6:41 AM`, `4:31 PM`), grain and the twelve states. The page is v11's `index.html` with the CSS, the markup and the state code after `draw()` replaced. `draw()` itself is copied verbatim. Checked on the stills: the sky band from y 225 to the horizon matches v11 pixel for pixel, apart from the place where v11's three buttons stood.

The content is v11's too: Nov 16, Mon, 55°F, the wind for each state, the three events and the five titles. The counts on the bottom tiles are mock data.

## What differs from v11

Everything that is a button or a word is redrawn:

- **One mono face** (`ui-monospace`, which is SF Mono on Apple systems, then Menlo) for every word, in mixed case. v11's spaced capitals, Jost, the condensed day name and the serif titles are gone, and no font is bundled. The phone's status-bar clock stays in the system face, because it is the phone's, not the app's.
- **Top row:** at the left, the mark (28 points, white): a frame, a middle line, the S curve through the middle and a crescent in the upper-left and lower-right corners, all drawn as lines of one width (4.5 of 100, about 1.3 points) with nothing filled. The frame's upper-left and lower-right corners are rounded; the other two are square. A first version was a filled white square with the shapes cut out; the user asked for thinner, uniform lines. It is redrawn as an inline SVG after the user's `logo-upper-left.png` in this folder (2026-11-23); until then an upside-down A stood here. At the right, one round white line button: settings, which is the app's settings symbol in a ring.
- **Four square tiles** (y 92 to 170, 6 points apart, as the reference's top row): each has a label at the top left, and a slash at the bottom left with the value at the bottom right.
  1. White, filled: `Mon` / `Nov 16`.
  2. Outlined: `55°F` / `wind 8`. The wind follows the state.
  3. Outlined: by day, the weather word (`Clear`, `Clouds`, `Rain`, `Snow`) with v11's line weather sign at the bottom right, where the reference has its small icons. At night, the moon's phase (`Full moon`, `Waxing moon`, `Waning moon`) with a small disc showing its lit part.
  4. Filled with the accent: the sun or moon's setting time (`Sunset` / `4:31 PM`, `Moonset` / `7:03 AM`), or its rising time while it is on the horizon at rise (`Sunrise` / `6:41 AM`, `Moonrise` / `5:12 PM`).
- **The frame:** four white corner brackets round the view (x 34 to 359, y 180 to 426), as round the reference's planet. The bottom corners sit under the rise and set marks. Inside the top corners are two small labels: the place (`Chicago`, the sample place from v8) in white at the left, and at the right, in the accent, how long the sun or moon is up, ending in a slash (`Daylight / 9h 50m/`, `Moon up / 13h 51m/`). Both are worked out from the rise and set times.
- **The next three events as leader rows**, written as the reference's "label/------value": `6:45 PM/---------Hanna’s show`, with the dashes filling the gap. All three fit on one line at 11 points. A longer title would be cut with an ellipsis and keep at least a short leader. The rows sit on a dark plate (60% black; v11's events box was 55%), because just under the horizon the sea is still lit, most of all under a rising or setting sun.
- **The five titles as one block of mono lines** at 11.5 points, numbered `01` to `05`, with a hanging indent where a title wraps. They fade out towards the end as the reference's paragraph does, but with a floor so the last one still reads: 100%, 100%, 86%, 68%, 56%. The numbers are a further 70% of their row, so `05` itself is at about 39%. A small down arrow sits at the right of the last line. They sit on the dark lower sea, which is about 90% black there, so they need no plate.
- **Four filled accent tiles at the bottom** (y 734 to 812), as the reference's bottom row: `Day` / `3`, `List` / `5` (it read `Do & get` until the user asked for `List` on 2026-11-22), `Saved` / `12`, `History` / `7d`. Settings is the round button at the top, so the fourth tile went to the Day screen, which the app already has (it opens from the events). History is the app's ∀ button (the last 7 days).
- **A thin rounded outline in the accent** round the screen, 7 points in from the edge, as the reference's phone outlines. It is broken down both sides from y 176 to 440, so it never crosses the view or a rising or setting sun or moon. `&norim` hides it.
- **Dark text on filled tiles**, so the tiles still read with `&ink=v11`, where the fill turns pale.

## Choices made without being asked

- The accent is `rgb(235, 78, 39)`, sampled from `nasa.png`.
- The scene stays full-bleed behind the frame rather than set inside it. Setting it inside would cut v11's sea and stars at the frame's edges. Full-bleed keeps the scene exactly as v11 has it, and the top and lower sea are already dark enough for the words.
- Only one round button at the top right (settings), not two: the app has no second control that belongs there.
- No circled-i or expand marks in the frame's bottom corners, because they do nothing in the app. The bottom corners stay bare.
- The reference's last row of small outlined tiles that end in a slash is left out. There is no honest content for it, and no room above the home indicator.
- Every word on the screen is in the accent, with three exceptions. The place label, the rise and set marks, the mark at the top left and the settings ring are white, as the reference's logo, icons and planet name are. The date tile is white with dark words. The words on the filled accent tiles are dark.
- The frame's place label (`Chicago`) and the "how long it is up" label are new content. The app knows both: the place from the zip, and the rise and set times.

## Reads less well

- With `&ink=v11` at sunrise, the ink is a pale cream, so the white date tile and the accent tiles look almost alike. With the orange-red default there is no such problem.
- The fifth title, at 56%, is readable but quiet, which is the intent of the fade.

Stills `01-sunrise.png` to `12-moon-set.png` are rendered at 3× with headless Chrome (`--headless=new --hide-scrollbars --force-device-scale-factor=3 --window-size=393,852 --virtual-time-budget=4000`, address `?state=<id>&bare&still`), as for the other versions.
