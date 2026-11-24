---
id: 219
title: iOS polish left from the v12 follow-ups: color sliders' VoiceOver value, ADD button margin, marker ring, large-type nits
status: backlog
owner: 
depends_on: []
created: 2026-11-24T19:57:05Z
updated: 2026-11-24T19:57:05Z
---

## Goal

Left from task 198 and its review, none urgent. (1) The HUD color block's two VoiceOver sliders report AXValue 'nan' to the accessibility tree; make them report hue and lightness, and check by ear on a phone when one is available. (2) The Do / Get ADD button stands about 7 points from the right edge while the rule ends 20 in, at default size. (3) The color marker ring overhangs the block's edge at the default corner. (4) Saved / History source-and-date line: a source longer than about 60 characters still pushes the date out at default size; truncate the source, never the date. (5) At the largest text sizes: calendar hosts and the voice PREVIEW button hyphenate; add-event values no longer line up across rows. (6) Rename the test theBusyNoteSaysSeasignIsBusyAndToTryAgainInAMoment (it checks 'in a minute'); a test that a 429 under a longer back-off is not marked as the app's own hold; the chip test checks stored properties, not the touch area. (7) GoogleCalendarModel.handle() and backOff() can still replace the app's own hold outright, shortening it and clearing its mark (about lines 1156-1184 and 1217). (8) On hold with the AI key section (the user's decision): Replace / Remove break mid-word at the largest text size, and 'KEY CAN'T BE READ NOW' wraps to two lines at default size. Dropped as not worth doing: Sea Signs row truncation at large type (deliberate); the now line when now is exactly on a box's top edge.

## Acceptance criteria

- [ ] 1-7 fixed or recorded as accepted, with tests where logic changed and screenshots where the look changed
- [ ] Suite passes on both runtimes

## Relevant files


## What's been tried


## Log

- 2026-11-24T19:57:05Z [li] created (backlog)
