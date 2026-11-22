---
id: 170
title: iOS: day calendar screen opened by tapping the events area on Today
status: review
owner: implementer-2
depends_on: [169]
created: 2026-11-22T17:50:02Z
updated: 2026-11-22T19:22:24Z
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
- 2026-11-22T18:54:51Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-22T19:17:44Z [implementer-2] Implemented in e8a8148. New ios/Seasign/Calendar/DayModel.swift (DaySourceSnapshot per source keyed by day+zone, DaySchedule mapping that keeps ended events and clamps end<start to zero length, DayOrder all-day first then start, DayRefresh.isDue pure gating, DayModel) and DayView.swift. API layer: calendarEvents/googleEvents take day: String? = nil as the last argument, left out of the body when nil (tests check Today's requests still send no day). GoogleCalendarModel.dayEvents(day:timezone:) reuses withToken/handle, honours retryNotBefore, never touches snapshot/lastFetch/isRefreshing/cache; a 400 returns .refused without handle so the midnight case does not back off Today's poll. EventsModel/GoogleCalendarModel gain read-only isSample so debug sample links are never sent. No new SwiftData model: the day snapshot lives in memory only.
- 2026-11-22T19:17:44Z [implementer-2] Choices: (1) Google polled at a flat 5 s while the day screen is open (GooglePoll.interval, minimumGap 4 s), not the 60 s push rate, because a push only refreshes Today's snapshot; links every 5 min, retried after 30 s on failure; both forced on open and on return to the foreground (.task(id: scenePhase == .active)), still held back by 429 holds. (2) Midnight 400: recompute the day; if it changed ask again once at once, otherwise a failure plus a 60 s hold for that source. Day turnover while open: parts for yesterday are hidden at once and the next 5 s turn asks for the new day. (3) Mic and + are hidden unless -debugDayButtons YES (they then call no-op closures); DayView shows each only when its closure is set, so 171/172 just pass closures. (4) Icons: two new hand-drawn LineIcon cases .mic and .plus (no SF Symbols). (5) Layout: date header (e.g. SUNDAY, NOVEMBER 22) with CloseMark top right; mic above + in a 44 pt column right under the close mark, list beside it with trailing space reserved; rows use EventLabel lead/tail columns in system mono, titles in caps Jost like History, ended rows at 40% opacity and spoken with ', ended'; status line and empty states in dim caps. (6) The events box is a Button with TapOnlyButtonStyle (PrimitiveButtonStyle firing from onTapGesture) laid under the rows (rows allowsHitTesting(false), VoiceOver still reads them) and under the zip prompt; target = TodayOverlayLayout.eventsTarget (box down to hairline, also when no box, >= 44 pt). Debug: -debugOpenDay YES opens the screen; -debugGoogle YES feeds sample events for today built from the real time (all-day, one ended, two to come, the Family calendar's sample problem shows the status line).
- 2026-11-22T19:17:44Z [implementer-2] Verified. iPhone 16 / iOS 18.3.1 full suite: '✔ Test run with 625 tests in 80 suites passed after 16.204 seconds.' and '** TEST SUCCEEDED **'. iPhone 17 / iOS 27.2 full suite: '✔ Test run with 625 tests in 80 suites passed after 18.734 seconds.' and '** TEST SUCCEEDED **'. New tests: DayScheduleTests (order, end<start, ended kept, carry-over only same day+zone, gating table), DayModelTests (merge/zone/labels, zone change, Today's snapshots/cache/labels/requests untouched, failures keep events + status line, gating incl. date turnover, Google 429 hold, midnight refusal retry, same-day refusal holds without backing off Today, no calendars, run loop stops on cancel), TodayOverlayLayoutTests.theDayTargetIsTheBoxOrItsPlace. iPhone 17 with -debugGoogle YES (axe coordinate gestures): a 101 pt pull starting and ending inside the box showed the calendar spinner and did not open the day screen; a press on the empty lower part of the box and one on an event row each opened it; Close returns to Today. Note: axe 'tap' (instant) does nothing in this app; held touches (--down --up --delay 0.15) work. Not verified: the zip prompt tap in the Simulator (the iPhone 17 has a zip saved and I did not remove it; the prompt sits above the day button in the ZStack, unchanged), gestures on iOS 18.3 (no UI driving there by rule), live Google/links polling against real accounts.
- 2026-11-22T19:22:24Z [implementer-2] More checks on the iPhone 17 (-debugGoogle YES): with -debugEventTitles none (no rows, no box, zip set) a held touch at (250,110) where the box would be opened the day screen. axe describe-ui on Today shows Button "Today's calendar" (287x106 pt) plus the row elements 'Coffee with Sam, 2:00 PM' and 'Swim practice, 4:00 PM', so the rows keep their VoiceOver labels. 39c918a corrects two comments only (dayEvents does clear/set the Google model's holds, failures and status as a poll would; TapOnlyButtonStyle no longer claims VoiceOver activation, which I did not test). Not verified: the zip prompt tap (the iPhone 17 has a zip and the local API at 127.0.0.1:8787 refuses connections, so a removed zip could not be saved back), the loop stopping/restarting with scenePhase in the running app (only model cancellation is tested), VoiceOver double-tap on the box, gestures on iOS 18.3, live Google and link polling. Screenshots: scratchpad 170-today.png, 170-today-no-events.png, 170-day-without-buttons.png, 170-day-with-buttons.jpg, 170-pull-in-box.png. Follow-ups for the lead: Today's UpcomingEvent.hasEnded still treats end<start as ended at the raw end (day screen clamps); an event begun the night before shows a bare '10:00PM' on the day screen; an event in both a pasted link and Google shows twice (as on Today).
- 2026-11-22T19:22:24Z [implementer-2] status: in-progress → review
