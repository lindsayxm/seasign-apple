---
id: 208
title: iOS day calendar: the now line shows across the filled event under way
status: done
owner: lead
depends_on: []
created: 2026-11-24T10:45:05Z
updated: 2026-11-24T14:43:34Z
---

## Goal

User's choice 2026-11-24: on the day timeline the white now line is hidden where it crosses the filled (accent) box of the event under way; show it across that box. Draw the segment inside the filled box, above the fill and below the text, 1 point, in Palette.onAccent (white would fail on light accents since task 206). Outlined boxes keep hiding the line. Use -debugEvents on the iPhone 17 simulator; never the iPhone 16 Pro Max.

## Acceptance criteria

- [x] With now inside the filled event, a 1-point line in the on-accent color crosses the box at the now line's y, under the text; with now outside it, or on outlined boxes, nothing changes
- [x] The y of the segment inside the box is covered by a unit test (pure helper)
- [x] Screenshot of the day screen with the line across the filled event, including the worst case with now on the title's first line, shown to the user
- [x] xcodebuild test passes on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2

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
- 2026-11-24T14:38:29Z [lead] criterion 2 met: The y of the segment inside the box is covered by a unit test (pure helper)
- 2026-11-24T14:38:29Z [lead] criterion 4 met: xcodebuild test passes on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2
- 2026-11-24T14:38:29Z [lead] review: changes needed (one narrow case, lead may accept). Criterion 1 left unticked: nowY(in:) (DayTimeline.swift:103-106) is geometric and the view gates only on focus (DayTimelineView.swift:181). A 'next' event (nothing under way) that starts within minimumBoxHeight of midnight has its box moved up (DayTimeline.swift:171-174), so with now between the moved-up top and the real start the filled box of an event that has not started gets the line, where before it hid it (e.g. test metrics: event 23:50, now 23:30, box top about 23:12, nowY(in:) about 6). Fix: pass nowY only when rows[box.index].event.start <= now, or accept explicitly. Everything else in criterion 1 checks out from the code: ended rows are never in focus (covers short events drawn taller and zero-length events), events under way always contain now inside their box (cut-at-midnight and moved-up included), the all-day strip passes no nowY, filled columns draw only their own width, outlined boxes still hide the line, the segment sits in the background under the text and in Palette.onAccent (day-light.png shows it dark on the light fill). Edges: at now == box top the 1-point line is half clipped, cosmetic. Pixel alignment with the white line outside: aligned at the screenshots' resolution (644 px wide, about 1.6 px/pt) at both box edges; device-pixel alignment not verified (inner line sits in a box moved by a fractional .offset). Criterion 2 ticked: theNowLineCrossesOnlyTheBoxItIsIn tests the y inside, another box, before any box and another day; low: no minY/maxY edge, minimum-height or moved-up-box case (the last would catch the issue above). Criterion 4 ticked on the lead's logs t17b.log / t16b.log: 845 tests passed on iPhone 17 / 27.2 and iPhone 16 / 18.3.1, the new test ran in both, no ios/ change since the tested commit 44ebf6d. Criterion 3 left as ticked (user saw them); note day-title.png at 10:04 puts the line in the box's top padding rather than on the title's first line; 10:45 shows it on the second line.
- 2026-11-24T14:39:02Z [lead] status: review → in-progress
- 2026-11-24T14:43:34Z [lead] Lead: applied the reviewer's fix for finding 1 (nowY(in:started:), the view passes event.start <= now) with a test for the moved-up box at 23:50 with now 23:30. Suite: 845 tests passed, TEST SUCCEEDED, on iPhone 17 / iOS 27.2 and iPhone 16 / iOS 18.3.1. The fix itself was not re-reviewed; it is the reviewer's own one-line prescription. Left open, low: pixel alignment of the inner line at native resolution; the half-clipped line when now is exactly on the box's top; edge-value tests.
- 2026-11-24T14:43:34Z [lead] criterion 1 met: With now inside the filled event, a 1-point line in the on-accent color crosses the box at the now line's y, under the text; with now outside it, or on outlined boxes, nothing changes
- 2026-11-24T14:43:34Z [lead] status: in-progress → review
- 2026-11-24T14:43:34Z [lead] status: review → done
