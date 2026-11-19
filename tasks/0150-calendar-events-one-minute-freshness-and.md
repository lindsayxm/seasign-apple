---
id: 150
title: Calendar events: one-minute freshness and pull-to-refresh on Today
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-19T15:14:02Z
updated: 2026-11-19T15:14:02Z
---

## Goal

User, 2026-11-19: events added in Google Calendar took about 25 minutes to show (app keeps events 10 min, API caches each calendar 15 min, no manual refresh). Make changes show within about a minute and let the user pull down on Today to refresh. No API contract change.

## Acceptance criteria

- [ ] API: CALENDAR_TTL in api/src/routes/calendar is 60 seconds (check in cloudflare-docs that 60 is KV's minimum expirationTtl; do not go lower); tests that pin 15 minutes updated; npm test and tsc pass; openapi/openapi.json unchanged
- [ ] App: EventsModel.refreshInterval is 60 seconds, comment and tests updated. The existing minute loop and the scenePhase .active trigger in TodayView stay; confirm with a test or the log that an open app now asks about once a minute and stays well under the calendar rate limit (20 per 60 s per IP)
- [ ] Pull down on Today refreshes events with refresh(force: true), which must still honour retryNotBefore after a 429. The pull may also run the sky and feed refreshes under their normal rules, but must never start an AI search (it spends the user's daily cap and key)
- [ ] Today still does not scroll: the pull must not move or bounce the layout or scene at rest, and taps on titles, the three buttons and the all-publications mark still work. Look up .refreshable and its scroll-container requirement in sosumi first. Screenshots of three states through the DEBUG override match the v11 stills as before
- [ ] Reproduced on the iPhone 16 Pro Max simulator (7F57E59E-6D2C-438C-B107-5250AFE1B7D8) against the wrangler dev already running on port 8787: after more than 60 s, a background/foreground and a pull each add a POST /v1/calendar/events to the server log that is not a cache hit. Do not start a second dev server or stop the running one; do not print the calendar link
- [ ] Suite passes on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2

## Relevant files

- api/src/routes
- api/test
- ios/Seasign/Calendar
- ios/Seasign/Today
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-19T15:14:02Z [lead] created (todo)
- 2026-11-19T15:14:02Z [implementer-1] status: todo → in-progress — claimed by implementer-1
