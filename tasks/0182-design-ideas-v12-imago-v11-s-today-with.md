---
id: 182
title: design-ideas/v12-imago: v11's Today with buttons and text redesigned after the user's reference (nasa.png)
status: done
owner: implementer-1
depends_on: []
created: 2026-11-23T04:33:11Z
updated: 2026-11-23T04:45:52Z
---

## Goal

Look-only round, nothing in ios/ or api/. The user (2026-11-22): 'move to /design-ideas/v12-imago and look at nasa.png; use v11 as the starting point, but redesign the buttons and text around the reference image instead'. Copy design-ideas/v11-artemis (index.html, fonts) into design-ideas/v12-imago and keep v11's scene (sky, sea, sun and moon path, rise and set marks, twelve states, the address switches). Redesign everything that is a button or text in the language of design-ideas/v12-imago/nasa.png: one mono face; square tiles with a label at the top left and a slash and value at the bottom (one white filled tile, outlined tiles, filled accent tiles); corner brackets framing the scene with small labels inside the frame; rows written as 'Label/------value' with dashed leaders; a block of mono text that fades out at the bottom; small outlined tiles ending in a slash; thin rounded frame lines; the orange-red accent on black. Content stays Seasign's own (date, day, temperature, wind, next three events, five article titles, the four buttons settings, do/get, saved, history). No NASA name, logo, wordmark or mission words; the reference is for the visual language only.

## Acceptance criteria

- [x] design-ideas/v12-imago/index.html opens in a browser with v11's switches; all twelve states render; README.md in the folder says what differs from v11 and every choice made without being asked; nasa.png stays where the user put it
- [x] Twelve stills 01-sunrise.png to 12-moon-set.png rendered at 3x with headless Chrome as for v11; the lead views at least four of them
- [x] design-ideas/README.md lists v12-imago and the v0 landing page gets its thumbnail; v11 and earlier folders are unchanged; nothing in ios/ or api/ changes

## Relevant files

- design-ideas/v12-imago
- design-ideas/README.md
- design-ideas/v0-version-landing-page

## What's been tried


## Log

- 2026-11-23T04:33:11Z [li] created (todo)
- 2026-11-23T04:33:11Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-23T04:38:06Z [implementer-1] Copied v11-artemis/index.html to v12-imago/index.html as the base; the canvas draw() stays verbatim, only CSS, markup and show() change. Accent sampled from nasa.png: rgb(235,78,39).
- 2026-11-23T04:43:41Z [implementer-1] Built v12-imago/index.html: v11 draw() verbatim; new mono UI (∀ line mark + round settings at top; 4 tiles Mon/Nov 16 white, 55°F/wind, weather word or moon phase with glyph, accent Sunset|Moonset (or rise at rise); corner-bracket frame y180-426 with Chicago and Daylight/Moon-up span labels; events as leader rows on a 60% black plate; titles as 11.5pt mono block fading 100/100/86/68/56%; bottom accent tiles Day/3, Do & get/5, Saved/12, History/7d; accent rim broken y176-440). New switches &ink=v11 and &norim; v11 switches kept, &nobtn hides controls. Accent rgb(235,78,39) sampled from nasa.png. No font bundled.
- 2026-11-23T04:43:41Z [implementer-1] Verified: render loop reproduces v11's 02-mid-day byte-identical, so the method matches. Twelve 1179x2556 stills rendered and all viewed (contact sheet; 01, 02, 03, 05, 08 at full size); &ink=v11 viewed at sunrise, mid-day, mid-night; the animated page loads with no script errors (&ink=v11&nobtn, waxing). The sky band y225-385 is pixel-identical to v11 apart from where v11's button column stood. Nothing overlaps the sun or moon on any state. Thumbs made with sips (393 wide JPEG q60); v12 card marked latest. Committed 69ca04e (also commits the user's nasa.png).
- 2026-11-23T04:43:41Z [implementer-1] status: in-progress → review
- 2026-11-23T04:45:09Z [implementer-1] Correction to the earlier note: 02-mid-day and 11-moon-full were viewed at full size in their committed form after that note was written (02 had been seen full size only before the events and feed fixes). Neither needed a change. README corrected: v11's plate was 55%; the feed numbers carry a further 70%, so 05 is at about 39%; dark words on the filled tiles are named. Commit after 69ca04e.
- 2026-11-23T04:45:52Z [implementer-1] criterion 1 met: design-ideas/v12-imago/index.html opens in a browser with v11's switches; all twelve states render; README.md in the folder says what differs from v11 and every choice made without being asked; nasa.png stays where the user put it
- 2026-11-23T04:45:52Z [implementer-1] criterion 2 met: Twelve stills 01-sunrise.png to 12-moon-set.png rendered at 3x with headless Chrome as for v11; the lead views at least four of them
- 2026-11-23T04:45:52Z [implementer-1] criterion 3 met: design-ideas/README.md lists v12-imago and the v0 landing page gets its thumbnail; v11 and earlier folders are unchanged; nothing in ios/ or api/ changes
- 2026-11-23T04:45:52Z [implementer-1] Lead: stills 01-sunrise, 02-mid-day, 03-sunset and 08-mid-night viewed: all text reads, nothing covers the sun or moon; the fifth title is faint by design. git shows only design-ideas/ in the two commits. Closed by the lead (look-only round). Shown to the user; their reactions decide the next round.
- 2026-11-23T04:45:52Z [implementer-1] status: review → done
