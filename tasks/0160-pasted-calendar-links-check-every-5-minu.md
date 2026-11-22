---
id: 160
title: Pasted calendar links: check every 5 minutes, not every minute (app and API cache)
status: todo
owner: 
depends_on: [158]
created: 2026-11-22T03:30:39Z
updated: 2026-11-22T03:33:05Z
---

## Goal

User decision 2026-11-21: pasted iCal links are the slow fallback (Connect Google is the fast path), and a conditional 'has it changed?' check was considered and dropped as not worth its cost. The app asks for pasted-link events every 5 minutes instead of every 60 seconds, and the API caches a link's events for 5 minutes instead of 1. Fewer Worker requests and about a fifth of the KV writes.

## Acceptance criteria

- [ ] iOS: EventsModel.refreshInterval is 5 minutes; the Today minute loop still runs (sky shares it) but sends a calendar request only when the last answer is 5 minutes old; the pull above the horizon, return to the foreground and adding or removing a link still fetch at once; Google events polling is untouched
- [ ] API: CALENDAR_TTL in api/src/routes/calendar.ts is 300 seconds; comments and any test that states the 60-second value updated; a forced refresh from the app (pull) must still get fresh events: check how force reaches the API today and keep that behaviour, or say in the log if a pull can now return a cached answer up to 5 minutes old
- [ ] memory/decisions/2026-11-19-google-calendar-api-and-refresh.md gets a dated line recording the new numbers and why; npm test and tsc pass; openapi unchanged; iOS suite passes on both runtimes

## Relevant files

- ios/Seasign/Calendar/EventsModel.swift
- ios/Seasign/Today/TodayView.swift
- api/src/routes/calendar.ts
- memory/decisions/2026-11-19-google-calendar-api-and-refresh.md

## What's been tried


## Log

- 2026-11-22T03:30:39Z [li] created (todo)
- 2026-11-22T03:33:05Z [li] Lead (user asked 2026-11-21 whether a pull forces a check): a pull must bypass the server cache. Today a forced refresh from the app still gets the KV-cached answer (calendar.ts reads the cache unconditionally). Add an optional boolean (for example fresh: true) to POST /v1/calendar/events that skips the cache read and re-fetches the link, then writes the cache as usual; the app sends it for the pull, for adding a link and on return to the foreground after more than 5 minutes, not for the scheduled checks. This changes the spec: regenerate openapi and the Swift client in this task. The calendar rate limit (20 a minute per address) is the brake; test that fresh does not bypass it. This replaces the 'or say in the log' option in criterion 2.
