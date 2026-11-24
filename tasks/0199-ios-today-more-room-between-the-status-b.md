---
id: 199
title: iOS Today: more room between the status bar and the top row
status: done
owner: lead
depends_on: []
created: 2026-11-24T01:40:02Z
updated: 2026-11-24T01:48:22Z
---

## Goal

At the user's request, push Today's top row (mark, place, settings) down from the status bar; the date tile, events box, frame top, frame labels and the rim's gap move down with it. The scene, plate, titles and tiles stay.

## Acceptance criteria

- [x] Top row, tiles, frame top, frame labels and rim gap are each 14 points lower; pinned layout tests updated to the new numbers
- [x] Screenshot on the iPhone 17; xcodebuild test passes on both runtimes

## Relevant files

- ios/Seasign/Today/TodayOverlayLayout.swift

## What's been tried


## Log

- 2026-11-24T01:40:02Z [li] created (todo)
- 2026-11-24T01:40:02Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-24T01:48:21Z [lead] Mockup.topPadding = 14 added to the top row, the tiles' top, the frame's top, the frame labels and the rim gap's top. Pinned numbers updated by 14 in TodayOverlayLayoutTests (mark and settings y 66, tiles y 105, rows 110/127/144/161, frame 194 with height 232, labels 201.5, rim gap from 190) and TodayPullTests (spinner row). Lead runs: iPhone 17 / iOS 27.2 829 tests passed, TEST SUCCEEDED; iPhone 16 / iOS 18.3.1 829 tests passed, TEST SUCCEEDED. Screenshot on the iPhone 17 looked at by the lead. No separate reviewer: a constants change checked by the pinned tests and the screenshot.
- 2026-11-24T01:48:21Z [lead] criterion 1 met: Top row, tiles, frame top, frame labels and rim gap are each 14 points lower; pinned layout tests updated to the new numbers
- 2026-11-24T01:48:21Z [lead] criterion 2 met: Screenshot on the iPhone 17; xcodebuild test passes on both runtimes
- 2026-11-24T01:48:22Z [lead] status: in-progress → review
- 2026-11-24T01:48:22Z [lead] status: review → done
