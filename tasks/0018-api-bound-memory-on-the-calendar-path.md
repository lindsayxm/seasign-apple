---
id: 18
title: API: bound memory on the calendar path
status: review
owner: implementer-1
depends_on: [7]
created: 2026-11-16T03:45:09Z
updated: 2026-11-16T13:58:47Z
---

## Goal

Measured during task 7 (Node, --max-old-space-size): parseCalendar on a hostile 2 MB file needs up to 112 MB of old space (83,000 EXDATE lines on one event), 96 MB (233,000 nested BEGIN lines), 56 MB (28,000 small events). A Workers isolate has 128 MB. Bound it: lower the calendar size cap and/or refuse hostile shapes with a linear pre-scan before ICAL.parse, as the feed parser now does. Regression tests must assert refusal, since the local runtime does not enforce the memory limit.

## Acceptance criteria

- [ ] Hostile shapes at the cap need under 64 MB of old space in Node, with the figures in the task log
- [ ] Ordinary Google, iCloud and Outlook fixtures still parse
- [ ] npm test and npx tsc --noEmit pass

## Relevant files

- api/src/lib/calendar.ts
- api/src/routes/calendar.ts
- api/test/

## What's been tried

- Refusing an END with nothing open in the pre-scan: ical.js accepts a stray trailing END:VCALENDAR (seen in the differential fuzz), so refusing it would have broken sloppy but readable files; it is now ignored. Also: counting EXDATE/RDATE from jCal without then decoding them up front let an event emit its DTSTART before a later undecodable RDATE threw, so the event was half-read; values are now decoded right after the count, before anything is placed, as before.

## Log

