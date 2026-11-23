---
id: 175
title: iOS: Google 'Connect again' follow-ups: a different account, one save for connection and scopes, test gaps
status: review
owner: implementer-1
depends_on: []
created: 2026-11-22T18:54:27Z
updated: 2026-11-23T01:05:44Z
---

## Goal

From the #169 review. (1) 'Connect again to add events' from a working connection can come back as a different Google account (ephemeral sheet, no login_hint, no check): the new refresh token overwrites the old one, the old account's grant is never revoked, and until the new list loads the old account's choices, events and push channels are mixed with the new token. (2) setConnection(.connected) and setGrantedScopes are two saves (GoogleCalendarModel.swift about 387-391); a crash between them after an expired write-access connection could leave stored scopes claiming write access the token lacks. (3) Test gaps.

## Acceptance criteria

- [ ] Account switch: look up in Google's OAuth docs (read-only pages) whether the installed-app flow accepts login_hint and what identifies the account without new scopes; then detect a different account (for example the primary calendar id changing, as the reviewer suggests) and treat it as Disconnect of the old account followed by a fresh Connect: old refresh token revoked best effort before it is overwritten, choices, cached events, default calendar and watch keeper reset; tests for same account and different account
- [ ] Connection state and granted scopes are written in one save; a test that an expired write-access connection reconnecting with an exchange that omits scope ends read-only (this must fail if scopes were inherited)
- [ ] aFailedConnectAgain... also asserts the stored scopes and newEventsCalendarID are unchanged; a renewal invalid_grant during the sheet is covered by a test that states the outcome. Suite passes on both runtimes (one xcodebuild at a time). Never touch the iPhone 16 Pro Max

## Relevant files

- ios/Seasign/Google
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-22T18:54:27Z [li] created (todo)
- 2026-11-22T18:54:27Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-22T18:54:51Z [implementer-2] status: in-progress → todo
- 2026-11-22T23:56:36Z [li] Lead: test gap seen 2026-11-22 while verifying #172: aPartialGrantIsHandedBackAndNotKept (GoogleCalendarTests.swift:570) waits a fixed 100 ms for the detached revoke Task and failed once on a busy Mac (iPhone 16 / 18.3.1, 'endpoint.revoked == [FakeGoogle.refresh]'); wait on a signal with a bound instead. Same pass: look for other fixed short sleeps in the Google and voice tests.
- 2026-11-23T00:40:10Z [li] Lead: also make VoiceEntryModelTests.aConfirmCutOffByTheEndOfTheWindowDoesNothing wait on a signal (failed once on timing for the implementer, 2026-11-22).
- 2026-11-23T00:40:29Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-23T00:52:29Z [implementer-1] Tests written first and run against the unfixed source (iPhone 16 / 18.3.1, -only-testing GoogleConnectAgainTests + GoogleWriteAccessModelTests): fail as intended: aDifferentAccountIsADisconnectOfTheOldOneThenAFreshConnect (11 issues: no revoke, no unwatch, Family kept on, newEventsCalendarID kept), anEndedSignInThatComesBackAsAnotherAccountStartsAfresh (3), aFailedConnectAgain... new list-unreadable/429/403 rows (new token kept), anExpiredWriteConnectionReconnectedWithoutScopesIsReadOnlyAtEverySave (a save stored connected with the old write scopes; seen through ModelContext.didSave and a second context). Same-account tests and the invalid_grant-during-sheet pin pass on old code, as they should. Docs (developers.google.com/identity/protocols/oauth2/native-app): login_hint is accepted (email or sub), only a hint; 'Revocation removes all OAuth 2.0 scopes previously granted to a project, invalidating any issued access or refresh tokens for all clients' so the same account must never be revoked. Account told apart by the primary calendar id from calendarList (calendarlist.readonly, already granted; Calendar concepts page: primary id 'usually matches the user's primary email address').
- 2026-11-23T00:58:22Z [implementer-1] Commit a807d76. Fix: connect() reads the list with the new token when a primary is known (connected or expired); another primary id -> forgetAccount() + stopAndRevoke() (unwatch with old token bounded by unwatchWait, old refresh token revoked) before tokens.save; same account keeps all, revokes nothing; list unreadable -> .unavailable, nothing kept (new token revoked only when not connected or disconnected meanwhile). GoogleCalendarStore.setConnected(grantedScopes:) is the one save. Sleeps: GoogleCalendarTests aPartialGrant... and GoogleWriteAccess aGrantMissingARead... wait on FakeGoogleEndpoint.waitForRevoked (5 s bound); anAnswerArrivingAfterDisconnect waits on stub.waitUntilParked; VoiceEntryModelTests aConfirmCutOff... sets firstWords/phraseLimit 30 s and waits for finishes == 2; default test firstWords 400 ms -> 1.5 s (sayTheExample could hit silence on a stall). Left as is: sleep-then-expect-nothing waits (cannot fail from load). Results: iPhone 16 / 18.3.1 'Test run with 736 tests in 88 suites passed after 78.659 seconds.' '** TEST SUCCEEDED **'; iPhone 17 / 27.2 'Test run with 736 tests in 88 suites passed after 87.258 seconds.' '** TEST SUCCEEDED **'. login_hint not added (only a hint; detection needed anyway).
- 2026-11-23T01:05:44Z [implementer-1] Commit 6c7bba9: two more tests (expired + new list unreadable: stays expired, .unavailable, new grant revoked; Disconnect during the pre-commit list read: nothing kept, both grants revoked). Behaviour change to note: a Connect again after expiry now fails (.unavailable) when the list read fails (offline, 429, 403), where it used to connect and retry the list. Revocation sentence checked verbatim in the raw page HTML ('Key Point: Revocation removes all OAuth 2.0 scopes previously granted to a project, invalidating any issued access or refresh tokens for all clients registered under that project.'). Other sleeps checked: AddEventModelTests 582/906 and DayModelTests 626 are expect-nothing waits, left. Settings is the only caller of disconnect() and clears nothing beside it. Final results: iPhone 16 / 18.3.1 'Test run with 738 tests in 88 suites passed after 69.148 seconds.' '** TEST SUCCEEDED **'; iPhone 17 / 27.2 'Test run with 738 tests in 88 suites passed after 83.300 seconds.' '** TEST SUCCEEDED **'.
- 2026-11-23T01:05:44Z [implementer-1] status: in-progress → review
