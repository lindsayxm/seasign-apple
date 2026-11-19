---
id: 148
title: iOS Today: remove the rise/set tag, always show the wind line, remove the AI mark from Today titles
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-19T14:06:20Z
updated: 2026-11-19T14:12:53Z
---

## Goal

User, 2026-11-19: remove the text call-out on the sun/moon at rise and set; always show the wind speed under the temperature; remove the AI labels on Today.

## Acceptance criteria

- [ ] No tag or leader is drawn in any state; the tag code (tagLines, leader, the tag entry in SceneMarks) is gone. The rise/set time mark under the end tick stays hidden near the horizon exactly as now (u<0.05 or u>0.95): keep that rule in SceneState under a new name instead of showsTag
- [ ] The wind line under the hairline shows whenever fresh current weather exists (TodayView: just 'if let wind = state.windLabel'); still none in the neutral or stale scene
- [ ] Today article titles show no AI mark and no indent or width reduction for AI rows (HeadlinesColumn); AIMark, isAI, the spoken AI label and the marks in History, Saved, Reading and the filter bar are unchanged
- [ ] VoiceOver scene description still speaks rise and set times and wind, without the tag; tests updated (SceneLookTests, snapshot-to-marks, spoken marks); suite passes on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2
- [ ] Simulator screenshots through the DEBUG override of sunrise, sunset, moonrise, moonset and one screen with a sample AI row, on a simulator other than the user's iPhone 16 data (use the override flags only; do not print or screenshot real calendar contents, do not change its settings)

## Relevant files

- ios/Seasign/Scene
- ios/Seasign/Today
- ios/Seasign/Feed/HeadlinesColumn.swift
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-19T14:06:20Z [lead] created (todo)
- 2026-11-19T14:06:36Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-19T14:12:53Z [implementer-1] Removed the rise/set tag: SceneMarks.Tag, SceneMarks.tag, SceneState.tagLines and showsTag, and the leader/tag drawing in SceneRenderer.drawMarks. tagEdge renamed hiddenTimeEdge (same rule: body within 5 % of an end whose instant is known); riseMark/setMark still hide that end's time. TodayView: wind line is now 'if let wind = state.windLabel' (windMph is nil in the neutral and stale scene). HeadlinesColumn: no AIMark, no indent, full column width for every title; AILabel.accessibility still says AI-found. Palette and SkyMath comments no longer mention the tag. VoiceOver choice: accessibilityDescription(clock:) now always says 'Sunrise 6:41 AM, sunset 4:31 PM.' from markedPass (so the time hidden at the end is still spoken) and no longer speaks the wind, because the wind line is always shown with its own label 'Wind N miles per hour' and would otherwise be spoken twice. AIMark.fixed / AIMark.fixedWidth are now unused (left in place). Tests: tagStandsAbove... removed, tag assertions replaced by hiddenTimeEdge/riseMark/setMark/riseTime/setTime/windLabel checks, spoken tests rewritten incl. a near-end and moonset case. 432 tests in 62 suites pass on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2 (433 before, less the deleted tag-position test).
