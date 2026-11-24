---
id: 213
title: iOS: a due return to the foreground always sends its fresh calendar request
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-24T16:43:31Z
updated: 2026-11-24T17:03:01Z
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
- 2026-11-24T16:49:52Z [li] Also, from the #164 review (low): setSnapshot(nil) clears freshShown, so after two zone changes a hung older fresh answer can replace a newer scheduled one (EventsModel.swift:312-315 with :212). Keep freshShown across a clear if no test needs the reset, with a test for the sequence F1 hangs, F2 shown, zone A-B-A, S4 shown, F1 lands.
- 2026-11-24T17:03:01Z [li] status: backlog → todo
- 2026-11-24T17:03:01Z [implementer-1] status: todo → in-progress — claimed by implementer-1
