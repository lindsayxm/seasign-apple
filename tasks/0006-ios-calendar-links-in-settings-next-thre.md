---
id: 6
title: iOS: calendar links in Settings, next three events on Today
status: in-progress
owner: implementer-2
depends_on: [4, 5]
created: 2026-11-15T22:33:55Z
updated: 2026-11-16T02:22:05Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. Settings gets a Calendars section: paste a link, name it, remove it (SwiftData CalendarLink), with short instructions for where to find the link in Google, Apple and Outlook. Today shows the next three events from /v1/calendar/events to the right of the date, as in ref-img/00-button-meanings.png (time, then title in caps). Cache the last result locally so Today shows events before the network answers.

## Acceptance criteria

- [ ] Adding a link in Settings shows its next three events on Today; removing it clears them
- [ ] No calendar permission prompt appears; Info.plist has no calendar usage string
- [ ] A failing link shows a message in Settings, not an empty Today
- [ ] Simulator screenshot of Today with events recorded in the task log; tests pass on both simulators

## Relevant files

- ios/Seasign/Settings/
- ios/Seasign/Today/
- ios/Seasign/Calendar/

## What's been tried


## Log

- 2026-11-15T22:33:55Z [li] created (todo)
- 2026-11-16T02:22:05Z [implementer-2] status: todo → in-progress — claimed by implementer-2
