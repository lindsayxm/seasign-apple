---
id: 208
title: iOS day calendar: the now line shows across the filled event under way
status: review
owner: lead
depends_on: []
created: 2026-11-24T10:45:05Z
updated: 2026-11-24T14:35:10Z
---

## Goal

User's choice 2026-11-24: on the day timeline the white now line is hidden where it crosses the filled (accent) box of the event under way; show it across that box. Draw the segment inside the filled box, above the fill and below the text, 1 point, in Palette.onAccent (white would fail on light accents since task 206). Outlined boxes keep hiding the line. Use -debugEvents on the iPhone 17 simulator; never the iPhone 16 Pro Max.

## Acceptance criteria

- [ ] With now inside the filled event, a 1-point line in the on-accent color crosses the box at the now line's y, under the text; with now outside it, or on outlined boxes, nothing changes
- [ ] The y of the segment inside the box is covered by a unit test (pure helper)
- [x] Screenshot of the day screen with the line across the filled event, including the worst case with now on the title's first line, shown to the user
- [ ] xcodebuild test passes on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2

## Relevant files

- ios/Seasign/Calendar/DayTimelineView.swift
- ios/Seasign/Calendar/DayTimeline.swift
- ios/SeasignTests/DayTimelineTests.swift

## What's been tried


## Log

- 2026-11-24T10:45:05Z [li] created (todo)
- 2026-11-24T10:45:09Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-24T11:03:46Z [lead] Lead: Layout.nowY(in:) (tested) and BoxBackground draws the 1-point piece in Palette.onAccent above the fill, under the text, clipped to the box. Suite: 842 passed on both runtimes. Screenshots on iPhone 17 with -debugGoogle YES -debugOpenDay YES -debugDaySample normal -debugDayNow 10:45 / 10:04. Finding: at 10:45 the line runs through the title's second line and reads like a strike-through, since line and text share a color. Waiting for the user's look before review.
- 2026-11-24T14:35:10Z [lead] User, 2026-11-24, after being told the line reads like a strike-through when it falls on the title: keep it as built.
- 2026-11-24T14:35:10Z [lead] criterion 3 met: Screenshot of the day screen with the line across the filled event, including the worst case with now on the title's first line, shown to the user
- 2026-11-24T14:35:10Z [lead] status: in-progress → review
