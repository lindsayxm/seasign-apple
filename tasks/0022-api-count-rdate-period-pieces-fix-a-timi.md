---
id: 22
title: API: count RDATE period pieces; fix a timing-flaky test
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-16T15:16:07Z
updated: 2026-11-16T15:16:07Z
---

## Goal

From the task 18 second review. (1) An RDATE value containing '/' is read by ical.js as a period and it keeps every '/'-separated piece, while our listed-value count sees one value, so one counted value can carry about 500,000 pieces; the heaviest file measured needs 56 MB of old space for one parse (every limit at once in the window plus one period line), not the 48 MB recorded at api/src/lib/calendar.ts:76-81 and in memory/architecture.md. Periods in RDATE are already reported as partial and not used; simplest safe fix: do not hand an RDATE value containing '/' to ical.js at all (set partial), or count '/' pieces toward the listed limits. Also, a malformed period currently makes ical.js throw and the whole file is refused as not_calendar; after the fix it should only set partial. Re-measure with api/scripts/calendar-memory.ts (add the shape) and correct both recorded figures. (2) api/test/discover-adapters.test.ts:577 'key runs > is linear in the text for the longest key' failed once at 333 ms against a 250 ms limit on a loaded machine; make it robust (compare against a measured baseline ratio or raise the bound with a comment), without removing what it proves. Check the other wall-clock bounds added in tasks 5, 7, 18 and 20 for the same weakness and fix any that are tight.

## Acceptance criteria

- [ ] An RDATE with periods, well-formed or malformed, sets partial and never refuses the file; its pieces cannot exceed the listed limits (test asserts what reaches ICAL.parse)
- [ ] Recorded worst-case figures match a fresh harness run
- [ ] npm test passes five times in a row; npx tsc --noEmit passes

## Relevant files

- api/src/lib/calendar.ts
- api/test/
- api/scripts/calendar-memory.ts
- memory/architecture.md

## What's been tried


## Log

- 2026-11-16T15:16:07Z [li] created (todo)
- 2026-11-16T15:16:07Z [implementer-1] status: todo → in-progress — claimed by implementer-1
