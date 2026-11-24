---
id: 216
title: iOS subscription A2: the AI rule: no AI unless Subscribed
status: review
owner: implementer-1
depends_on: [215]
created: 2026-11-24T19:09:50Z
updated: 2026-11-24T21:54:49Z
---

## Goal

Read plans/2026-11-24-account-and-subscription.md (phase A), memory/decisions/2026-11-24-subscription-gate-and-ai-lapse-rule.md and memory/notes/2026-11-24-storekit-research.md first. HARD RULE: no AI features on a lapsed subscription, ever. One pure function answers whether AI may run from the subscription state (and signed-in, which does not block yet: phase C turns that on); it says no for free, lapsed and unknown. Every AI path goes through it: SearchGate (automatic and manual search), the Use My List / Let AI Search toggle and its precondition message, FeedModel's display of AI-found items already cached (Today, History; Saved follows the user's answer in the decision file), and the launch-time check that moves the mode back to Use My List. On a change to not-Subscribed the mode is set to Use My List. Do not change the AI key section in Settings otherwise (on hold by the user). Until task A3 lands, production still treats everyone as Subscribed through one named default so nothing visible changes; a test pins that the default is in exactly one place.

## Acceptance criteria

- [ ] Tests: for each of free, lapsed, unknown no search is sent (automatic or manual), the toggle cannot move to AI, cached AI-found items are not shown on Today or History, and a lapse sets the mode to Use My List; subscribed behaves as today
- [ ] A reviewer has traced every call site that sends POST /v1/discover or shows an AI-found item and confirmed it goes through the rule
- [ ] Suite passes on both runtimes

## Relevant files

- ios/Seasign/AISearch
- ios/Seasign/Feed
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-24T19:09:50Z [li] created (backlog)
- 2026-11-24T19:10:14Z [li] User, 2026-11-24: AI-found articles the person saved stay visible in Saved on a lapsed subscription (already fetched, no cost). AI-found items in the feed (Today, History) are hidden when not Subscribed.
- 2026-11-24T19:12:45Z [li] User, 2026-11-24: the point of the rule is that no additional charges are incurred after a lapse; whether already-fetched AI headlines stay visible does not matter, do what is easier. Lead: keep the existing behaviour (FeedModel.showsAI follows AISearchModel.isActive, so they are hidden when AI search is not active); no extra hiding code. The essential tests are that no POST /v1/discover is sent unless Subscribed.
- 2026-11-24T20:46:52Z [li] From task 215 (lead): (1) allowsPaidFeatures is Subscribed alone; signed-in does not block AI until phase C adds the server check. (2) Re-read the subscription state before any request that costs money (a manual or automatic search): the test environment's expiry sent no update to a running app, so a running app may go on believing it is subscribed; make overlapping refreshes safe (the answer used must be from a read started after the request was asked for). (3) Until the product exists in App Store Connect the StoreKit read fails and the state is Unknown on every phone, so after this task AI is off everywhere except under -debugSubscription subscribed: the tests and DEBUG sample paths that need AI must inject Subscribed, and the lead tells the user before a gated build goes on a simulator they use.
- 2026-11-24T21:13:49Z [li] From the #215 re-review: the state is only re-judged on refresh(), so a Subscribed state outlives its expiry until the next read: the gate must await refresh() and use that answer before each paid request. Small test fixes to make in this task: in StoreKitSubscriptionTests.aStaleSubscribedAnswerPastItsExpiryIsLapsed assert the model still says subscribed before the clock moves (drop the print); in the natural-expiry test assert what StoreKit reported.
- 2026-11-24T21:15:39Z [li] status: backlog → todo
- 2026-11-24T21:15:39Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-24T21:22:08Z [implementer-1] Design: pure rule AIRule.mayRun(SubscriptionAccess) next to SearchGate (true only for Subscribed; signed-in ignored until phase C). SearchGate gets a required subscription field checked before the mode (.notSubscribed); AIPrecondition gets subscription cases checked first, so setMode/isActive/showsAI/Settings note/canSearchNow follow it. AISearchModel takes a required SubscriptionSource (protocol; SubscriptionModel conforms); run() awaits subscription.refresh() first and uses that answer, then gate+charge+isSearching in one synchronous main-actor turn. SubscriptionModel calls registered handlers on every landed read; AISearchModel moves the mode to Use My List on any landed non-Subscribed answer. The unread placeholder (.unknown before the first read lands) sends nothing and hides AI but does not move the stored mode, so a subscriber is not flipped at every launch once 217 wires the real model; a landed Unknown (failed read) does move it.
- 2026-11-24T21:34:05Z [implementer-1] Fail-first, by mutation on iPhone 16 / iOS 18.3 (logs kept in the session scratchpad): (1) AIRule.mayRun returning true: 12 of 15 new tests failed (only subscribed-path, overlap and default tests passed, as expected). (2+4) run() using the last state instead of awaiting refresh, and the launch check applying the unread placeholder: the caught-before-send, read-in-flight, overlap, reads-counted and launch tests failed. (3) the lapse handler not moving the mode: 8 tests failed. Item 6: the stale-answer assertion flipped to .free failed showing .subscribed on 18.3; the natural-expiry assertion flipped to [] failed showing [1] (subscribed) on 18.3 at the lapse moment and [2] (expired) on 27.2. Experiment on 18.3: StoreKit reports expired within a second after the clock check reads Lapsed, so the test now waits up to 10 s for [.expired].
- 2026-11-24T21:34:05Z [implementer-1] Swift Testing prints parameterized results with a leading zero-width space (U+200B), so a grep anchored on '^✘ Test ' misses failing parameterized tests; grep '✘ Test' unanchored.
- 2026-11-24T21:43:11Z [implementer-1] Done in faaf580. Full suite: iOS 18.3 (iPhone 16) 'Test run with 955 tests in 105 suites passed', ** TEST SUCCEEDED **; iOS 27.2 (iPhone 17) same 955/105, ** TEST SUCCEEDED **. Release simulator build succeeds; no debug flag strings in the Release binary. Screenshot (iPhone 17, -debugSubscription lapsed -debugAI YES plus -debugSaved/-debugEvents/-debugLists/-debugNoZip/-debugGoogle, sample data only): toggle stays on USE MY LIST after tapping Let AI Search, note 'AI search is off because your subscription has ended.'; Today showed only site sample headlines. The iPhone 17 simulator now has this build installed (behaves as before for a normal launch: pre-gate default is Subscribed).
- 2026-11-24T21:43:11Z [implementer-1] status: in-progress → review
- 2026-11-24T21:49:04Z [implementer-1] Mutant 5 (gate decided before the awaited refresh, only the rule checked after): searchesWhoseReadsOverlapSendOnce failed on stub.count == 1 and usedToday == 1 (3 requests). Its wait changed to waitingCount >= 1 so a double send fails on the count (commit after faaf580). Reverted; AISubscriptionRuleTests 15/15 passed on 18.3 and 27.2. Checked -debugAI YES alone (sample flags) on iPhone 17: Today shows the AI-found sample headlines, so the not-yet-answered fixed-store model lands Subscribed as expected.
- 2026-11-24T21:54:49Z [implementer-1] Lead: suite at a1ffe30: 955 tests in 105 suites passed, TEST SUCCEEDED, on iPhone 17 / iOS 27.2 and iPhone 16 / iOS 18.3.1 (log read with an unanchored '✘ Test' grep: no failures).
