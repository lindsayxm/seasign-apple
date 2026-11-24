---
id: 214
title: iOS: Google Connect again, low findings from the second #178 review
status: in-progress
owner: implementer-2
depends_on: []
created: 2026-11-24T17:01:20Z
updated: 2026-11-24T17:40:03Z
---

## Goal

From the re-review of task 178 (its note has lines). (1) Connect again from a working connection inside the app's own 429 hold sends the person through the whole Google sheet, sends no read, and then says 'We couldn't reach Google. Check your connection and try again.': check the hold before opening the sheet and say that Seasign is busy and when to try again (follow the existing rate-limit wording), sending nothing. (2) A connect problem message is not cleared when the sign-in later ends (endSignIn), so the expired view can show a stale 'disconnect and connect again' beside 'Connect again': clear it there. (3) The guard right after the sheet still drops the sheet's sign-in when the old sign-in ended while the sheet was up; use the same goesOn rule as the other two guards so the new sign-in is kept (a Disconnect still hands it back). (4) A DEBUG launch argument that sets a connect problem on the -debugGoogle sample, and Simulator screenshots on the iPhone 17 of accountNotShown and of the new busy message (sample data only; never the iPhone 16 Pro Max; the iPhone 17 also holds a real Google connection, so use the sample path only).

## Acceptance criteria

- [ ] 1-3 fixed, each with a test that fails on the old code
- [ ] Screenshots of the two messages from the sample, seen by the lead
- [ ] Suite passes on both runtimes

## Relevant files

- ios/Seasign/Google
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-24T17:01:20Z [li] created (backlog)
- 2026-11-24T17:40:03Z [li] status: backlog → todo
- 2026-11-24T17:40:03Z [implementer-2] status: todo → in-progress — claimed by implementer-2
