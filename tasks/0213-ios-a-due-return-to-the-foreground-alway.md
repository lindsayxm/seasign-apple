---
id: 213
title: iOS: a due return to the foreground always sends its fresh calendar request
status: review
owner: implementer-1
depends_on: []
created: 2026-11-24T16:43:31Z
updated: 2026-11-24T17:39:18Z
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
- 2026-11-24T17:12:50Z [implementer-1] Approach (implementer-1): EventsModel holds isAppActive (default true), set by TodayView first thing in onChange(of: scenePhase) and seeded in onAppear from scenePhase. refresh(force: false) sends nothing while it is false (placed after the zone clear and prune, before the hold check), so the minute loop's expired turn at process resume (before the scene goes active) sends nothing and the return reads isDue as due. Every non-forced caller checked: minute loop, zone change, the return when not due (runs after the flag is set true), add/remove tails (Settings, active); DayModel only calls events.hold. isDue covers every reason a non-forced refresh sends, so the return makes up skipped checks. Consequence: the loop's answer can no longer land first in that window, because its request is not sent. freshShown: setSnapshot(nil) now clears only scheduledShownThrough; consequence: an older fresh answer no longer fills an empty Today after a clear (one shown before the clear was newer).
- 2026-11-24T17:12:50Z [implementer-1] Red/green (iPhone 17, 27.2, -only-testing EventsModelTests, 41 tests): with the gate line removed and freshShown = nil restored in setSnapshot(nil), 3 new tests fail: aDueReturnSendsItsFreshRequestWhenTheLoopsTurnRunsBeforeTheSceneIsActive (requests [nil], not [true]: the loop's scheduled answer lands first and the return reads not due), checksWithoutForceWaitForTheReturnWhileTheAppIsNotActive, anOlderFreshAnswerDoesNotReplaceANewerOneAfterTheZoneComesBack (F1's lunch replaces S4). New tests cannot compile against the original file (setAppActive is new), so red was by removing only those lines. With the fix: 41 passed.
- 2026-11-24T17:20:50Z [implementer-1] Measurement setup (iPhone 17, iOS 27.2 sim, Debug build with temporary T213 NSLog traces: no link text; local 'npx wrangler dev' on 8787 started by me; -debugSeedLink with Google's public US-holidays .ics; returns by simctl launch of Settings then of Seasign, same PID 67401 checked each time). Launch: onAppear set active=0, loop turn started, scene went active, return isDue=1 -> fresh #1; the loop's turn reached the events after the sky's request with active=1 -> scheduled #2: 2 requests (wrangler 2), as in 164. Run 1 (6.5 min background): at resume the loop's turn ran first and logged skip-away, then setAppActive 1, isDue=1, fresh #3 sent and shown: 1 request, fresh (wrangler +1).
- 2026-11-24T17:27:33Z [implementer-1] Run 2 (6.5 min background, same PID): loop turn started at resume (sky request first), its events check ran after the scene went inactive and logged skip-away; then setAppActive 1, isDue=1, fresh #4 sent and shown: 1 request, fresh (wrangler 3 -> 4).
- 2026-11-24T17:34:22Z [implementer-1] Run 3 (6.5 min background, same PID): loop turn at resume logged skip-away at once, then setAppActive 1, isDue=1, fresh #5 sent and shown: 1 request, fresh. Wrangler log over the whole session: 5 POST /v1/calendar/events (launch 2, runs 1-3 one each), matching the traces #1-#5. So 3 of 3 due returns sent their fresh request; the skipped loop turn showed in all three (run 2's after the sky's request, as the scene had gone inactive). Cleanup: traces removed (grep T213 in ios/ empty), app terminated, my wrangler dev and log stream stopped, 8787 free. No screenshots; the simulator's Google connection was not looked at (its POST /v1/google/events lines, if any, not recorded).
- 2026-11-24T17:38:13Z [implementer-1] Suite at f0c475e (traces removed before both runs): iPhone 17 (iOS 27.2): 'Test run with 880 tests in 99 suites passed', '** TEST SUCCEEDED **'; iPhone 16 (iOS 18.3.1): 'Test run with 880 tests in 99 suites passed', '** TEST SUCCEEDED **' (877 + 3 new). Optional holdAtLeast item not done: holdIsServerLimit is observable only through Connect again's serverLimitHold or listHold with no calendars, so a test needs the task-178 Connect-again setup, more than a few lines; GoogleCalendarModel unchanged.
- 2026-11-24T17:38:13Z [implementer-1] status: in-progress → review
- 2026-11-24T17:39:18Z [implementer-1] Comments corrected from the measurement: the doc on EventsModelTests.requestsSentByALaunchAndAReturnWithOneLink (two requests only when both are in flight with the app active; at launch the scene does go active and both are sent; on a return the loop's turn can run before active and then sends nothing) and TodayView's comment on reading isDue first (a turn that ran before the scene went active sent nothing). Not verified: the TodayView wiring (flag set before isDue is read, the onAppear seed) has no unit test, only the iPhone 17 measurement; the resume order was measured on 27.2 only; returns driven by simctl launch, not an icon tap; a launch that starts in the background (push) not exercised.
