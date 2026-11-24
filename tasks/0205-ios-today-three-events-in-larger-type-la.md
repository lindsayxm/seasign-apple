---
id: 205
title: iOS Today: three events in larger type, larger feed titles (tester feedback)
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-24T03:55:57Z
updated: 2026-11-24T03:56:13Z
---

## Goal

A tester found Today's text too small. The user asks: show only the next 3 calendar events in the events box (was 4) so there is more room, and make that text a bit bigger; and make the feed titles on the plate a bit bigger. Keep the box, tiles and everything else where they are. Targets (the lead's reading of 'a bit bigger'; adjust slightly if a figure does not fit, and say so): event rows 11.3 -> 13 points on a 22-point pitch, three rows centred in the same 78-point box, columns per row still computed from the box width (fewer characters fit; the row formatter already handles any width); feed titles 10.5 -> 12 points with a 19-point line, two-line rows (38) on a pitch that still fits five titles above the tiles on a 393x852 screen with the existing 17-point clearance (about 54), numbers and title x unchanged. Other screen sizes keep the existing rules (whole rows only; SE shows fewer).

## Acceptance criteria

- [ ] Today shows at most 3 events; event text and title text are larger as specified; nothing overlaps or clips on 393x852, iPhone 17, iPhone SE and Pro Max sizes (layout tests)
- [ ] Pinned layout and formatter tests rewritten to the new numbers, none deleted; VoiceOver labels unchanged
- [ ] Screenshots on the iPhone 17 (sample data) of mid-day and one night state, and the iPhone SE; xcodebuild test passes on both runtimes

## Relevant files

- ios/Seasign/Today/TodayOverlayLayout.swift
- ios/Seasign/Design/Typography.swift
- ios/Seasign/Calendar/EventsColumn.swift
- ios/Seasign/Feed/HeadlinesColumn.swift

## What's been tried


## Log

- 2026-11-24T03:55:57Z [li] created (todo)
- 2026-11-24T03:56:13Z [implementer-1] status: todo → in-progress — claimed by implementer-1
