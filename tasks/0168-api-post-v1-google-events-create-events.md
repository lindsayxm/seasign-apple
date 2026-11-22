---
id: 168
title: API: POST /v1/google/events/create (events.insert with the user's token)
status: in-progress
owner: implementer-1
depends_on: [167]
created: 2026-11-22T17:50:02Z
updated: 2026-11-22T18:45:19Z
---

## Goal

Plan plans/2026-11-22-day-calendar-and-voice.md, task 3. Create one event in a Google calendar the user owns. Header X-Google-Token, never stored or logged. 'with Rahaf' is title text only: no attendees, no invitations, no location, no description, no recurrence.

## Acceptance criteria

- [ ] Look up first and cite in the log: Google's events.insert reference (body, sendUpdates default, client-supplied id rules: allowed characters and length, what a duplicate id answers), and the exact 403 bodies for a token without a write scope versus a calendar the user cannot write to
- [ ] Route under /v1/google (google rate-limit group, no-store): body calendar id, title (trimmed, 1 to 200 characters), either start and end instants with an IANA time zone or an all-day date, and a client-made event id; validation with fixed 400s; end after start; at most 24 hours long for timed events
- [ ] Calls events.insert through postGoogleJson with fields limited to what the app shows; returns the created event in the existing UpcomingEvent shape; a retry with the same id that Google reports as a duplicate is answered as success (the event exists), not as an error
- [ ] Errors: 401 google_auth, 403 insufficient_scope (token lacks write access), 403 forbidden (calendar not writable), 404 not_found, 429 rate_limited, 502 fetch_failed, timeout; fixed bodies; the token, title and times never logged
- [ ] Tests with mocked Google that record the request body: happy path timed and all-day, each error, duplicate id, validation cases, nothing secret or private in logs; npm test and tsc pass; npm run openapi regenerated; the iOS app still builds

## Relevant files

- api/src/routes
- api/src/lib/google.ts
- api/test
- openapi/

## What's been tried


## Log

- 2026-11-22T17:50:02Z [li] created (todo)
- 2026-11-22T18:45:19Z [implementer-1] status: todo → in-progress — claimed by implementer-1
