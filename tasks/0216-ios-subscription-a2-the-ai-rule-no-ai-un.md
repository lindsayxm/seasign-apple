---
id: 216
title: iOS subscription A2: the AI rule: no AI unless Subscribed
status: backlog
owner: 
depends_on: [215]
created: 2026-11-24T19:09:50Z
updated: 2026-11-24T21:13:49Z
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
