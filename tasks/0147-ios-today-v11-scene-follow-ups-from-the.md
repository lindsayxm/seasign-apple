---
id: 147
title: iOS: Today v11 scene — follow-ups from the review of #145
status: in-progress
owner: implementer-1
depends_on: [146]
created: 2026-11-19T04:00:43Z
updated: 2026-11-19T05:53:31Z
---

## Goal

From the reviewer's report on #145 (see that task's log). (1) SkyMath.swift RiseSetTimeline.pass(at:): when an event is missing from the data the tag can show the wrong pass's time: with events [set1, set2] five minutes after set1 the moon is drawn sinking but the tag reads MOONSET with set2's time; with [rise1, rise2] five minutes before rise2 it reads MOONRISE/SUNRISE with rise1's time. Make the pass agree with the body state(at:) draws, and add tests for both cases. (2) SceneLookTests render test only asserts the image width; assert that something was drawn (for example some non-background pixels) for the missing-rise and missing-set skies. (3) Add a test that goes from a real multi-day SkySnapshot through SceneState.make() to the marks (ticks, times, tag), not only hand-built states. (4) Cap the hourly tick count so a very long pass (polar day) does not pack dozens of ticks together; choose a sensible cap and say so in the log. (5) Add the rise and set times to the scene's VoiceOver description. (6) SceneState.markTime repeats ClockStyle's formatting; use one.

## Acceptance criteria

- [ ] The two missing-event cases show the right time or no tag, with tests
- [ ] The render test fails if nothing is drawn; a snapshot-to-marks test exists
- [ ] Tick count is capped; VoiceOver description includes rise and set times; all tests pass on iOS 18.3 and 27.2

## Relevant files

- ios/Seasign/Scene/SkyMath.swift
- ios/Seasign/Scene/SceneState.swift
- ios/SeasignTests/

## What's been tried


## Log

- 2026-11-19T04:00:43Z [lead] created (todo)
- 2026-11-19T05:53:31Z [implementer-1] status: todo → in-progress — claimed by implementer-1
