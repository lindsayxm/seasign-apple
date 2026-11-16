---
id: 5
title: API: POST /v1/calendar/events (calendar links)
status: in-progress
owner: implementer-1
depends_on: [2, 3, 16]
created: 2026-11-15T22:33:55Z
updated: 2026-11-16T01:11:05Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. Add POST /v1/calendar/events. Body: up to 10 calendar links (Google secret iCal address, Apple published link, Outlook published link). Rewrite webcal:// to https://, allow https only, reject private and local hosts, cap size and time. Fetch each .ics, parse with ical.js, expand repeating events, and return events starting from now within the next 7 days, soonest first, with title, start, end, all-day flag. Cache per link in KV for 15 minutes under a SHA-256 hash of the link. Never log links. One failing link does not fail the rest; report it per link. Regenerate spec and client.

## Acceptance criteria

- [x] Tests with .ics fixtures cover single, all-day, repeating and timezone events, and a failing link
- [x] Tests prove http and private-address links are rejected and that KV keys do not contain the link
- [x] npm test and npx tsc --noEmit pass
- [x] openapi/openapi.json regenerated and the iOS app still builds

## Relevant files

- api/src/routes/calendar.ts
- api/src/lib/safe-fetch.ts
- api/test/
- openapi/openapi.json

## What's been tried

- Relying on an iteration cap alone to bound recurrence CPU: a single ical.js next() call can spin for a minute or more (FREQ=DAILY;BYMONTH=2;BYMONTHDAY=30 ran 59 s then threw; FREQ=SECONDLY;BYMONTH=6 and FREQ=DAILY;BYMONTHDAY=-31;BYMONTH=2 also spin). Date.now() does not advance during CPU work in Workers, so a time budget cannot interrupt it either. Rules must be vetted before they are iterated.
- Checking a VTIMEZONE only for rule shape (yearly, safe parts): the number of observances was not bounded, and ical.js expands each from its DTSTART on first use. 20 zones x 300 observances from 1601 took 22 s; one event with 100,000 EXDATEs took 2.3 s. Fixed by limiting repeating observances (12 per zone, 40 per file), doing zone maths only within 3 days of the window, applying EXDATE in our code and removing it before ical.js iterates, and skipping events with more than 2,000 EXDATE+RDATE values. After: 0.2 s and 0.3 s.

## Log

