---
id: 18
title: API: bound memory on the calendar path
status: in-progress
owner: implementer-1
depends_on: [7]
created: 2026-11-16T03:45:09Z
updated: 2026-11-16T13:21:28Z
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


## Log

- 2026-11-16T03:45:09Z [li] created (backlog)
- 2026-11-16T13:15:23Z [li] status: backlog → todo
- 2026-11-16T13:15:23Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-16T13:21:28Z [implementer-1] Harness: api/scripts/calendar-memory.ts (Node 22.14, --experimental-strip-types). Builds a named shape in-process at the size cap, decodes it with TextDecoder like the route, runs parseCalendar under --max-old-space-size, two runs per cap, caps 160..8 MB; reports the smallest cap where both runs pass. BASELINE at 2 MB, before any change (passes at / fails at, MB): exdate-lines (83k EXDATE lines, one event) 120/112; rdate-lines 120/112; rrule-lines (RRULE lines in one event) 112/104; exdate-values (one EXDATE line, 116k values) 96/88; nested-open (233k BEGIN:X, refused) 96/88; small-events (28k 4-line events) 88/80; overrides-shared-uid 88/80; exdate-lines-tzid 80/64; zone-rdates 72/64; events-in-window 64/60; nested-closed 64/60; nested-in-event 64/60; ignored-lines (X: lines) 60/56; events-with-alarms 60/56; small-events-tzid 60/56; dtstart-lines 52/48; no-colon-lines 52/48; summary-lines 44/40; zone-observances 44/40; smallest-events 40/36; blank-lines, huge-summary-escaped, many-calendars, sibling-components, tzid-dtstart-lines, vtimezones-empty, vtimezones-full 36/32; alarms-in-one-event, folded-summary 28/24; ordinary (2,600 Google-style events, 1.85 MB) 28/24; long-summaries 24/20; huge-summary, huge-summary-bad-bytes, huge-uid 20/16; huge-description, lf-folds, params, tzid-long 16/12; tiny 12/8. Matches task 7's figures for exdate (112) and nesting (96); my small-events shape is a little denser than task 7's (88 vs 56).
