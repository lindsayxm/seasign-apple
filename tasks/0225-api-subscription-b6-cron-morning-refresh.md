---
id: 225
title: API subscription B6: Cron morning refresh for subscribed accounts only
status: backlog
owner: 
depends_on: [222]
created: 2026-11-25T02:31:50Z
updated: 2026-11-25T02:31:50Z
---

## Goal

Read plans/2026-11-24-account-and-subscription.md (phase B), memory/decisions/2026-11-24-subscription-gate-and-ai-lapse-rule.md and memory/notes/2026-11-24-storekit-research.md first. The Cron Trigger morning refresh from the v1 plan, run only for accounts with an active entitlement; list refresh only unless the entitlement is active at that moment for AI (hard rule).

## Acceptance criteria

- [ ] Tests: an account without an active entitlement is skipped and costs no fetch
- [ ] npm test and npx tsc --noEmit pass

## Relevant files

- api/src
- api/wrangler.jsonc
- api/test

## What's been tried


## Log

- 2026-11-25T02:31:50Z [li] created (backlog)
