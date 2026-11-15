---
id: 5
title: API: POST /v1/calendar/events (calendar links)
status: todo
owner: 
depends_on: [2, 3]
created: 2026-11-15T22:33:55Z
updated: 2026-11-15T22:38:11Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. Add POST /v1/calendar/events. Body: up to 10 calendar links (Google secret iCal address, Apple published link, Outlook published link). Rewrite webcal:// to https://, allow https only, reject private and local hosts, cap size and time. Fetch each .ics, parse with ical.js, expand repeating events, and return events starting from now within the next 7 days, soonest first, with title, start, end, all-day flag. Cache per link in KV for 15 minutes under a SHA-256 hash of the link. Never log links. One failing link does not fail the rest; report it per link. Regenerate spec and client.

## Acceptance criteria

- [ ] Tests with .ics fixtures cover single, all-day, repeating and timezone events, and a failing link
- [ ] Tests prove http and private-address links are rejected and that KV keys do not contain the link
- [ ] npm test and npx tsc --noEmit pass
- [ ] openapi/openapi.json regenerated and the iOS app still builds

## Relevant files

- api/src/routes/calendar.ts
- api/src/lib/safe-fetch.ts
- api/test/
- openapi/openapi.json

## What's been tried


## Log

- 2026-11-15T22:33:55Z [li] created (todo)
- 2026-11-15T22:38:11Z [li] depends on: #2 → #2, #3
