---
id: 14
title: iOS: Sign in with Apple, sync, account deletion
status: backlog
owner: 
depends_on: [13]
created: 2026-11-15T22:33:55Z
updated: 2026-11-15T22:33:55Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. Blocked until the Apple Developer account is approved. Optional Sign in with Apple in Settings; on first sign-in upload local SwiftData to the API, then keep it in sync; in-app account deletion. The app keeps working signed out.

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
