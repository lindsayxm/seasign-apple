---
id: 27
title: design-ideas/v1: screenshots of the current app in each scene state
status: done
owner: lead
depends_on: []
created: 2026-11-17T00:23:10Z
updated: 2026-11-17T00:24:34Z
---

## Goal

The user asked for design-ideas/v1/ holding a screenshot of Today as the app looks now in twelve states: sunrise, mid-day, sunset, clouds, rain, snow, moonrise, midnight, waxing, waning, full, moonset. Use the DEBUG launch arguments. Use the sample events and feed (-debugEvents, -debugFeed) so the user's real calendar is not committed.

## Acceptance criteria

- [x] Twelve named screenshots in design-ideas/v1/, each looked at by the lead

## Relevant files

- design-ideas/v1/

## What's been tried


## Log

- 2026-11-17T00:23:10Z [lead] created (todo)
- 2026-11-17T00:23:10Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-17T00:24:34Z [lead] Twelve screenshots taken on iPhone 17 (iOS 27.2) with -debugEvents YES -debugFeed YES (sample events and headlines, not the user's calendar) plus: 01 sunrise+6 clear; 02 midday clear; 03 sunset-6 clear; 04 midday cloudy; 05 midday rain; 06 midday snow; 07 moonrise+8 moon 0.5; 08 night moon 0.5; 09 night moon 0.25; 10 night moon 0.75; 11 night moon 0.5; 12 moonset-8 moon 0.5. Lead looked at all twelve: each shows the named state. 08 and 11 are the same picture (full moon at the top of its arc). Night shots show one event because the debug clock is past the two timed sample events.
- 2026-11-17T00:24:34Z [lead] status: in-progress → review
- 2026-11-17T00:24:34Z [lead] criterion 1 met: Twelve named screenshots in design-ideas/v1/, each looked at by the lead
- 2026-11-17T00:24:34Z [lead] status: review → done
