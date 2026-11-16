---
id: 18
title: API: bound memory on the calendar path
status: backlog
owner: 
depends_on: [7]
created: 2026-11-16T03:45:09Z
updated: 2026-11-16T03:45:09Z
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
