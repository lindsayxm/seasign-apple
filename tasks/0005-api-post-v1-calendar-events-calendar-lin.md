---
id: 5
title: API: POST /v1/calendar/events (calendar links)
status: review
owner: implementer-1
depends_on: [2, 3, 16]
created: 2026-11-15T22:33:55Z
updated: 2026-11-16T00:55:52Z
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
