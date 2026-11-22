---
id: 175
title: iOS: Google 'Connect again' follow-ups: a different account, one save for connection and scopes, test gaps
status: in-progress
owner: implementer-2
depends_on: []
created: 2026-11-22T18:54:27Z
updated: 2026-11-22T18:54:27Z
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
