---
id: 164
title: iOS: pasted-link refresh, low findings: 429 hold lost to a scheduled answer; answers not ordered; measure requests in the running app
status: in-progress
owner: implementer-2
depends_on: []
created: 2026-11-22T04:35:41Z
updated: 2026-11-24T16:09:32Z
---

## Goal

Low findings from the #162 review, none urgent. (1) EventsModel clears retryNotBefore on any successful answer (about line 193, before the drop check), so a scheduled answer landing after a fresh request's 429 ends the 60 s hold and the next pull runs into another 429: clear the hold only for an answer to a request sent after the hold was set. (2) Answers of the same kind are not ordered (a slow fresh answer can replace a later pull's; a hung scheduled answer can replace a newer one after zone A-B-A): keep one 'last shown request number' for every answer. (3) The doc comment at EventsModelTests.swift about 476-479 says 'whichever lands first', no longer true. (4) Measure in the running app how many calendar requests a launch and a return send with one pasted link (a DEBUG launch argument that seeds a public .ics link would make this possible without typing), and whether the minute loop's cached answer can land before the return reads isDue. (5) With settings sync (task 13) revisit the assumption that a removed link's id never comes back.

## Acceptance criteria

- [ ] Items 1-3 fixed with tests that fail on the old code
- [ ] Item 4 measured on the iPhone 17 simulator against local wrangler dev and recorded in the log; iOS suite passes on both runtimes

## Relevant files

- ios/Seasign/Calendar/EventsModel.swift
- ios/SeasignTests/EventsModelTests.swift

## What's been tried


## Log

- 2026-11-22T04:35:41Z [li] created (backlog)
- 2026-11-22T19:49:26Z [li] Lead: add from #170: EventsModel.refresh and add clear retryNotBefore on every success, so a links request already out when a 429 hold is set (by the day screen or another request) wipes that hold when it succeeds; the same rule as GoogleCalendarModel.answered(holdAtStart:) should apply to links.
- 2026-11-22T19:57:32Z [li] Lead: from the second #170 review: tests that pin holdAtLeast (a per-calendar 60 s hold must not shorten a longer kept hold) and the kept failure count in GoogleCalendarModel.answered; holdAtLeast resets holdIsServerLimit when it replaces a shorter 429 hold (check that is intended).
- 2026-11-24T16:09:32Z [li] status: backlog → todo
- 2026-11-24T16:09:32Z [implementer-2] status: todo → in-progress — claimed by implementer-2
