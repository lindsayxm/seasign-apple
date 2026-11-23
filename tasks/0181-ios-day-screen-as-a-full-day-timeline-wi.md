---
id: 181
title: iOS: day screen as a full-day timeline with event boxes
status: todo
owner: 
depends_on: []
created: 2026-11-23T02:04:39Z
updated: 2026-11-23T02:04:39Z
---

## Goal

The user asked on 2026-11-22: on the full-screen day view show how long each event lasts, as Google Calendar does: the top of an event's box is its start time, the bottom its end, and the whole day fits the length of the screen (no scrolling). Replaces the list in ios/Seasign/Calendar/DayView.swift; DayModel's data is unchanged. Lead's choices where the user did not say: midnight to midnight in the events' time zone, hours scaled to the space left under the header; hour lines with time labels on the left in the app's clock style (12/24 h); all-day events in a strip above the grid; overlapping events side by side in columns; an event without a length or shorter than its title line gets a minimum height so the title reads; an event running past midnight is cut at the edge; a 'now' line for the current time; ended events dimmed as today; title in the box, the time too when the box is tall enough; the mic and + buttons, notices, listening text and the Added note keep working and do not cover the grid's events more than they must; the app's own palette and type (TodayType, Palette), not Google's colours.

## Acceptance criteria

- [ ] Layout is a pure function (events, day bounds, height, width -> boxes with frames and columns) with tests: start and end map to y, overlaps get columns, minimum height, cut at midnight, a 23- and 25-hour day (clock change), an all-day event goes to the strip, no length
- [ ] VoiceOver: each box reads title, start, end and length; order by start; the grid does not hide events from VoiceOver
- [ ] Screenshots on the iPhone 17 with the Google sample (-debugGoogle YES -debugOpenDay): a normal day, overlapping events, many all-day events, a very short event, an empty day; and one on the smallest supported screen (iPhone SE 3rd generation, iOS 18.3) to show the day still fits and reads
- [ ] Suite passes on both runtimes (one xcodebuild at a time); never touch the iPhone 16 Pro Max

## Relevant files

- ios/Seasign/Calendar/DayView.swift
- ios/Seasign/Calendar
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-23T02:04:39Z [li] created (todo)
