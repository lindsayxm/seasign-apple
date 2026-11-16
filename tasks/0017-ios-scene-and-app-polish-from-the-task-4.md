---
id: 17
title: iOS: scene and app polish from the task 4 review
status: todo
owner: 
depends_on: [10]
created: 2026-11-16T00:17:40Z
updated: 2026-11-16T00:18:26Z
---

## Goal

Low-severity findings from the task 4 review. (1) A cached sky older than a set age (suggest 3 hours) must not show its temperature and weather as current: keep sun and moon from it but hide the temperature and use clear weather, or mark it stale; add a test. (2) Polar transition days in SceneState/SkyMath: when only one of sunrise/sunset is null, fall back to current.isDay rather than assuming a 12-hour day; add tests for sunrise-without-sunset and sunset-without-sunrise. (3) The sun disc should not pop in and out at full horizon size at rise and set: ease it across the horizon (clip at the waterline so it rises out of and sinks into the water). (4) Lower the night redraw cost: stars should not force a 10 fps redraw all night; redraw slowly or keep stars static with an occasional twinkle. (5) Replace the fatalError on SwiftData container failure in SeasignApp.swift with a recoverable path (for this device-only cache-like store: delete and recreate the store only for models that are pure caches, otherwise show an error screen; explain the choice in the log). (6) Make the app iPhone-only: the built Info.plist lists UIDeviceFamily 1 and 2; set TARGETED_DEVICE_FAMILY on the target in ios/project.yml. (7) Delete the unused ios/Seasign/Today/HealthModel.swift and its tests (the user approves deleting these scaffold leftovers). (8) Update memory/architecture.md with the current ios/ layout, the info:/UIAppFonts wiring, the debug launch arguments, and the note that a Debug build made for the iOS 27.2 simulator will not launch on the 18.3 simulator (build per runtime).

## Acceptance criteria

- [ ] Tests cover the stale cache rule and both one-sided polar cases, and pass on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2)
- [ ] Screenshots at sunrise minus a few minutes, at sunrise, and plus a few minutes show the sun crossing the horizon gradually; paths recorded in the task log
- [ ] Built Info.plist lists UIDeviceFamily 1 only
- [ ] No fatalError on container failure; HealthModel and its tests are gone; memory/architecture.md describes the current ios/ layout

## Relevant files

- ios/Seasign/Scene/
- ios/Seasign/SeasignApp.swift
- ios/Seasign/Today/
- ios/SeasignTests/
- ios/project.yml
- memory/architecture.md

## What's been tried


## Log

- 2026-11-16T00:17:40Z [li] created (todo)
- 2026-11-16T00:18:26Z [li] Correction to the goal, item 7: the user has not been asked about HealthModel.swift. Deleting it is allowed without asking because it was created in this session by the task 2 scaffold (AGENTS.md: ask only before deleting files not created this session).
