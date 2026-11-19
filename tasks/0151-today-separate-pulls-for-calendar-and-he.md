---
id: 151
title: Today: separate pulls for calendar and headlines, each with its own spinner
status: review
owner: implementer-1
depends_on: []
created: 2026-11-19T16:59:34Z
updated: 2026-11-19T17:32:00Z
---

## Goal

User, 2026-11-19: keep calendar and headline refresh separate. Pulling down on the calendar area refreshes events and the sky (temperature, conditions), not headlines; pulling down on the sea/headline area refreshes headlines only. Temperature and conditions refresh silently in the background every 10 minutes.

## Acceptance criteria

- [ ] A pull that starts above the horizon (header, events box, sky) runs events.refresh(force: true) and the sky refresh, and sends no feed request. A pull that starts at or below the horizon (the sea and the article titles) runs the feed refresh only, and sends no calendar or sky request. Neither ever calls anything on the AI model. Rule kept as a pure, tested function
- [ ] The sky pull really fetches: add a forced sky refresh if the sky model has a freshness rule that would otherwise skip it; it must still honour any rate-limit delay
- [ ] Calendar spinner: at the upper right corner of the events box (inside its padding), shown only while that pull runs. Headline spinner: at the upper right of the headline area, level with the first title row, with the same x centre as the calendar spinner. The old spinner by the wind line is gone. Nothing else moves; both are hidden at rest
- [ ] The sky (temperature, conditions) refreshes in the background every 10 minutes while the app is open, with no spinner or other visible sign; confirm the interval in code and by a test or the server log. The minute-by-minute events refresh and the refresh on return to the foreground stay as they are
- [ ] Verified on the iPhone 16 Pro Max simulator against the wrangler dev already on port 8787: a calendar-area pull adds a calendar POST and a sky GET and no feed POST; a headline-area pull adds a feed POST only. Screenshots of each spinner. Taps on titles, the three buttons and the all-publications mark still work
- [ ] Suite passes on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2

## Relevant files

- ios/Seasign/Today
- ios/Seasign/Feed
- ios/Seasign/Calendar
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-19T16:59:34Z [lead] created (todo)
- 2026-11-19T16:59:34Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-19T17:01:52Z [implementer-1] Lead additions (2026-11-19, treated as criteria): (1) the headline pull calls feed.refresh(force: true) so the 15-min gate does not skip it, but unlike Settings' forced refresh it must send nothing during a 429 delay; fix that for the pull path only, with a test; no AI. (2) the sky pull calls model.refresh(force: true), honouring any 429 delay. Lead is changing api/src/routes/sky.ts cache time separately; api/ not touched here.
- 2026-11-19T17:15:31Z [implementer-1] Rule: TodayPull.target(start:translation:horizonY:) (pure, tested): nil unless isPull (>=100 pt down, >= 2x sideways); start.y < SceneLayout.horizonY -> .calendar, else (at or below) .headlines. Calendar pull: events.refresh(force: true) and model.refresh(force: true) concurrently (TodayModel.refresh(force:) already existed and checks retryNotBefore after the freshness gate; new tests aForcedRefreshFetchesAFreshSky and RateLimit aForcedSkyRefreshWaitsOutTheDelay). Headline pull: feed.refresh(force: true, waitsOutDelay: true); new FeedModel parameter, default false, so Settings' 'Refresh headlines now' (force only) is unchanged and still sent during a delay; test theHeadlinePullWaitsOutTheDelay. No AI call on either path (refreshIfDue is only called from TodayView's launch task and scenePhase handler). Two @State flags (isPullingCalendar, isPullingHeadlines), each guarding only its own pull. Spinners: small ProgressView in a 20 pt frame, hit-testing off, centres from TodayOverlayLayout.calendarSpinnerCenter (x = (377-8)*s - 10, y = first event line's middle) and headlineSpinnerCenter (same x, first title line's middle); wind-line spinner removed. VoiceOver: 'Refresh calendar and weather' on the header; 'Refresh headlines' on each headline row, the follow-sites prompt and the 'Last 7 days' button (so it exists when the sea is empty). DEBUG: -debugPullSpinner <s> holds spinners up for screenshots. Sky every 10 min: no new timer; the minute loop plus TodayModel.refreshInterval (600 s) does it; tests theSkyIsFreshForTenMinutes and anOpenAppAsksForTheSkyEveryTenMinutes (60 one-minute ticks -> fetches at minutes 10,20,...,60). memory/architecture.md: pulls bullet added, stale '10 minutes' for events corrected to one minute.
- 2026-11-19T17:31:55Z [implementer-1] GAP for criterion 5: the iPhone 16 Pro Max follows no sites ('Follow sites in Settings...' on Today), so FeedModel.refresh returns before sending and NO feed POST can appear for a headline pull (nor be shown absent for a calendar pull). The feed path is covered by code and the unit test only. Not changed: no site added (settings left as they are). To close it, the lead/user would follow a site on the Pro Max (or allow me to) and repeat a headline pull.
- 2026-11-19T17:31:56Z [implementer-1] Evidence, Pro Max (iOS 18.3) against the running wrangler dev, request lines timestamped by a tail (/private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/requests151.log). Calendar pull from the header (y 128, horizon at ~432 pt): 11:10:30 POST calendar/events + GET sky; again 11:10:48 POST + GET; 11:31:22 GET sky + POST (launch 6 s earlier had skipped both as fresh; the minute loop's events tick before it was at 11:31:04). Headline pull from the follow-sites prompt (y 566) at 11:11:23: no request at all between 11:10:48 and 11:14:12 (next events tick, which the pull at 11:10:48 had pushed back); at 11:31:24: nothing after 11:31:22. Headline pull from sample title row 02 (-debugFeed, frozen) at 11:12:20: nothing. No AI route in any window. Sky in the background: after the 11:10:48 pull, plain launch 11:14:55 and nothing touched: GET /v1/sky at 11:20:59 and 11:31:03 (10 min 11 s and 10 min 4 s; in practice 10-11 min, the first minute tick at or after 600 s), calendar POST every minute 11:15:57-11:31:04. Note: xcodebuild test runs on the iPhone 16/17 sims hit the same server from their test hosts (pairs at 11:04-11:09 and 11:14:12-20); those windows are excluded.
- 2026-11-19T17:31:56Z [implementer-1] Screenshots (simctl, full res; -debugPullSpinner 20 to hold them): calendar spinner /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/spinner-calendar.png (crop /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/spinner-calendar-top.png); headline spinner /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/spinner-headlines.png (crop /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/spinner-headlines-crop.png) and with sample titles /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/spinner-headlines-titles-crop.png; both running at once (two flags, same x) /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/spinners-both-small.png; at rest after a plain launch, no spinner, nothing moved /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/at-rest-small.png. Taps after the change: Do/Get, Saved, Last 7 days open and close; a title tap (row 03, -debugFeed) opens the reading view; drags from the follow-sites prompt and title row 02 did not open them. Known: the spinner renders system gray (the tint is not applied); the headline spinner touches the end of a long first title (sample row 01) and the calendar one sits where a full-width first event title ends. Not run: VoiceOver actions, the Settings tap (not opened by instruction), pulls on iOS 27.2, a pull started right next to the horizon (boundary is unit-tested). Tests: 449 tests in 64 suites passed on iPhone 16 / iOS 18.3.1 and on iPhone 17 / iOS 27.2. Pro Max left running the new build from a plain launch.
- 2026-11-19T17:32:00Z [implementer-1] status: in-progress → review
