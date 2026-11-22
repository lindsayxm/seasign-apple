---
id: 170
title: iOS: day calendar screen opened by tapping the events area on Today
status: todo
owner: 
depends_on: [169]
created: 2026-11-22T17:50:02Z
updated: 2026-11-22T18:45:19Z
---

## Goal

Plan plans/2026-11-22-day-calendar-and-voice.md, task 5. Full-screen list of all of today's events from Google and pasted links, ended ones included, with a mic button top right and a + button below it (wired in later tasks).

## Acceptance criteria

- [ ] The events box on Today is a button (whole box, 44 pt minimum, VoiceOver label); tappable also when there are no events; the pull gesture and the zip prompt still work; it opens Destination.day as a fullScreenCover like History
- [ ] DayModel: its own snapshot of today's events from both sources through the day parameter, merged and ordered by start (all-day first), in the events zone (EventZone.resolve); refreshes on open, on return to the foreground and on its own timer while open (Google 5 s like Today's poll rules, pasted links 5 minutes); per-source failures keep what is shown; Today's next-three logic and models untouched
- [ ] DayView in the app's style (SheetScaffold or the History header, CloseMark, EventLabel times, ended events dimmed, an empty state); mic and + buttons top right with 44 pt targets, in the icon style of the other screens; until tasks 171 and 172 they open a short 'coming soon' note or are hidden behind a flag, the implementer says which
- [ ] Tests for DayModel (merge order, ended events kept, zone, failure handling, refresh gating) and that Today's labels are unchanged. Suite passes on both runtimes; screenshots on the iPhone 17 with -debugGoogle of Today and the day screen

## Relevant files

- ios/Seasign/Calendar
- ios/Seasign/Today/TodayView.swift
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-22T17:50:02Z [li] created (todo)
- 2026-11-22T18:06:18Z [li] Lead: from #167: day must be today or one of the next six days in the request zone, else the fixed 400; a request for today sent just before local midnight can arrive after it and get the 400: on that 400, or when the local date changes while the screen is open, recompute the date and ask again. Google's day query can miss a zero-length event exactly at local midnight (timeMin is exclusive); accepted.
- 2026-11-22T18:45:19Z [li] Lead: from the #167 review: until the API follow-up lands an event can arrive with end before start (floating time in a skipped clock hour). Never build a ClosedRange or Range from an event's start and end without ordering them first; treat end < start as a zero-length event. Test it.