- 2026-11-15T22:33:55Z [li] created (todo)
- 2026-11-15T22:38:11Z [li] depends on: #2 → #2, #3
- 2026-11-15T23:09:17Z [li] depends on: #2, #3 → #2, #3, #16
- 2026-11-16T00:17:40Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-16T00:25:58Z [implementer-1] Installed ical.js 2.2.1 with the installed npm 10.9.2 (no crash). It loads and expands rules in workerd. Findings that shape the design: (1) a TZID with no VTIMEZONE in the file gives a floating Time, so toUnixTime() would read it as UTC; times are resolved in our own code (file VTIMEZONE, else IANA via Intl, else the request timezone). (2) TimezoneService is isolate-global and is never used. (3) about 9 microseconds per recurrence step in workerd (20,000 daily steps = 185 ms).
- 2026-11-16T00:25:58Z [implementer-1] tried: Relying on an iteration cap alone to bound recurrence CPU: a single ical.js next() call can spin for a minute or more (FREQ=DAILY;BYMONTH=2;BYMONTHDAY=30 ran 59 s then threw; FREQ=SECONDLY;BYMONTH=6 and FREQ=DAILY;BYMONTHDAY=-31;BYMONTH=2 also spin). Date.now() does not advance during CPU work in Workers, so a time budget cannot interrupt it either. Rules must be vetted before they are iterated.
- 2026-11-16T00:47:16Z [implementer-1] Built api/src/lib/safe-fetch.ts (safeFetch, parseSafeUrl, assertSafeUrl, SafeFetchError), api/src/lib/calendar.ts (parseCalendar, upcomingEvents, isSafeRule) and api/src/routes/calendar.ts, mounted in src/app.ts. Design: the cached value per link is the list of occurrences from now-1d to now+8d as instant/floating/allDay, so one cached copy answers any request time zone for the 15 minute TTL; key cal:v1:<sha256 of the checked https URL>, so webcal:// and https:// forms share an entry. Per-link failures come back as {index, ok:false, error} with status 200; only a malformed body is a 400. Logs carry the index and an error code only.
- 2026-11-16T00:47:16Z [implementer-1] CPU bounding: isSafeRule whitelists rule shapes (DAILY/WEEKLY/MONTHLY/YEARLY; BYDAY, BYMONTHDAY, BYMONTH, limited BYSETPOS; interval <= 100), checked by fuzzing about 20,000 random rules against ical.js in Node with a kill timeout; events with other rules are skipped. Unsafe VTIMEZONEs are dropped before any time is decoded. A per-file work budget (weighted by measured step cost) caps the rest, and seekStart moves the iterator start near today for rules without COUNT; a test compares seek against plain iteration for 28 rule shapes at 4 dates. Limits chosen: RANGE=THISANDFUTURE overrides apply to their own instance only; a TZID that is neither in the file nor an IANA name is treated as floating; sub-daily rules (HOURLY and finer) are skipped.
- 2026-11-16T00:55:46Z [implementer-1] tried: Checking a VTIMEZONE only for rule shape (yearly, safe parts): the number of observances was not bounded, and ical.js expands each from its DTSTART on first use. 20 zones x 300 observances from 1601 took 22 s; one event with 100,000 EXDATEs took 2.3 s. Fixed by limiting repeating observances (12 per zone, 40 per file), doing zone maths only within 3 days of the window, applying EXDATE in our code and removing it before ical.js iterates, and skipping events with more than 2,000 EXDATE+RDATE values. After: 0.2 s and 0.3 s.
- 2026-11-16T00:55:46Z [implementer-1] Verified: npm test 312 passed (5 files), npx tsc --noEmit clean, npm run openapi wrote openapi/openapi.json (adds /v1/calendar/events and 5 schemas), xcodegen generate + xcodebuild test on iPhone 16 / iOS 18.3.1: 73 tests in 13 suites passed, TEST SUCCEEDED (with the other agent's uncommitted ios/ work present). wrangler dev --port 8788 answered the route (refused links per index, 400 for bad bodies); stopped afterwards. Commits 5f921ec and the follow-up. The task file itself is not committed: the hook blocks staging it from an agent. Left open: 'partial' is cached but not returned; no per-IP rate limit; DNS-level private addresses cannot be checked in a Worker.
- 2026-11-16T00:55:52Z [implementer-1] status: in-progress → review
- 2026-11-16T01:08:33Z [implementer-1] criterion 1 met: Tests with .ics fixtures cover single, all-day, repeating and timezone events, and a failing link
- 2026-11-16T01:08:33Z [implementer-1] criterion 2 met: Tests prove http and private-address links are rejected and that KV keys do not contain the link
- 2026-11-16T01:08:33Z [implementer-1] criterion 3 met: npm test and npx tsc --noEmit pass
- 2026-11-16T01:08:33Z [implementer-1] criterion 4 met: openapi/openapi.json regenerated and the iOS app still builds
- 2026-11-16T01:08:33Z [implementer-1] review: CHANGES NEEDED. All four criteria verified and ticked (npm test 312 passed, tsc clean, npm run openapi gives no diff; fixtures cover single/all-day/repeating/timezone/failing link; http, private hosts and KV-key tests are real; criterion 4's iOS build is taken on the implementer's word as the lead instructed, not rebuilt). The criteria are about tests, so they hold, but the security goal does not yet: (1) BLOCKING isSafeRule bypass: FREQ=MONTHLY;INTERVAL=48;BYDAY=5MO (also INTERVAL=96, -5MO, 5MO,5TU) with a DTSTART in February of a year that is never a leap year under that interval (e.g. 20260210) passes the whitelist and spins ical.js for more than 45 s (killed) in one next() call: the fifth-weekday guard in api/src/lib/calendar.ts:256 only fires when BYMONTH is present, but an INTERVAL that is a multiple of 12 pins the month too. (2) Work the budget does not see: 20k overrides + 22k masters sharing one UID in a 2 MB file take 6.2 s (the suppression Set is copied per master, calendar.ts:641); 62k empty VTIMEZONEs take 2.8 s (removed one by one, calendar.ts:583). (3) A single malformed RRULE value (FREQ=FOO, COUNT=abc, BYDAY=XX, BYMONTH=13, BYSETPOS=400) makes ICAL.parse throw, so the whole calendar is reported not_calendar instead of skipping one event. (4) POST with a non-JSON Content-Type returns 500 internal_error instead of 400. safe-fetch.ts: no bypass found in about 135 URL forms and 12 redirect cases; no link in responses, logs, KV keys or values. Correctness probes (all-day east/west of UTC, EXDATE, RECURRENCE-ID, DST with and without VTIMEZONE, Windows TZID, floating, in-progress, no DTEND, cancelled, window edges, common rule shapes, seek vs no-seek) all matched hand calculation.
- 2026-11-16T01:11:04Z [implementer-1] status: review → in-progress
- 2026-11-16T01:11:05Z [implementer-1] lead: sent back after review. Must fix: (1) isSafeRule bypass (MONTHLY with INTERVAL a multiple of 12 and a 5th-weekday ordinal). Also fix in this round: (2) quadratic work with shared UIDs and with many empty VTIMEZONEs; (3) one malformed RRULE must not fail the whole calendar; (4) wrong or missing Content-Type returns the 400 invalid_request body, and the spec documents every status the route can return; (5) map common Windows zone names to IANA when no VTIMEZONE is present; (6) apply EXDATE;VALUE=DATE to timed series; (7) de-duplicate links after normalisation; (8) add partial: boolean to CalendarStatus in the response.
