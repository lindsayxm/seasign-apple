---
id: 224
title: API subscription B5: POST /v1/discover requires an active entitlement (hard rule)
status: backlog
owner: 
depends_on: [221]
created: 2026-11-25T02:31:50Z
updated: 2026-11-25T02:31:50Z
---

## Goal

Read plans/2026-11-24-account-and-subscription.md (phase B), memory/decisions/2026-11-24-subscription-gate-and-ai-lapse-rule.md and memory/notes/2026-11-24-storekit-research.md first. HARD RULE: no AI on a subscription that is not active. /v1/discover is refused without a session and without an active entitlement (the B2 check), before any provider is called. The phone must send its session token; this cannot land before phase C gives the phone a session, so it is built and merged together with the iOS change that sends the token.

## Acceptance criteria

- [ ] Tests: no provider fetch happens without a session, for an expired, grace, billing-retry or revoked entitlement, or when the check fails
- [ ] npm test and npx tsc --noEmit pass; spec and client regenerated; iOS builds

## Relevant files

- api/src/routes/discover.ts
- api/test

## What's been tried


## Log

- 2026-11-25T02:31:50Z [li] created (backlog)
