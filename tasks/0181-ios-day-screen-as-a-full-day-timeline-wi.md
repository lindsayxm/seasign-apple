---
id: 181
title: iOS: day screen as a full-day timeline with event boxes
status: done
owner: implementer-2
depends_on: []
created: 2026-11-23T02:04:39Z
updated: 2026-11-23T04:02:06Z
---

## Goal

The user asked on 2026-11-22: on the full-screen day view show how long each event lasts, as Google Calendar does: the top of an event's box is its start time, the bottom its end, and the whole day fits the length of the screen (no scrolling). Replaces the list in ios/Seasign/Calendar/DayView.swift; DayModel's data is unchanged. Lead's choices where the user did not say: midnight to midnight in the events' time zone, hours scaled to the space left under the header; hour lines with time labels on the left in the app's clock style (12/24 h); all-day events in a strip above the grid; overlapping events side by side in columns; an event without a length or shorter than its title line gets a minimum height so the title reads; an event running past midnight is cut at the edge; a 'now' line for the current time; ended events dimmed as today; title in the box, the time too when the box is tall enough; the mic and + buttons, notices, listening text and the Added note keep working and do not cover the grid's events more than they must; the app's own palette and type (TodayType, Palette), not Google's colours.

## Acceptance criteria

- [x] Layout is a pure function (events, day bounds, height, width -> boxes with frames and columns) with tests: start and end map to y, overlaps get columns, minimum height, cut at midnight, a 23- and 25-hour day (clock change), an all-day event goes to the strip, no length
- [x] VoiceOver: each box reads title, start, end and length; order by start; the grid does not hide events from VoiceOver
- [x] Screenshots on the iPhone 17 with the Google sample (-debugGoogle YES -debugOpenDay): a normal day, overlapping events, many all-day events, a very short event, an empty day; and one on the smallest supported screen (iPhone SE 3rd generation, iOS 18.3) to show the day still fits and reads
- [x] Suite passes on both runtimes (one xcodebuild at a time); never touch the iPhone 16 Pro Max

## Relevant files

- ios/Seasign/Calendar/DayView.swift
- ios/Seasign/Calendar
- ios/SeasignTests

## What's been tried

- Installing the app built for the iPhone 17 (iOS 27.2) destination on the iPhone SE (iOS 18.3) crashes at launch: dyld 'Library missing' (library name not read). Use the app built by the iPhone 16 / OS=18.3.1 test run for the SE instead.

## Log

- 2026-11-23T02:04:39Z [li] created (todo)
- 2026-11-23T02:37:14Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-23T02:48:13Z [implementer-2] Built: DayTimeline.swift (pure layout: day bounds by calendar midnight, y by real elapsed seconds so 23/25-hour days work, hour marks labelled by local clock, minimum box height = one title line, columns from drawn frames incl. minimum height, groups share column count, boxes widen into free columns, cut at midnight, bottom-edge shift, content tier per height, all-day strip flow with +N chip, spoken text, time text). DayTimelineView.swift draws it; DayView: mic/+ moved into the header row beside the close mark so nothing floats over the grid; notices/listening/Added/problem/empty line sit between header and grid, which shrinks to the height left. DEBUG -debugDaySample normal|overlap|allday|short|empty and -debugDayNow HH:MM, both only with the sample Google model.
- 2026-11-23T03:50:03Z [implementer-2] tried: Installing the app built for the iPhone 17 (iOS 27.2) destination on the iPhone SE (iOS 18.3) crashes at launch: dyld 'Library missing' (library name not read). Use the app built by the iPhone 16 / OS=18.3.1 test run for the SE instead.
- 2026-11-23T03:50:04Z [implementer-2] Verified. iPhone 16 OS=18.3.1: '✔ Test run with 755 tests in 89 suites passed after 872.001 seconds.' and '** TEST SUCCEEDED **'. iPhone 17 OS=27.2: '✔ Test run with 755 tests in 89 suites passed after 157.674 seconds.' and '** TEST SUCCEEDED **'. Screenshots (sample Google, -debugDayNow 14:20) in the scratchpad t181/shots: iPhone 17 normal, overlap, allday, allday-24h, short, empty; SE normal, listening, added. snapshot_ui on the iPhone 17 shows one element per box with the full spoken label (title, start, end, length, ended; yesterday/tomorrow for cut events) and the +3 chip listing the folded all-day events; VoiceOver order is set by accessibilitySortPriority by start but was not observed with VoiceOver itself. Commit 2fe6ea3.
- 2026-11-23T03:50:04Z [implementer-2] status: in-progress → review
- 2026-11-23T04:02:05Z [implementer-2] criterion 1 met: Layout is a pure function (events, day bounds, height, width -> boxes with frames and columns) with tests: start and end map to y, overlaps get columns, minimum height, cut at midnight, a 23- and 25-hour day (clock change), an all-day event goes to the strip, no length
- 2026-11-23T04:02:06Z [implementer-2] criterion 2 met: VoiceOver: each box reads title, start, end and length; order by start; the grid does not hide events from VoiceOver
- 2026-11-23T04:02:06Z [implementer-2] criterion 3 met: Screenshots on the iPhone 17 with the Google sample (-debugGoogle YES -debugOpenDay): a normal day, overlapping events, many all-day events, a very short event, an empty day; and one on the smallest supported screen (iPhone SE 3rd generation, iOS 18.3) to show the day still fits and reads
- 2026-11-23T04:02:06Z [implementer-2] criterion 4 met: Suite passes on both runtimes (one xcodebuild at a time); never touch the iPhone 16 Pro Max
- 2026-11-23T04:02:06Z [implementer-2] Lead: own run at 2fe6ea3, own DerivedData: iPhone 16 / iOS 18.3.1 'Test run with 755 tests in 89 suites passed', TEST SUCCEEDED; iPhone 17 / iOS 27.2 the same. Screenshots 17-normal, 17-overlap and se-normal viewed by the lead. Closed by the lead without a separate code reviewer. Differs from the user's first wording: mic and + are in the header row, not stacked at the top right (the user has been told and can reverse it). Not verified: VoiceOver reading order with VoiceOver itself; a long date or large text beside three header buttons; grid text does not follow Dynamic Type; the app built for the iPhone 17 destination crashed at launch on the SE simulator (dyld, library not read) while the iPhone 16 build ran there.
- 2026-11-23T04:02:06Z [implementer-2] status: review → done
