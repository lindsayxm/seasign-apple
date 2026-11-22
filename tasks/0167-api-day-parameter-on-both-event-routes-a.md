---
id: 167
title: API: day parameter on both event routes; accessRole on the Google calendar list
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-22T17:50:02Z
updated: 2026-11-22T17:50:18Z
---

## Goal

Plan plans/2026-11-22-day-calendar-and-voice.md, task 2. The day screen needs every event of one day, ended ones included; both routes return only events that have not ended. The default-calendar picker needs to know which Google calendars are writable.

## Acceptance criteria

- [ ] POST /v1/calendar/events and POST /v1/google/events take an optional day (YYYY-MM-DD, validated, used with the existing timezone); with it they return the events that overlap that day in that zone, ended ones included, all-day events placed as now, sorted as now, same cap; without it behaviour is byte-for-byte as before (existing tests untouched and passing)
- [ ] Pasted links: first establish what the KV entry holds (CachedCalendar, parseCalendar's window); if it does not cover earlier today, widen what is parsed and cached so a day request is answered from the cache like any other; fresh still works; memory caps unchanged or re-argued in the log. Google: timeMin at the start of the day; the day may be today or within the existing 7-day window (reject others with the fixed 400)
- [ ] GET /v1/google/calendars returns Google's accessRole per calendar (owner, writer, reader, freeBusyReader) from calendarList, nothing else new
- [ ] Tests for each of the above including zone edges (an event ending at local midnight, an all-day event, a day in a zone far from UTC); npm test and npx tsc --noEmit pass; npm run openapi regenerated; the iOS app still builds

## Relevant files

- api/src/routes/calendar.ts
- api/src/routes/google.ts
- api/src/lib/calendar.ts
- api/src/lib/google.ts
- api/test
- openapi/

## What's been tried


## Log

- 2026-11-22T17:50:02Z [li] created (todo)
- 2026-11-22T17:50:18Z [implementer-1] status: todo → in-progress — claimed by implementer-1
