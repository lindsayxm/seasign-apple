---
id: 14
title: iOS: Sign in with Apple, sync, account deletion
status: backlog
owner: 
depends_on: [13]
created: 2026-11-15T22:33:55Z
updated: 2026-11-24T19:05:41Z
---

## Goal

Superseded design: read plans/2026-11-24-account-and-subscription.md (approved 2026-11-24), phase C. Sign in with Apple straight after a successful purchase (never offered without one), the 'account not finished' state, first upload then sync both ways, sync and Google Calendar push paused on lapse, in-app account deletion with the note that it does not cancel the subscription. To be split into smaller tasks when phase C starts. Adding the Sign in with Apple and In-App Purchase capabilities needs the user's approval first.

## Acceptance criteria

- [ ] Signed-out use is unchanged
- [ ] After sign-in, local data appears in D1 and changes sync both ways
- [ ] Account deletion removes server data and signs out

## Relevant files

- ios/Seasign/Auth/
- ios/Seasign/Sync/

## What's been tried


## Log

- 2026-11-15T22:33:55Z [li] created (backlog)
- 2026-11-24T15:55:23Z [li] Lead 2026-11-24: design replaced by plans/2026-11-24-account-and-subscription.md once the user approves it (sign-in joined to the purchase; no free optional sign-in). Do not start from the old goal.
- 2026-11-24T19:05:41Z [li] edited section: Goal
