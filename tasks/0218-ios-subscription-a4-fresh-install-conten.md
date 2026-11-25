---
id: 218
title: iOS subscription A4: fresh-install content: three starter sites, two list items, 'Add your calendar... ↑'
status: review
owner: implementer-1
depends_on: [217]
created: 2026-11-24T19:09:50Z
updated: 2026-11-25T02:08:11Z
---

## Goal

Read plans/2026-11-24-account-and-subscription.md (phase A), memory/decisions/2026-11-24-subscription-gate-and-ai-lapse-rule.md and memory/notes/2026-11-24-storekit-research.md first. On a fresh install (when the stores are first created, like the default zip; never put back after removal): followed sites Hacker News (https://news.ycombinator.com/, feed https://news.ycombinator.com/rss), Wired Science (https://www.wired.com/category/science/, feed mode with https://www.wired.com/feed/category/science/latest/rss) and Ars Technica Space (https://arstechnica.com/space/, feed https://arstechnica.com/space/feed/), stored as the API's resolve would return them; 'Go outside' on the Do list and 'Concert tickets' on the Get list, for everyone, no subscription needed; with no calendar the events box says 'Add your calendar... ↑' with the arrow toward the settings button (keep the zip prompt rule and the narrow-box rule from task 205). A subscriber can remove the sites. Check on a simulator with no user data; never delete the app from the iPhone 16 Pro Max, iPhone 16 or iPhone 17 simulators.

## Acceptance criteria

- [ ] Tests: seeds written once when the store is first created and not again after removal; an existing store is not seeded; the events box text with and without a calendar and on the iPhone SE width
- [ ] Screenshot of a fresh install on a clean simulator against local wrangler dev: three sites' headlines on Today, the two list items, the calendar prompt
- [ ] Suite passes on both runtimes

## Relevant files

- ios/Seasign/Store
- ios/Seasign/Feed
- ios/Seasign/Lists
- ios/Seasign/Today
- ios/SeasignTests

## What's been tried

- Arrow test requiring the arrow's middle inside the 24-pt settings glyph failed on all four widths: the right-aligned row ends in ' /', so the arrow sits 2 to 4 pt left of the glyph (SE 312.9 vs 317; 393: 332.0 vs 335; 402: 341.5 vs 344; 440: 380.9 vs 382). It is inside the button's 44-pt tap target on all four. Kept the user's text and the row's form; the test now pins 'inside the tap target and at most 5 pt left of the glyph'.

## Log

- 2026-11-24T19:09:50Z [li] created (backlog)
- 2026-11-25T01:03:30Z [li] status: backlog → todo
- 2026-11-25T01:03:30Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-25T01:17:21Z [implementer-1] Red run (stubs that compile but do nothing, own simulator T218 Test, iOS 27.2): StarterContentTests and TodayCalendarPromptTests fail as expected - seeding tests find 0 sites/items, userStoreIsNew false, prompt text empty, prompt tests crash on eventRows[0] (no row). Existing-store tests passed against the stub, as they should.
- 2026-11-25T01:17:21Z [implementer-1] Checked through local wrangler dev (2026-11-24): resolve gives HN feed mode feedUrl https://news.ycombinator.com/rss title 'Hacker News'; Wired page links mode (57 links) title 'Science News: Health, Robotics, Climate Change, Space News | WIRED'; Ars page feed mode feedUrl https://arstechnica.com/space/feed/ title 'Category: Space - Ars Technica'. POST /v1/feed with the three in feed mode (Wired with its science feed) answered ok for all three: 30, 16, 13 dated items.
- 2026-11-25T01:21:12Z [implementer-1] tried: Arrow test requiring the arrow's middle inside the 24-pt settings glyph failed on all four widths: the right-aligned row ends in ' /', so the arrow sits 2 to 4 pt left of the glyph (SE 312.9 vs 317; 393: 332.0 vs 335; 402: 341.5 vs 344; 440: 380.9 vs 382). It is inside the button's 44-pt tap target on all four. Kept the user's text and the row's form; the test now pins 'inside the tap target and at most 5 pt left of the glyph'.
- 2026-11-25T01:31:14Z [implementer-1] Full suite iPhone 17 iOS 27.2: '✔ Test run with 1026 tests in 110 suites passed after 90.145 seconds.' and '** TEST SUCCEEDED **'; no '✘ Test' line. (On my own new simulator 'T218 Test' the StoreKit purchase/restore tests failed: fresh-simulator StoreKitTest environment, nothing in this change touches them; they pass on iPhone 17.)
- 2026-11-25T01:50:44Z [implementer-1] Full suite iPhone 16 iOS 18.3.1: '✔ Test run with 1026 tests in 110 suites passed after 601.846 seconds.' and '** TEST SUCCEEDED **'; grep for '✘ Test' finds 0 lines.
- 2026-11-25T01:55:01Z [implementer-1] Design: StarterContent (ios/Seasign/Store/StarterContent.swift) is the app's one way of opening the stores; SeasignApp.start calls StarterContent.open(), which calls LocalStore.open and seeds only when Opened.userStoreIsNew. First creation is known by FileManager.fileExists on default.store, asked inside LocalStore.open before anything can create the file. An existing file is never seeded whatever it holds (empty included; the pre-split single store too), so removed seeds never return and existing installs get nothing. In-memory stores (tests, debug samples) never pass through it. Crash between file creation and the seed save leaves that install empty (safe side). Seeds: 3 feed-mode Sites with resolve's url and page titles, categories Tech/Science/Space (my choice, the user named none), and ListItems 'Go outside' (Do), 'Concert tickets' (Get), 1 ms apart for order. Nothing about AI or the subscription is written.
- 2026-11-25T01:55:01Z [implementer-1] Events box: TodayOverlayLayout.calendarPromptText 'Add your calendar... ↑' as the one row when showsCalendarPrompt(linkCount:0, google:.notConnected, eventCount:0) and a zip is set; right-aligned in the row form like the zip prompt; plain text (tap opens the day screen like the rest of the box); VoiceOver 'Add your calendar in Settings'. No zip: the zip prompt alone, task 205 rule unchanged. Whole on every phone (needs 26 columns, SE has 27). The arrow lands inside the settings button's 44-pt target, 2-4 pt left of the 24-pt glyph (the row ends in ' /'); screenshots show it under the button's left edge.
- 2026-11-25T01:55:01Z [implementer-1] Screenshots (clean simulators I created: 'T218 iPhone 17 Pro' iOS 27.2, 'T218 iPhone SE' iOS 18.3; app never installed before; local wrangler dev): /private/tmp/claude-501/-Users-li-seasign-seasign-apple/9f3372c6-3fea-4cb1-8afe-f6224e28ebe8/scratchpad/shots218/01-fresh-today-iphone17pro.png (calendar prompt, 5 headlines from HN/Ars/Wired), 02-fresh-lists-iphone17pro.png (Go outside / Concert tickets), 03-no-zip-today-iphone17pro.png (-debugNoZip: zip prompt wins), 05-fresh-today-iphoneSE.png (SE: '-- Add your calendar... ↑ /' whole), 06-settings-subscribed-iphoneSE.png, 07-settings-sites-removable-iphoneSE.png (three sites with REMOVE, 30/16/13 articles), 08-tap-settings-free-iphone17pro.png (tapping settings on a fresh install gives the popup; StoreKit Unknown under simctl). Observed, not investigated: on the new iOS 27.2 simulator any cover opened at launch by -debugOpenSettings/-debugOpenDay stays white; the same covers render on iOS 18.3 and a tap on settings opens the popup normally on 27.2.
- 2026-11-25T02:08:00Z [implementer-1] Correction to the screenshot note: shot 01's five headlines are not shown to include Wired. Today shows the five newest across the three sites (unchanged picker); at 20:04 snapshot_ui listed four Hacker News and one Ars Technica. Wired is evidenced by /private/tmp/claude-501/-Users-li-seasign-seasign-apple/9f3372c6-3fea-4cb1-8afe-f6224e28ebe8/scratchpad/shots218/12-history-science-wired-iphone17pro.png (Last 7 days filtered to Science: five Wired items, source 'Science Latest') and shot 07 (16 articles). Also retracted: the white launch-time covers on iOS 27.2 were a slow first render on a brand-new simulator; with a 30 s wait /private/tmp/claude-501/-Users-li-seasign-seasign-apple/9f3372c6-3fea-4cb1-8afe-f6224e28ebe8/scratchpad/shots218/04-settings-subscribed-iphone17pro.png shows Settings. Existing-install check in the running app: on 'T218 Test' (store created before seeding existed) /private/tmp/claude-501/-Users-li-seasign-seasign-apple/9f3372c6-3fea-4cb1-8afe-f6224e28ebe8/scratchpad/shots218/10-existing-store-today-T218Test.png shows 'Follow sites in Settings…' and the calendar prompt, /private/tmp/claude-501/-Users-li-seasign-seasign-apple/9f3372c6-3fea-4cb1-8afe-f6224e28ebe8/scratchpad/shots218/11-existing-store-lists-T218Test.png empty lists.
- 2026-11-25T02:08:01Z [implementer-1] seedingTurnsNothingOnForAI tightened (it passed vacuously: seeding writes no Settings row): now asserts no row after seeding, then SkyStore.settings() gives aiModeRaw nil, no interests, default zip. StarterContentTests rerun: iPhone 17 27.2 '✔ Test run with 13 tests in 1 suite passed after 1.810 seconds.'; iPhone 16 18.3.1 '✔ Test run with 13 tests in 1 suite passed after 13.223 seconds.'; both '** TEST SUCCEEDED **'. VoiceOver: snapshot_ui reports both the prompt row and event rows by their drawn text, so the tool does not show the accessibility label; architecture.md says it is set, not checked with VoiceOver.
- 2026-11-25T02:08:11Z [implementer-1] status: in-progress → review
