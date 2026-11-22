---
id: 171
title: iOS: add an event by typing: + entry, phrase parser, confirm popup, create
status: todo
owner: 
depends_on: [170]
created: 2026-11-22T17:50:02Z
updated: 2026-11-22T19:18:18Z
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
