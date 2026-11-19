---
id: 155
title: API: Google route follow-ups from review (usageLimits clause, eventTypes, rate limit, decision file)
status: done
owner: lead
depends_on: []
created: 2026-11-19T19:58:17Z
updated: 2026-11-19T19:59:24Z
---

## Goal


## Acceptance criteria


## Relevant files

- api/src
- api/test
- api/wrangler.jsonc
- memory/decisions

## What's been tried


## Log

- 2026-11-19T19:58:17Z [lead] created (todo)
- 2026-11-19T19:58:17Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-19T19:59:24Z [lead] From the #153 review: (1) isRateLimitBody no longer treats the whole usageLimits domain as a rate limit (accessNotConfigured now reads as forbidden); (2) events.list asks only for eventTypes default and fromGmail, so working location, focus time, out of office and birthdays are left out (lead's product default, flagged to the user); (3) google rate limit 120 -> 600 per 60 s in rate-limit.ts and wrangler.jsonc; (4) decision file: google row, namespace 19006, X-Google-Token in the post-deploy log check. Tests added; npm test and tsc pass; spec unchanged. Closed by the lead without a separate reviewer.
- 2026-11-19T19:59:24Z [lead] status: in-progress → review
- 2026-11-19T19:59:24Z [lead] status: review → done
