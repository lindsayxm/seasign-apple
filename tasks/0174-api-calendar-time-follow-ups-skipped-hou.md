---
id: 174
title: API: calendar time follow-ups: skipped-hour instants, stale instance beside an override, sweep test time
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-22T18:45:19Z
updated: 2026-11-24T15:38:03Z
---

## Goal

From the two #167 reviews; none blocks the day screen. (1) wallToEpoch returns the earlier instant for a wall time inside a skipped hour, against its own comment; a floating event in a spring-forward hour can come back with its end before its start (Asia/Beirut 2026-03-29, 00:45 to 01:00 in the day view; Berlin 02:45 on 2026-03-29 on plain requests). (2) The override-suppression filter in parseCalendar (about line 1632) ignores the instance's length, unlike the EXDATE and RDATE filters, so a long instance replaced by an override is shown beside it once its RECURRENCE-ID is far enough back. (3) The all-zones sweep in api/test/calendar-day.test.ts took 5 to 18 s under load against a 30 s timeout; Node's zone data also flags America/Asuncion.

## Acceptance criteria

- [ ] No event is ever returned with end before start; skipped-hour times resolve to the instant of the jump; tests for Beirut, Berlin and New York
- [ ] A replaced instance is never shown beside its override whatever its length; test with the weekly 7-day series
- [ ] The sweep test runs well inside its timeout (narrow it to zones with a midnight change, or precompute); npm test and tsc pass; spec unchanged

## Relevant files

- api/src/lib/calendar.ts
- api/test

## What's been tried


## Log

- 2026-11-22T18:45:19Z [li] created (backlog)
- 2026-11-24T15:38:03Z [li] status: backlog → todo
- 2026-11-24T15:38:03Z [implementer-1] status: todo → in-progress — claimed by implementer-1
