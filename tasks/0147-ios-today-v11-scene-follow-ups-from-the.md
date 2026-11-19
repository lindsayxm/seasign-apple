---
id: 147
title: iOS: Today v11 scene — follow-ups from the review of #145
status: review
owner: implementer-1
depends_on: [146]
created: 2026-11-19T04:00:43Z
updated: 2026-11-19T06:00:32Z
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
- 2026-11-19T06:00:32Z [implementer-1] Changed: (1) RiseSetTimeline.pass(at:state:) now takes the state SceneState draws (sun's sighting rule or moon's rule) and follows it: up = rise before/set after; down at the rising end = the pass starting with the coming rise (rise nil if the next event is a set, i.e. the rise is only estimated); down at the setting end = the pass ending with the last set (set nil if the last event is a rise). Tests: [set1,set2] five minutes after set1 -> (rise0 or nil, set1), so MOONSET shows set1; [rise1,rise2] five minutes before rise2 -> (rise2, set2), and just after rise1's estimated set -> (rise1, nil), no tag; sun rule too. (2) SceneRenderTests.skiesWithAMissingEndAreDrawn renders missing-rise and missing-set sun and moon skies and checks more than half of the low sky (y 290-384) is lit and the disc is bright where SceneLayout puts it; checked that it fails (0 of 9259 lit, disc 0) with drawing removed, then reverted. (3) SnapshotToMarksTests: skyJSON10001 through SceneState.make to SceneMarks at NY midday, just after sunrise (tag SUNRISE 6:42 AM, WIND 9 MPH), the moon at 17:05 and two minutes before moonset (MOONSET 9:49 PM), after midnight (nothing up, no marks) and the 16th's own times in 24-hour. (4) SkyPass.maxHourCount = 24: any pass up to a day (the longest US sun is about 22 h, in Alaska) keeps one tick an hour, at least 11 pt apart on a 393 pt screen; a pass of days (polar day with both ends in the data) gets 24 evenly spaced ticks instead of hundreds. (5) SceneState.accessibilityDescription(clock:) used by SceneView: the old sentence plus 'Sunrise 6:41 AM, sunset 4:31 PM.', or with the tag 'Sunset at 4:31 PM, wind 11 miles per hour. Sunrise was at 6:41 AM.'; unknown times and the neutral scene are not spoken. (6) markTime builds on ClockStyle.columns. Verified: 433/433 on iPhone 16 / iOS 18.3 (XcodeBuildMCP) and iPhone 17 / iOS 27.2 (xcodebuild). No visual change expected; per the lead I did not run or screenshot the app on the iPhone 16 (real zip and calendar), and did not view it elsewhere either. VoiceOver text is checked by tests only, not with VoiceOver running.
- 2026-11-19T06:00:32Z [implementer-1] status: in-progress → review
