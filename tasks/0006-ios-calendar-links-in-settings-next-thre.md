---
id: 6
title: iOS: calendar links in Settings, next three events on Today
status: done
owner: implementer-2
depends_on: [4, 5]
created: 2026-11-15T22:33:55Z
updated: 2026-11-16T21:28:22Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. Settings gets a Calendars section: paste a link, name it, remove it (SwiftData CalendarLink), with short instructions for where to find the link in Google, Apple and Outlook. Today shows the next three events from /v1/calendar/events to the right of the date, as in ref-img/00-button-meanings.png (time, then title in caps). Cache the last result locally so Today shows events before the network answers.

## Acceptance criteria

- [x] Adding a link in Settings shows its next three events on Today; removing it clears them
- [x] No calendar permission prompt appears; Info.plist has no calendar usage string
- [x] A failing link shows a message in Settings, not an empty Today
- [x] Simulator screenshot of Today with events recorded in the task log; tests pass on both simulators

## Relevant files

- ios/Seasign/Settings/
- ios/Seasign/Today/
- ios/Seasign/Calendar/

## What's been tried


## Log

- 2026-11-15T22:33:55Z [li] created (todo)
- 2026-11-16T02:22:05Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-16T02:27:52Z [implementer-2] Plan: CalendarLink (@Model) in userModels; CachedEvents (JSON snapshot keyed by link UUID, no URL) in cacheModels; pure types in ios/Seasign/Calendar (UpcomingEvent, EventsSnapshot, EventPicker, EventLabel, LinkMask, EventZone); EventsModel + EventsStore; SeasignAPI.calendarEvents with payload-free failures; Settings section; EventsColumn on Today; DEBUG -debugEvents YES. Provider steps checked today against support.google.com/calendar/answer/37648, Apple iPhone User Guide 'Share iCloud calendars' (iOS 18 and 27), support.microsoft.com 'Share your calendar in Outlook.com'.
- 2026-11-16T02:42:40Z [implementer-2] Built (commits eccca02 and the one after): CalendarLink in the user store, CachedEvents in the cache store, SeasignAPI.calendarEvents, EventsModel/EventsStore, pure EventPicker/EventLabel/EventZone/LinkMask, Calendars section in Settings, EventsColumn on Today, DEBUG -debugEvents YES. Tests: 149 pass on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2), including stores written with the pre-task schema opening with nothing lost and the cache kept. No EventKit import; built Info.plist has no calendar usage key.
- 2026-11-16T02:42:40Z [implementer-2] Screenshots (sample data via -debugEvents YES): Today with events, iPhone 16 / iOS 18.3.1: /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task6/today-events.png ; Settings Calendars section, iPhone 17 / iOS 27.2: /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task6/settings-calendars.png . Driven in the Simulator (iOS 27.2): Remove with confirmation drops the row and its events from Today; Add with no API running shows 'We couldn't check that link' and saves nothing.
- 2026-11-16T02:42:40Z [implementer-2] Live check against wrangler dev skipped: it needs an .ics served over https from a public host, which was not available. Instead a test decodes a body copied from api/test/calendar.test.ts, and the API's date format (whole-second UTC, calendar.ts instant()) was checked against the generated client's ISO 8601 decoding. So criterion 1 is shown by EventsModelTests with the stub transport, not end to end.
- 2026-11-16T02:42:40Z [implementer-2] status: in-progress → review
- 2026-11-16T02:43:58Z [implementer-2] criterion 2 met: No calendar permission prompt appears; Info.plist has no calendar usage string
- 2026-11-16T02:43:58Z [implementer-2] criterion 3 met: A failing link shows a message in Settings, not an empty Today
- 2026-11-16T02:43:58Z [implementer-2] criterion 4 met: Simulator screenshot of Today with events recorded in the task log; tests pass on both simulators
- 2026-11-16T02:43:58Z [implementer-2] review (lead): ran the suite on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2): 149 tests passed on each. Viewed today-events.png: three events to the right of the date, times and caps titles as in the mockup. No EventKit import or logging calls in ios/Seasign. Criteria 2-4 ticked. Criterion 1 left unticked: add-link-to-events is proven by stub-transport tests only; a live check needs a real calendar link over https, which the user can paste into the Simulator with wrangler dev running. Staying in review until then.
- 2026-11-16T21:11:11Z [lead] Session end 2026-11-16: still waiting on criterion 1, the live check with a real calendar link pasted by the user in the Simulator while npx wrangler dev runs in api/. Everything else is ticked.
- 2026-11-16T21:28:22Z [lead] Live check 2026-11-16 (lead with the user): local API on wrangler dev; the user pasted a real Google secret iCal address in the Simulator. First attempt failed with the connection message because wrangler dev was not running; after starting it the link was accepted (POST /v1/calendar/events 200 in the wrangler log, and the log holds no part of the link). The user confirmed the next events show on Today with the right titles and times, and that removing the link clears them. No screenshot was taken, to keep the user's real calendar out of the session.
- 2026-11-16T21:28:22Z [lead] criterion 1 met: Adding a link in Settings shows its next three events on Today; removing it clears them
- 2026-11-16T21:28:22Z [lead] status: review → done
