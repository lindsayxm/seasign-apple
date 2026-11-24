---
id: 214
title: iOS: Google Connect again, low findings from the second #178 review
status: review
owner: implementer-2
depends_on: []
created: 2026-11-24T17:01:20Z
updated: 2026-11-24T17:58:08Z
---

## Goal

From the re-review of task 178 (its note has lines). (1) Connect again from a working connection inside the app's own 429 hold sends the person through the whole Google sheet, sends no read, and then says 'We couldn't reach Google. Check your connection and try again.': check the hold before opening the sheet and say that Seasign is busy and when to try again (follow the existing rate-limit wording), sending nothing. (2) A connect problem message is not cleared when the sign-in later ends (endSignIn), so the expired view can show a stale 'disconnect and connect again' beside 'Connect again': clear it there. (3) The guard right after the sheet still drops the sheet's sign-in when the old sign-in ended while the sheet was up; use the same goesOn rule as the other two guards so the new sign-in is kept (a Disconnect still hands it back). (4) A DEBUG launch argument that sets a connect problem on the -debugGoogle sample, and Simulator screenshots on the iPhone 17 of accountNotShown and of the new busy message (sample data only; never the iPhone 16 Pro Max; the iPhone 17 also holds a real Google connection, so use the sample path only).

## Acceptance criteria

- [ ] 1-3 fixed, each with a test that fails on the old code
- [x] Screenshots of the two messages from the sample, seen by the lead
- [ ] Suite passes on both runtimes

## Relevant files

- ios/Seasign/Google
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-24T17:01:20Z [li] created (backlog)
- 2026-11-24T17:40:03Z [li] status: backlog → todo
- 2026-11-24T17:40:03Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-24T17:45:51Z [implementer-2] Tests written first (GoogleConnectAgainTests, MARK Task 214) with only the compile shim in the model (new ConnectProblem.busy and its text, sample(connectProblem:), ConnectProblem.debugNamed). Against the unfixed connect()/endSignIn (iPhone 17 / 27.2, -only-testing GoogleConnectAgainTests, 34 tests, 7 issues): item 1 aConnectAgainInsideOurOwn429HoldDoesNotOpenTheSheet failed (sheet opened, authorization_code sent, message .unavailable not .busy); item 2 aConnectProblemIsClearedWhenTheSignInEnds failed (accountNotShown left after expiry); item 3 aSignInThatEndsWhileTheSheetIsUpKeepsTheSheetsSignIn failed (stayed expired, nothing stored). Pins passed as they should: aDisconnectWhileTheSheetIsUpKeepsNothing; aConnectAgainInsideOurOwn429HoldDoesNotAskAgain re-pointed so the hold begins while the sheet is up (a poll 429 inside the sign-in closure), keeping the in-connect serverLimitHold branch covered.
- 2026-11-24T17:56:00Z [implementer-2] Commit b0a90f7. (1) connect(): from .connected with our own 429 hold on (serverLimitHold), connectProblem = .busy and return before connectAttempt/connectsBegun/isConnecting move: no sheet, nothing sent, no pending revoke skipped. Text: 'Seasign is busy right now, so nothing changed. Try again in a moment.' (2) endSignIn sets connectProblem = nil. (3) The guard after the sheet is goesOn(after:&started, attempt:): the sign-in here ending while the sheet is up goes on as a Connect after it ended (sheet's sign-in exchanged and kept); a Disconnect or newer Connect still returns before the exchange. (4) DEBUG only: -debugGoogleConnectProblem <case name> (ConnectProblem.debugNamed) passed into GoogleCalendarModel.sample(connectProblem:), read in SeasignApp's #if DEBUG block, so the live model and store are never touched. Existing tests changed for the new behaviour: GoogleWriteAccessModelTests.aFailedConnectAgainLeavesTheReadOnlyConnectionAsItWas (now checks .busy inside the hold, then waits it out before the forbidden step) and aSignInThatEndsWhileTheConnectAgainSheetIsUp... renamed ...KeepsTheSheetsSignIn (it pinned the old drop); GoogleConnectAgainTests.aConnectAgainInsideOurOwn429HoldDoesNotAskAgain re-pointed so the hold starts while the sheet is up. Screenshots on iPhone 17 / 27.2 with -debugGoogleReadOnly YES -debugEvents YES -debugAI YES -debugSaved YES and -debugGoogleConnectProblem accountNotShown / busy; checked to show sample data only (zip scrolled out of frame); app stopped after. Results (own DerivedData, one at a time): iPhone 17 / 27.2 'Test run with 886 tests in 99 suites passed after 68.942 seconds.' '** TEST SUCCEEDED **'; iPhone 16 / 18.3.1 'Test run with 886 tests in 99 suites passed after 68.682 seconds.' '** TEST SUCCEEDED **'. iPhone 16 Pro Max not touched. Left open: a 429 hold that begins while the sheet is up, or a 429 on the new-list read, still says .unavailable ('We couldn't reach Google...'); the busy note stays after the hold ends until the next Connect; in real use statusProblem .rateLimited ('Too many requests from this network. Try again in a minute.') usually shows beside it.
- 2026-11-24T17:56:00Z [implementer-2] status: in-progress → review
- 2026-11-24T17:58:08Z [implementer-2] Lead: both screenshots seen (iPhone 17, sample data only): the accountNotShown and busy notes sit under Disconnect Google in the Google section, white with the leading '!', readable.
- 2026-11-24T17:58:08Z [implementer-2] criterion 2 met: Screenshots of the two messages from the sample, seen by the lead
