---
id: 168
title: API: POST /v1/google/events/create (events.insert with the user's token)
status: in-progress
owner: implementer-1
depends_on: [167]
created: 2026-11-22T17:50:02Z
updated: 2026-11-22T18:48:05Z
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
- 2026-11-22T18:48:05Z [implementer-1] Docs read 2026-11-22 (read-only, no Google API call). events.insert https://developers.google.com/workspace/calendar/api/v3/reference/events/insert : POST /calendar/v3/calendars/{calendarId}/events; required body start and end (end exclusive); scopes accepted include calendar.events.owned; success returns the Events resource. sendUpdates: 'all' | 'externalOnly' | 'none'; the page states the default as false (the parameter is a string) and warns 'some emails might still be sent'; we set no attendees, so there is no one to notify, and we do not send sendUpdates=none because the page says none 'can have significant adverse effects, including events not syncing to external calendars'. Event resource https://developers.google.com/workspace/calendar/api/v3/reference/events : id writable on create; base32hex characters only (lowercase a-v, 0-9), length 5 to 1024, unique per calendar, and 'we cannot guarantee that ID collisions will be detected at event creation time'. start.dateTime needs an offset unless timeZone is given; timeZone optional for single events; start.date/end.date yyyy-mm-dd for all-day, end exclusive. Errors guide https://developers.google.com/workspace/calendar/api/guides/errors : 409 reason 'duplicate' (domain global) message 'The requested identifier already exists.' with no event in the body; 409 reason 'conflict' is a different case; 403 reasons documented there are only rate/quota (userRateLimitExceeded, rateLimitExceeded, quotaExceeded) and forbiddenForNonOrganizer. NOT in Google's Calendar docs: the 403 for a token without a write scope and the 403 for a calendar the user cannot write to. Google-wide: ErrorReason ACCESS_TOKEN_SCOPE_INSUFFICIENT 'the provided access token doesn't have at least one of the acceptable scopes' https://github.com/googleapis/googleapis/blob/master/google/api/error_reason.proto ; AIP-193 https://google.aip.dev/193 says a resource the user may not access is PERMISSION_DENIED (403). RFC 6750 s3.1 defines WWW-Authenticate error="insufficient_scope" with 403. Community reports (not official): scope case is 403 reason insufficientPermissions, message 'Request had insufficient authentication scopes.'; calendar-not-writable is 403 reason requiredAccessLevel, message 'You need to have writer access to this calendar.' (e.g. https://discuss.google.dev/t/cannot-create-calendar-events-with-service-account/139036 , https://community.zapier.com/troubleshooting-99/google-calendar-error-403-the-app-returned-you-need-to-have-writer-access-to-this-calendar-27760 ).
