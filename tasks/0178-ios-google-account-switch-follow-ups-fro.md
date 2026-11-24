---
id: 178
title: iOS: Google account-switch follow-ups from the #175 review
status: in-progress
owner: implementer-2
depends_on: []
created: 2026-11-23T01:15:22Z
updated: 2026-11-24T16:05:04Z
---

## Goal

From the #175 review (its review note has lines and scenarios). (1) A calendar list with no primary, or the same account's primary id changed (email rename), is taken for a different account: the old token is revoked, which ends the new grant too; treat a missing primary as 'cannot tell' (.unavailable) and decide what a changed id should do. (2) Connect again after expiry with an unreadable list revokes the new grant and ignores a 429 Retry-After; from expired, start a fresh account locally and keep the new token instead; record the hold. (3) withToken does not check the generation between a 401 and its retry, so a request for the old account can go out with the new token (answer is dropped). (4) A late hand-back revoke can end a second Connect into the same account. (5) Test gaps: Disconnect during stopAndRevoke; unwatch outlasting unwatchWait; list with no primary; distinct token strings in the same-account test. Also open: whether invalid_grant during the sheet should keep the completed sign-in; optional login_hint.

## Acceptance criteria

- [ ] Each of 1-4 fixed or recorded as accepted with a reason, with a test that fails without the fix
- [ ] The test gaps in 5 covered
- [ ] Suite passes on both runtimes; never touch the iPhone 16 Pro Max

## Relevant files

- ios/Seasign/Google
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-23T01:15:22Z [li] created (backlog)
- 2026-11-24T15:38:03Z [li] status: backlog → todo
- 2026-11-24T15:38:03Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-24T15:54:27Z [implementer-2] Tests written first, run against the unfixed source (iPhone 16 / 18.3.1, -only-testing GoogleConnectAgainTests + GoogleWriteAccessModelTests, 34 tests): the 13 fix tests fail as intended (no-primary from connected: A revoked/choices reset; rename: A revoked; old sign-in 429: switched anyway; old sign-in ended: dead A token revoked; expired+offline and expired+429: stayed expired, new grant revoked, no hold; connected 429: no hold; stale 401 for events/create/watch: refresh_token grant sent and A's request resent with B's renewed token; hand-back after Disconnect and Disconnect's own revoke: revoked a grant once a newer Connect had begun; aDifferentAccount now expects the old-token list read). Gap/pin tests pass on old code as they should: Disconnect during the switch's stopAndRevoke, unwatch outlasting unwatchWait, no primary after expiry, same-account distinct tokens. Fixture: GoogleAPIStub.answer(_:token:) answers per Google token; FakeGoogleEndpoint.waitForSent(grant:count:).
- 2026-11-24T15:55:45Z [implementer-2] Choices (for the lead to put to the user). (1) A changed primary id from a working connection: the OLD sign-in is asked, with its own token, for its primary now (one more calendarList read). Same as the new one -> same account (an email rename): everything kept, the primary's choice follows the new id, nothing revoked. Another -> a different account, switched as in #175 (A revoked). Old sign-in cannot be asked (offline, 429, 403, keychain) or names no primary -> cannot tell: .unavailable, the working connection kept as it was, nothing revoked. Old sign-in ended at Google (invalid_grant on its renewal) -> fresh Connect, nothing revoked (the token is dead). A new list with no primary from a working connection -> cannot tell (.unavailable), nothing revoked. Reason: never revokes a token that might be the same grant, and keeps #175's revoke of a truly different account. (2) From expired, anything but the same primary (another, none listed, list unreadable) starts afresh locally and keeps the new sign-in; nothing is revoked; a failed list read goes through handle() (status, back-off, our 429's Retry-After as a server-limit hold) and Settings reads it again. Behaviour reversal of #175's 'stays expired and hands the grant back'. From connected, a list 429 now also sets the hold (no status). (4) A revoke decided before a Connect began is not sent once it has (counter connectsBegun, moves only on Connect): connect's hand-backs and Disconnect's own revoke after the unwatch. Trade-off: the skipped grant stays at Google unused (the user can remove it in their Google Account). Considered and not done: making a new Connect wait before opening the sheet until earlier revokes finish (delays the sheet up to unwatchWait, and a bounded wait reopens the race). Open questions left as they were: invalid_grant during the sheet still drops the sheet's sign-in without exchanging it (nothing revoked, so it already meets the never-revoke rule; keeping it is the user's call); if the old sign-in ends during the post-exchange list reads the new grant is still handed back (only the new grant is ended; the old is dead). login_hint not added.
- 2026-11-24T16:05:04Z [implementer-2] Commit f3aa1fa. (3) withToken in the model and in GoogleWatchKeeper capture the generation and check it after the first token, after a 401 (before invalidate()/watchTokenRejected()) and after the renewal; a change throws, so the answer is dropped (callers already skip on a generation change); createEvent maps it to .failed(.signInTrouble). (5) Gaps: Disconnect during the switch's stopAndRevoke (A revoked once, B handed back, nothing kept); unwatch outlasting unwatchWait (A revoked before B saved, unwatch still held after connect, B's watch after it with B's token); no primary from connected and from expired; the same-account test uses a distinct access token and checks it is the one used after. Fixed my own unwatch-outlasts test once: sampling stub.outstanding at save time is load-dependent (the unwatch was out but not yet at the stub within 200 ms); it now waits until parked after connect. Results (own DerivedData, one run at a time): iPhone 16 / 18.3.1 'Test run with 858 tests in 99 suites passed after 127.031 seconds.' '** TEST SUCCEEDED **'; iPhone 17 / 27.2 'Test run with 858 tests in 99 suites passed after 64.723 seconds.' '** TEST SUCCEEDED **'. iPhone 16 Pro Max not touched; no live Google call; no UI change (no new ConnectProblem case, no copy changed).
