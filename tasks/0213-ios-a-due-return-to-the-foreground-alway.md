---
id: 213
title: iOS: a due return to the foreground always sends its fresh calendar request
status: backlog
owner: 
depends_on: []
created: 2026-11-24T16:43:31Z
updated: 2026-11-24T16:43:31Z
---

## Goal

Measured in task 164 on the iPhone 17 simulator: on a return after 6 minutes the minute loop's scheduled request can be sent and answered before the scene goes active, so the return reads isDue = false and no fresh request goes out (1 request in one run, 2 in another). Make a due return always send its fresh request: read isDue when the process resumes, or skip the minute loop's turn while the scene is not active. Correct the two comments the measurement contradicts: the doc on EventsModelTests.requestsSentByALaunchAndAReturnWithOneLink and the comment in TodayView about reading isDue first. Optional: GoogleCalendarModel.holdAtLeast keeps holdIsServerLimit when it replaces a server-limit hold that is still running.

## Acceptance criteria

- [ ] A test that fails on the old code shows a due return sends a fresh request even when the loop's answer landed first
- [ ] Measured again on the iPhone 17 simulator against local wrangler dev with -debugSeedLink: a return after 6 minutes sends a fresh request in three runs out of three
- [ ] Suite passes on both runtimes

## Relevant files

- ios/Seasign/Calendar/EventsModel.swift
- ios/Seasign/Today/TodayView.swift
- ios/SeasignTests/EventsModelTests.swift

## What's been tried


## Log

- 2026-11-24T16:43:31Z [li] created (backlog)