- 2026-11-16T03:45:09Z [li] created (backlog)
- 2026-11-16T13:15:23Z [li] status: backlog → todo
- 2026-11-16T13:15:23Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-16T13:21:28Z [implementer-1] Harness: api/scripts/calendar-memory.ts (Node 22.14, --experimental-strip-types). Builds a named shape in-process at the size cap, decodes it with TextDecoder like the route, runs parseCalendar under --max-old-space-size, two runs per cap, caps 160..8 MB; reports the smallest cap where both runs pass. BASELINE at 2 MB, before any change (passes at / fails at, MB): exdate-lines (83k EXDATE lines, one event) 120/112; rdate-lines 120/112; rrule-lines (RRULE lines in one event) 112/104; exdate-values (one EXDATE line, 116k values) 96/88; nested-open (233k BEGIN:X, refused) 96/88; small-events (28k 4-line events) 88/80; overrides-shared-uid 88/80; exdate-lines-tzid 80/64; zone-rdates 72/64; events-in-window 64/60; nested-closed 64/60; nested-in-event 64/60; ignored-lines (X: lines) 60/56; events-with-alarms 60/56; small-events-tzid 60/56; dtstart-lines 52/48; no-colon-lines 52/48; summary-lines 44/40; zone-observances 44/40; smallest-events 40/36; blank-lines, huge-summary-escaped, many-calendars, sibling-components, tzid-dtstart-lines, vtimezones-empty, vtimezones-full 36/32; alarms-in-one-event, folded-summary 28/24; ordinary (2,600 Google-style events, 1.85 MB) 28/24; long-summaries 24/20; huge-summary, huge-summary-bad-bytes, huge-uid 20/16; huge-description, lf-folds, params, tzid-long 16/12; tiny 12/8. Matches task 7's figures for exdate (112) and nesting (96); my small-events shape is a little denser than task 7's (88 vs 56).
- 2026-11-16T13:48:22Z [implementer-1] Approach (commit 5e7fd32): readableLines rewritten as one streaming pass over the unfolded text (regex walk, no split): tracks components as ical.js does (count-based, END closes whatever is open), hands ical.js only VCALENDARs and the VEVENTs/VTIMEZONEs directly inside them, with only what cleanEvent/readZone read: first of each single-valued event property, last DTSTART/TZOFFSETFROM/TZOFFSETTO in a zone block, rules (max 8/event) and EXDATE/RDATE (2,000/event, counted by commas). Alarms, unknown components and anything nested are depth-counted, not kept (nested VEVENT/VTIMEZONE still sets partial). Zones that readZone would reject for size (>60 blocks, >12 rules, >400 dates, odd rule) are not handed on; zones after 100 are not read. File-level limits refuse the whole file (CalendarTooLargeError -> route too_large), because file order is not date order and reading a prefix would silently lose upcoming events: 12,000 VEVENTs, 60,000 lines handed on, 20,000 listed dates; text > MAX_CALENDAR_BYTES (kept at 2 MB, now passed to safeFetch explicitly). After parsing, each event is wrapped in its own parentless ICAL.Component and dropped after use (ical.js caches decoded values on the wrapper), and expand counts EXDATE/RDATE from jCal before decoding. Differential fuzz old vs new on 60,000 random small calendars (nesting, folds, groups, duplicates, unknown components): only difference is a stray END at depth 0 followed by another calendar, which the old code refused and the new code reads (more lenient). CPU unchanged (9,000 yearly-from-1900 rules 85 vs 95 ms; 11,000 TZID events 67 vs 69 ms).
- 2026-11-16T13:48:27Z [implementer-1] tried: Refusing an END with nothing open in the pre-scan: ical.js accepts a stray trailing END:VCALENDAR (seen in the differential fuzz), so refusing it would have broken sloppy but readable files; it is now ignored. Also: counting EXDATE/RDATE from jCal without then decoding them up front let an event emit its DTSTART before a later undecodable RDATE threw, so the event was half-read; values are now decoded right after the count, before anything is placed, as before.
- 2026-11-16T13:54:56Z [implementer-1] FINAL figures (commit d08d8d8), serial, 3 runs per cap, 2 MB files, smallest passing cap (fails 4 MB lower): every pre-change hostile shape now 12-16 MB (exdate-lines 120->12, rdate-lines 120->12, rrule-lines 112->12, exdate-values 96->12, nested-open 96->12, small-events 88->12 refused too many events, overrides-shared-uid 88->12 refused, exdate-lines-tzid 80->12, zone-rdates 72->12, events-in-window 64->12 refused, nested-closed 64->12, nested-in-event 64->12, ignored-lines 60->12, events-with-alarms 60->12 refused, small-events-tzid 60->16, dtstart-lines 52->16, no-colon-lines 52->12, summary-lines 44->16, zone-observances 44->12, smallest-events 40->12, blank-lines 36->12, many-calendars 36->12, sibling-components 36->12, vtimezones-empty/full 36->12/16), except huge-summary-escaped 36->32 and folded-summary 28->28 (transient: ical.js unescape and the unfold regex, bounded by the byte cap). ordinary 2,600 events 28->16. New at-limit shapes: full-events (6,666 nine-line events, line limit) 32; full-events-in-window 36; max-rules (8,333 events x 8 RRULE) 32; max-zones (100 zones x 60 blocks + 200 RDATE) 32; max-events (12,000) 28; max-listed-lines (20,000 EXDATE lines) 24; max-listed-values 20; tiny 12. Whole request (--links 10: ten bodies held, ten parses in sequence, results kept): 28-40 MB old space (full-events-in-window 40, others same as single) + bodies 10 x 2 MB outside the heap. Test calendar of 3,000 Google-style events: 1.56 MB, 3,250 VEVENTs, ~23k lines handed on, 250 listed; parses partial:false and equals parsing only its last year. npm test 1494 passed; tsc clean; npm run openapi: no diff.
- 2026-11-16T13:58:43Z [implementer-1] Commit after d08d8d8: titleOf now returns a flat copy. Found by measuring --links 10 with long titles: a 200-char slice kept its whole summary alive and the route holds every link's results, so ten 2 MB summaries needed 56 MB (two-byte) before, 20 MB after; 500 in-window events with 4,000-char titles x10 56 -> 24. Two-byte variants of the at-limit shapes (--two-byte): full-events 32, full-events-in-window 40, max-rules 36, max-zones 32, max-events 32; x10 full-events-in-window 36, max-rules 36. Added a test for the 100-VTIMEZONE hand-on limit. npm test 1495 passed, tsc clean.
- 2026-11-16T13:58:47Z [implementer-1] status: in-progress → review
