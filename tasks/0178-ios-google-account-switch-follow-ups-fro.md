---
id: 178
title: iOS: Google account-switch follow-ups from the #175 review
status: backlog
owner: 
depends_on: []
created: 2026-11-23T01:15:22Z
updated: 2026-11-23T01:15:22Z
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
