---
id: 196
title: iOS v12: full-day calendar and add-event sheet restyled
status: todo
owner: 
depends_on: [195]
created: 2026-11-23T20:25:09Z
updated: 2026-11-23T20:25:09Z
---

## Goal

Read plans/2026-11-23-v12-in-the-app.md and memory/decisions/2026-11-23-v12-replaces-v11.md first. Restyle the day calendar (timeline, header, event boxes, now line, notices) and the add-event sheet and confirm popup to v12: mono type, accent outlines and fills from the environment accent, dark ground. Mic, + and close stay in the header row. Layout and behaviour unchanged. Guardrails: never commit fonts/ (use git add with named paths, never git add -A at the root); do not delete bundled fonts or other files that fall out of use; rewrite pinned layout tests to new numbers, do not delete them; screenshots on the iPhone 17 simulator with sample data only, never the iPhone 16 Pro Max; one xcodebuild at a time with your own -derivedDataPath.

## Acceptance criteria

- [ ] Screenshots with -debugDaySample normal, overlap, allday, short and empty on the iPhone 17, plus the add sheet and confirm popup
- [ ] No behaviour change: existing tests pass unchanged apart from pinned style values; xcodebuild test passes on both runtimes

## Relevant files

- ios/Seasign/Calendar/DayView.swift
- ios/Seasign/Calendar/DayTimelineView.swift
- ios/Seasign/Calendar/AddEventSheet.swift

## What's been tried


## Log

- 2026-11-23T20:25:09Z [li] created (todo)
