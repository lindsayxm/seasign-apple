---
id: 153
title: API: read Google calendars with the user's token (calendar list and events)
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-19T19:33:51Z
updated: 2026-11-19T19:46:27Z
---

## Goal

Plan plans/2026-11-19-google-calendar-push.md, task A. The app will send a short-lived Google OAuth access token in the X-Google-Token header; the Worker calls the Google Calendar API and answers in the same event shape as /v1/calendar/events. Local only; nothing is deployed.

## Acceptance criteria

- [ ] GET /v1/google/calendars (header X-Google-Token): the user's calendars from calendarList.list as id, name, primary flag, colour if cheap. POST /v1/google/events (header X-Google-Token; body: calendar ids (max 10) and timezone): events that have not ended and start within the next 7 days, soonest first, at most 50, with the same event fields and all-day handling as /v1/calendar/events, using events.list with singleEvents=true, orderBy=startTime, timeMin/timeMax; cancelled events left out; a per-calendar ok/error status like the existing route
- [ ] Look up the current Google Calendar API reference (events.list, calendarList.list, error bodies) before writing; do not rely on memory. Plain fetch to https://www.googleapis.com only; no SDK or new package
- [ ] The token is never stored, cached, logged or echoed; responses are not cached in KV (the point is freshness) and carry Cache-Control: no-store; a test proves the token appears in no log line, KV key or value, or response
- [ ] Errors mapped and declared in the spec: missing/malformed header 400; Google 401 -> 401 google_auth (the app must refresh its token); 403/404 per calendar -> that calendar's status; Google 429/5xx -> 502 or per-calendar fetch_failed; our own rate limit 429 as on other routes (new limiter group or reuse of calendar's; keep RATE_LIMITS equal to wrangler.jsonc). Request bodies and outbound time capped like other routes
- [ ] Tests with mocked Google responses (timed, all-day, multi-day, recurring instances, cancelled, paging via nextPageToken, error cases); npm test and tsc pass; npm run openapi regenerates openapi/openapi.json and the Swift client regenerates; the iOS app still builds and its suite passes on one runtime

## Relevant files

- api/src/routes
- api/src/app.ts
- api/src/lib
- api/test
- api/wrangler.jsonc
- openapi/

## What's been tried


## Log

- 2026-11-19T19:33:51Z [lead] created (todo)
- 2026-11-19T19:33:51Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-19T19:46:26Z [implementer-1] Built GET /v1/google/calendars and POST /v1/google/events (api/src/routes/google.ts, Google fetch helper and item mapping in api/src/lib/google.ts). Events reuse CalendarEventSchema (now exported from routes/calendar.ts) and upcomingEvents: Google items become StoredEvents (dateTime -> instant, date -> allDay wall-clock midnights, end.date exclusive), Google asked for now-1d..now+8d with singleEvents=true, orderBy=startTime, maxResults=250, fields limited to status/summary/start/end/endTimeUnspecified; up to 4 pages per calendar, then partial. Title cleaning shared via new cleanTitle() in lib/calendar.ts. Outbound: fetch to https://www.googleapis.com only, redirect manual, 8 s deadline per calendar across all pages, 1 MB per page, 64 KB error bodies. No KV use; Cache-Control: no-store set in app.ts on every /v1/google/* answer (body-limit and 429 included).
- 2026-11-19T19:46:26Z [implementer-1] Error mapping: header missing/malformed 400 invalid_request. Google 401 on any calendar or the list -> 401 google_auth. Per calendar: 403 (non-quota) forbidden, 404/410 not_found, 429 or 403 with usageLimits/rateLimitExceeded/userRateLimitExceeded/quotaExceeded/RESOURCE_EXHAUSTED rate_limited, 5xx/3xx/network/unreadable fetch_failed, deadline timeout, over cap too_large. Calendar list: non-quota 403 -> 403 google_forbidden (likely missing scope; refresh will not help), anything else -> 502 google_unavailable. Rate limit: new group google (RATE_LIMIT_GOOGLE, namespace 19006) 120 per 60 s per client, covering both routes: one phone polling every 5 s is 12/min, so room for about ten phones behind one address; cost per request is small and Google quota is the caller's. wrangler.jsonc and RATE_LIMITS updated together; cf-typegen rerun.
- 2026-11-19T19:46:27Z [implementer-1] Verified: npm test 1690 passed (17 files; new test/google.test.ts 58 tests incl. timed, all-day, multi-day, recurring instances, cancelled, paging, page cap, 50 cap, per-calendar errors, 401, timeouts, token never in logs/KV/responses, no-store, 429 on both routes); tsc clean; npm run openapi regenerated openapi/openapi.json; iOS xcodebuild test on iPhone 17 (iOS 27.2): 449 tests passed, generated client has getGoogleCalendars/postGoogleEvents. Docs read 2026-11-19: events.list, Event resource, calendarList.list and resource, errors guide, performance guide (fields), OAuth2 overview (token size 2048).
