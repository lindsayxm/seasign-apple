---
id: 23
title: iOS: 24-hour event times and every-other blending of AI headlines
status: in-progress
owner: implementer-2
depends_on: []
created: 2026-11-16T15:59:36Z
updated: 2026-11-16T15:59:36Z
---

## Goal

Two decisions from the user on 2026-11-16. (1) Event times on Today honour the phone's 24-hour setting: with 24-hour time on, show 21:00 instead of 9:00PM (and TUE 09:00 for a later day); with it off, keep the current 9:00PM form. Today's time formatting is built by hand in ios/Seasign/Calendar/ (EventLabel); make it follow the system setting (detect it the way Apple documents, for the current locale, and react when the setting changes while the app is open), keeping the zip's time zone. Apply the same rule to any other clock times the app shows (the reading view's published time, History and Saved if they show times). (2) On Today, AI-found headlines are blended every other with headlines from the user's followed sites, so AI results are mixed in rather than grouped or ranked purely by date: take the two streams (site items and AI items), each newest first and each limited to items published since the start of yesterday as now, and alternate them starting with the user's own item; when one stream runs out, continue with the other; then apply the existing rule for how many fit. With AI search off or no AI items, Today is unchanged. History stays strictly newest first. Undated AI items keep their search time as date; within the AI stream order stays newest first. A calendar's events staying on Today when its link temporarily fails is already built and confirmed by the user: add a short test if none covers it, change nothing else.

## Acceptance criteria

- [ ] Unit tests cover 12- and 24-hour formatting for timed, all-day and later-day events in a zone different from the phone's
- [ ] Unit tests cover the every-other order: both streams present, one empty, unequal lengths, AI off
- [ ] Tests pass on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2)

## Relevant files

- ios/Seasign/Calendar/
- ios/Seasign/Feed/
- ios/Seasign/Today/
- ios/Seasign/Reading/
- ios/SeasignTests/

## What's been tried


## Log

- 2026-11-16T15:59:36Z [li] created (todo)
- 2026-11-16T15:59:36Z [implementer-2] status: todo → in-progress — claimed by implementer-2
