---
id: 23
title: iOS: 24-hour event times and every-other blending of AI headlines
status: done
owner: implementer-2
depends_on: []
created: 2026-11-16T15:59:36Z
updated: 2026-11-16T16:12:31Z
---

## Goal

Two decisions from the user on 2026-11-16. (1) Event times on Today honour the phone's 24-hour setting: with 24-hour time on, show 21:00 instead of 9:00PM (and TUE 09:00 for a later day); with it off, keep the current 9:00PM form. Today's time formatting is built by hand in ios/Seasign/Calendar/ (EventLabel); make it follow the system setting (detect it the way Apple documents, for the current locale, and react when the setting changes while the app is open), keeping the zip's time zone. Apply the same rule to any other clock times the app shows (the reading view's published time, History and Saved if they show times). (2) On Today, AI-found headlines are blended every other with headlines from the user's followed sites, so AI results are mixed in rather than grouped or ranked purely by date: take the two streams (site items and AI items), each newest first and each limited to items published since the start of yesterday as now, and alternate them starting with the user's own item; when one stream runs out, continue with the other; then apply the existing rule for how many fit. With AI search off or no AI items, Today is unchanged. History stays strictly newest first. Undated AI items keep their search time as date; within the AI stream order stays newest first. A calendar's events staying on Today when its link temporarily fails is already built and confirmed by the user: add a short test if none covers it, change nothing else.

## Acceptance criteria

- [x] Unit tests cover 12- and 24-hour formatting for timed, all-day and later-day events in a zone different from the phone's
- [x] Unit tests cover the every-other order: both streams present, one empty, unequal lengths, AI off
- [x] Tests pass on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2)

## Relevant files

- ios/Seasign/Calendar/
- ios/Seasign/Feed/
- ios/Seasign/Today/
- ios/Seasign/Reading/
- ios/SeasignTests/

## What's been tried

- -AppleICUForce24HourTime YES as a launch argument does not change Locale.hourCycle (argument domain not consulted). defaults write alone plus background/foreground does not either: Foundation keeps the cached current locale until the system notification arrives.

## Log

- 2026-11-16T15:59:36Z [li] created (todo)
- 2026-11-16T15:59:36Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-16T16:09:04Z [implementer-2] 24-hour: new ios/Seasign/Design/ClockStyle.swift. Source is Locale.autoupdatingCurrent.hourCycle (Apple doc: on current/autoupdatingCurrent it gives the user's override; the 24-Hour Time switch is that override, AppleICUForce24HourTime). h11/h12 -> 12-hour, h23/h24 -> 24-hour (00-23, two-digit). followsSystemClockStyle() at the root puts it in \.clockStyle; re-read on NSLocale.currentLocaleDidChangeNotification (CurrentLocaleDidChangeMessage is iOS 26+) and on scene active. EventLabel and ReadingDate take a required ClockStyle; EventsModel.labels(now:clock:limit:).
- 2026-11-16T16:09:04Z [implementer-2] Clock times changed: Today event times (EventLabel.time and VoiceOver text), reading view date (ReadingDate.value). Checked, no clock time: History and Saved rows (ReadingDate.day only), Settings status lines, Today header (date only).
- 2026-11-16T16:09:05Z [implementer-2] Simulator check (iOS 27.2): defaults write -g AppleICUForce24HourTime YES in the simulator + relaunch shows 10:30 / 12:00; with the app running, changing the default and posting AppleTimePreferencesChangedNotification via notifyutil switched the form live both ways. Default deleted again afterwards. Not checked with the real switch on a device.
- 2026-11-16T16:09:05Z [implementer-2] tried: -AppleICUForce24HourTime YES as a launch argument does not change Locale.hourCycle (argument domain not consulted). defaults write alone plus background/foreground does not either: Foundation keeps the cached current locale until the system notification arrives.
- 2026-11-16T16:09:05Z [implementer-2] Blend: HeadlinePicker.everyOther(entries, now:, timeZone:) = sinceYesterday, split by isAI, alternate(sites:ai:) site first, remainder appended. FeedModel.headlines uses it; entries/History untouched. AI hidden -> entries has no AI rows -> identical to sinceYesterday (tested). DEBUG sample already gives S A S A S; no sample change.
- 2026-11-16T16:09:05Z [implementer-2] Part 3 already covered, no change: EventsSnapshotTests.eventsOfAnUnreachableCalendarAreCarriedOver (timeout and fetch_failed carried, ended event dropped, other errors and other zone not carried) and EventsModelTests.aCalendarThatTimesOutKeepsTheEventsReadBefore.
- 2026-11-16T16:09:05Z [implementer-2] Tests: 358 passed on iPhone 16 (iOS 18.3.1) and 358 on iPhone 17 (iOS 27.2), built separately. Screenshot: /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task23/today-every-other-ios27.png (every other, AI marked); 24-hour: /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task23/today-24h-ios27.png
- 2026-11-16T16:10:52Z [implementer-2] Leave-and-return path checked in the iOS 27.2 Simulator: app in background (Settings app in front), default written and AppleTimePreferencesChangedNotification posted, app brought back without relaunch: times read 10:30 / 12:00 (/private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task23/crop-bg-return.png). Simulator default deleted again. Only that screenshot, /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task23/crop-live-24h-on.png, today-24h-ios27.png and today-every-other-ios27.png are kept.
- 2026-11-16T16:10:52Z [implementer-2] status: in-progress → review
- 2026-11-16T16:12:31Z [implementer-2] criterion 1 met: Unit tests cover 12- and 24-hour formatting for timed, all-day and later-day events in a zone different from the phone's
- 2026-11-16T16:12:31Z [implementer-2] criterion 2 met: Unit tests cover the every-other order: both streams present, one empty, unequal lengths, AI off
- 2026-11-16T16:12:31Z [implementer-2] criterion 3 met: Tests pass on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2)
- 2026-11-16T16:12:31Z [implementer-2] review (lead): ran the suite on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2) at a3e7c90: 358 tests passed on each. Viewed today-every-other-ios27.png: headlines alternate site, AI, site, AI, site with AI marks on the AI ones. 24-hour form verified by the implementer in the iOS 27.2 Simulator, including a live switch; not checked on a device or on iOS 18.3. Carry-over of a failing calendar's events is covered by eventsOfAnUnreachableCalendarAreCarriedOver and aCalendarThatTimesOutKeepsTheEventsReadBefore.
- 2026-11-16T16:12:31Z [implementer-2] status: review → done
