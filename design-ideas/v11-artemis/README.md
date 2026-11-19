# v11 — Artemis

Look-only mockup; nothing here is part of the app. A copy of `v8-lemuria/` as it stood on 2026-11-18, made at the user's request to iterate on, with the top of the screen taken from `v7-firmament/`. v8 and v7 are left as they are. For everything not listed here, `../v8-lemuria/README.md` describes this version too.

Open `index.html`. Same address switches as v8: `?state=<id>`, `&bare`, `&still`, `&t=<seconds>`, `&nobtn`, `&arc`, `&nohud`.

## What differs from v8

- **The header is v7's, unchanged:** the date (`NOV 16`), the day name in the condensed face sized to the date's width, and the temperature at the left; the next three events in a dark box beside them, each with a rule at its left, times as `6:45 PM` and `TUE ALL` in two fixed columns. v8's mono day read-out, week and day note, hairline, boxed date and place, and short `6:45p` times are gone.
- **The three muted buttons** (settings, list, saved) sit under the events box at the right (26 points apart), still centred on x 331. In v8 they stood beside the events, but v7's events box runs to the right edge. This was decided without being asked.

- **Tags only at rise and set.** Sunrise, sunset, moonrise and moonset keep their tag (`SUNSET 4:31 PM` and the wind). On every other screen the tag and its leader are gone at the user's request, so wind, cloud cover, the words `RAIN` and `SNOW` and the moon's lit share are no longer written anywhere; the corner brackets round the sun or moon were then removed on every screen as well. The dotted drop line to the horizon, the small square under the body and the rise and set marks stay.

- **The date is white**, the same as the temperature (it was the ink colour). The day name was then made white as well, with a softer white glow, so the whole left column is white; the ink colour remains on the event times, their rules, the buttons, the numbers and the rise and set tag.

- **A hairline closes the header** (y 168, from the left margin at x 34 to the right edge of the events box at x 377), added at the user's request. The button column starts 6 points lower (y 186) to keep clear of it.

- **`∀` is in the lower right corner** moved from the lower left at the user's request, and centred on x 331 so it stands straight under the column of three buttons.

- **Five article titles** instead of seven, at the user's request. The list still starts at y 486 and `∀` stays at y 794, so there is open sea between them.

Kept from v8: the full-screen sky and sea, the sun and moon as light on a centred path with bracket and tag, the rise and set marks on the horizon, one ink colour per screen, the numbered serif titles, no stars at mid-day.

Stills `01-sunrise.png` … `12-moon-set.png` are rendered at 3× with headless Chrome, as for the other versions.
