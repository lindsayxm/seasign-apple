---
id: 174
title: API: calendar time follow-ups: skipped-hour instants, stale instance beside an override, sweep test time
status: review
owner: implementer-1
depends_on: []
created: 2026-11-22T18:45:19Z
updated: 2026-11-24T15:55:09Z
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
- 2026-11-24T15:47:21Z [implementer-1] Tests written first in api/test/calendar-time.test.ts (with helper api/test/zone-changes.ts, which reads offset changes with Intl alone): run against unchanged calendar.ts, 8 of 9 fail (Beirut/Berlin/New York floating, TZID in a skipped hour, Santiago all-day, Beirut day, all-zones placeEvent property sweep, on-call 7-day override, override of any length, non-repeating override); the 9th is a guard that an override far from the window is not looked up.
- 2026-11-24T15:55:08Z [implementer-1] Fix 1 (0b5ae04): wallToEpoch places a wall time the clocks skip at the instant of the jump (binary search between the two readings for the first instant whose clock is past the time; last gap per zone remembered so many times in one gap cost one search). dayStart removed: dayBounds calls wallToEpoch directly. Verified: Beirut/Berlin/New York tests, an all-zones property test through placeEvent (every 15 min, 3 h either side of each 2026 change, non-decreasing and own-or-jump instant, checked against Intl), the un-narrowed all-zones sweep passed in workerd before narrowing, and the same sweep and property check in Node (tzdata 2024b, Asuncion still jumping over midnight) for 2024, 2026 and 2027: no failures. VTIMEZONE times (zoneOffset) unchanged: they keep the RFC 5545 reading (offset before the gap).
- 2026-11-24T15:55:09Z [implementer-1] Fix 2 (0b5ae04): RECURRENCE-IDs are collected as plain values (wall, isDate, utc, tzid) and placed lazily in expand once the master's length is known, with the EXDATE bound (wall + NEAR > keepFrom - duration); sorted per UID, each placed at most once (placedFrom index), so the shared-UID linear-time test still passes. Only ids starting after the window are dropped up front. Covers both the repeating path (offer) and the single-event path. A RECURRENCE-ID now sets partial / spends the TZID allowance only when an event with its UID reaches back to it.
- 2026-11-24T15:55:09Z [implementer-1] Fix 3: the all-zones dayBounds sweep now checks, per zone, the days around each 2026 offset change (found with Intl alone in api/test/zone-changes.ts) plus the first of each month, and asserts the change days were found (Santiago 09-06, Havana 03-08, New York 03-08, Beirut 03-29 among them). With the gap fix disabled by hand it names Havana 03-08, Santiago 09-06 and Azores 03-29, so it keeps its teeth. Sweep 768 ms; calendar-day test time 9.00 s before, 2.5 s after. npm test 22 files / 1987 passed; tsc clean; npm run openapi gives no diff.
- 2026-11-24T15:55:09Z [implementer-1] For the lead: an EXDATE or RECURRENCE-ID written in UTC by the RFC reading for a TZID time in a skipped hour no longer matches when the file has no VTIMEZONE (checked: daily DTSTART;TZID=Europe/Berlin:...T023000 with EXDATE:20260329T013000Z, read 2026-03-28T12:00Z: the 29th now shows at 01:00Z; with a VTIMEZONE it is still dropped). If the RFC reading is preferred for TZID times, only the iana case of resolveWall needs to change; floating and all-day placement need the jump either way.
- 2026-11-24T15:55:09Z [implementer-1] status: in-progress → review
