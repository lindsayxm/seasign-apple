---
id: 171
title: iOS: add an event by typing: + entry, phrase parser, confirm popup, create
status: in-progress
owner: implementer-2
depends_on: []
created: 2026-11-22T17:50:02Z
updated: 2026-11-22T19:57:32Z
---

## Goal

Plan plans/2026-11-22-day-calendar-and-voice.md, task 6. + opens a one-line field; the line is understood on the phone; a popup shows the event and adds it to Google only after Confirm.

## Acceptance criteria

- [ ] EventPhraseParser is pure and tested with a fixed now and zone: the date detector sits behind a protocol (NSDataDetector takes no reference date; look it up in sosumi); rules: no time means all-day, no date means today, a past time today stays today, default length 1 hour, times are in the events zone, lead-ins like 'add a meeting to my calendar' are dropped and the rest becomes a capitalised title ('Meeting with Rahaf'); names are title text only; a missing title or unreadable date gives a draft problem, not a guess
- [ ] Confirm popup: title, day, time, length and target calendar, Confirm and Cancel, a problem state with 'Try again'; Confirm is single-flight; the create call sends a client-made event id reused on retry; errors map to plain-words notes; insufficient_scope leads to 'Connect again to add events'; no Google connection leads to Settings
- [ ] After Confirm the popup closes and the day screen shows 'Added · <day time> · <title>' for a few seconds; an event for today appears in the list at once and Today's next three pick it up on return
- [ ] Tests: parser table (today, tomorrow, weekday names, next week, no time, no date, past time, 24-hour phrasing, noon, midnight), confirm flow with mocked transport (success, each error, double tap, retry with the same id). Suite passes on both runtimes; screenshots on the iPhone 17 with -debugGoogle. No real event is ever created by the agent

## Relevant files

- ios/Seasign/Calendar
- ios/Seasign/API/SeasignAPI.swift
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-22T17:50:02Z [li] created (todo)
- 2026-11-22T19:05:10Z [li] Lead: from #168 and its review. The create call: POST /v1/google/events/create with calendar (Google id), id (32 lowercase hex: a UUID without dashes), title, timezone (must be UTC or an Area/Location IANA name: a device zone like GMT is refused, see SearchDay.ianaName for the existing handling), and either start+end (RFC 3339) or date. Answer: { id, created, event? }; created:false means Google already had that id (a retry that had in fact succeeded): show the app's own draft as added. Mint a fresh id for each confirmed draft; reuse it only for retries of that same draft to the same calendar; a changed draft or calendar gets a new id. Errors: google_auth (renew once and retry, as withToken does), insufficient_scope (lead to Connect again), forbidden (say the calendar cannot take new events; suggest choosing another in Settings), not_found, rate_limited, fetch_failed and timeout (retry with the same id), and after #176 a non-retryable rejected. From #169: canAddEvents true does not guarantee newEventsCalendar is non-nil; check both.
- 2026-11-22T19:18:18Z [li] Lead: from #176: the route refuses titles with control or format characters (bidi marks, zero-width space, soft hyphen, line and paragraph separators, a ZWNJ next to a space) and titles with no visible character: the parser must clean the title before sending (drop those characters, collapse white space) so a pasted or dictated line never gets the fixed 400 for that reason; test it against the same cases. Error rejected (502) means Google refused the event as sent: do not retry; say it was not added. Dates must be within one year back and five years ahead: the parser should refuse anything outside with its own message.
- 2026-11-22T19:51:25Z [li] Lead: dependency on #170 lifted so this can start while #170's fix commit 7091f49 is in its second review (the first review passed the screen's structure; the open points are about holds). DayView shows the mic and + buttons only when their closures are set; pass the + closure here and leave the mic closure for #172. If the #170 reviewer asks for changes in DayModel or GoogleCalendarModel while you work, the lead will tell you.
- 2026-11-22T19:51:25Z [li] depends on: #170 → none
- 2026-11-22T19:51:25Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-22T19:56:36Z [implementer-2] Probe of the real NSDataDetector (.date) on this Mac, 2026-11-22 13:53 America/Chicago (a Sunday), macOS Foundation via swiftc: 'add a meeting to my calendar sunday at 3pm with Rahaf' -> range 'sunday at 3pm' = 2026-11-29 15:00 (Sunday on a Sunday reads as NEXT Sunday); 'lunch tomorrow at noon' -> range includes 'lunch', 11-23 12:00; 'dentist next friday' -> 11-27 12:00 (no time given still 12:00); 'party next week' -> no match; 'call mom at 15:00' -> 11-22 15:00; 'flight at midnight' -> 11-23 00:00; 'dinner tomorrow' -> range includes 'dinner', 11-23 19:00 (meal words invent a time); 'meeting 3pm to 5pm' -> 15:00 duration 7200; 'from 3 to 5pm tomorrow' -> 11-23 15:00 duration 7200; 'standup at 9:30am for 30 minutes' -> 9:30, duration 0 ('for 30 minutes' not read); 'December 3, 2026 at 4pm review' -> 12-03 16:00; '12/3/2026' -> 12-03 12:00; 'dinner at 8' -> no match; 'yoga tonight at 7' -> 11-22 19:00; 'march 3 haircut' -> 2027-03-03 (year rolled from the real today); 'dinner on Dec 24' -> range 'dinner on Dec 24' 19:00; 'tuesday 10am' -> 11-24 10:00; 'meeting at 3 pm EST' -> 14:00 Chicago, timeZone America/New_York; 'in 2 days dinner' -> 11-24 19:00; 'meeting at 3pm for 2 hours' -> 15:00 duration 0; 'meeting sunday at 3' -> 11-29 15:00 (bare 3 read as pm); 'the day after tomorrow lunch' -> 11-24 12:00; 'this weekend hike' -> none; 'in 2 weeks' -> 12-06; 'next tuesday at 3' -> 12-01 15:00 (next tuesday = the one after this coming one, unlike next friday = 11-27); '3 december', 'Dec. 3rd', '2026-12-03', '12/3' -> 12-03 12:00; 'party on the 5th' -> none; 'meeting at 2:30' -> 14:30; 'meeting today' -> 12:00; 'doctor at noon' -> 12:00; 'sunday evening' -> 11-29 18:00; 'monday at 3pm til 4:30pm' -> two matches, no duration; 'call at 9 tomorrow morning' -> 11-23 09:00. Conclusions for the parser: the detector's Date is anchored to the real now and device zone and invents times (12:00 for date-only, 19:00 for dinner), its ranges swallow title words, and its relative readings depend on the real weekday. So: relative words and times are read by the parser's own rules from the injected now and zone; the detector (behind a protocol returning wall-clock parts, range, duration, zone) is used only for explicit calendar dates, with the year re-derived from now when the line gives none; title removal takes out only date/time tokens and their connectors.
- 2026-11-22T19:57:32Z [implementer-2] Lead: one small extra from the #170 review, in files you are in: when a source failed with nothing read from it, the day screen must not show 'Nothing on your calendar today.' under the failure line (DayModel about 284-289, DayView about 189-201): show the empty-day line only when every configured source has answered. Test it.
