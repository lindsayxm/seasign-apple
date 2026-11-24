---
id: 215
title: iOS subscription A1: subscription state on the phone (Free, Subscribed, Lapsed, Unknown) with StoreKit, tested locally
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-24T19:09:50Z
updated: 2026-11-24T19:57:05Z
---

## Goal

Read plans/2026-11-24-account-and-subscription.md (phase A), memory/decisions/2026-11-24-subscription-gate-and-ai-lapse-rule.md and memory/notes/2026-11-24-storekit-research.md first. Build the state model only, no UI: a pure SubscriptionState (free, subscribed, lapsed, unknown) decided from StoreKit's renewal states as the notes' table maps them (a switch with a default; grace period follows the user's answer recorded in the decision file, Lapsed until then), behind a small store protocol so tests and DEBUG use a fake; 'signed in' is an input from the start (false until phase C) so the later account step does not rewrite the rules; one monthly product (ID from the decision file) in a .storekit test file that is in the test bundle and not shipped in the app; a listener for transaction updates; DEBUG launch argument -debugSubscription free|subscribed|lapsed|unknown. First prove that SKTestSession works in this project under xcodebuild test with Swift Testing (serialized suite) on both runtimes, and find out by experiment whether an app launched with simctl sees a scheme StoreKit configuration; record both results in the task log and in memory/notes. Nothing in the app reads the state yet, so the app's behaviour does not change. No capability or entitlement is added (that needs the user).

## Acceptance criteria

- [ ] State mapping covered by pure tests for every renewal state, an unknown future state, no history, refund, and a StoreKit error
- [ ] SKTestSession tests: buy gives subscribed; expire and refund give lapsed; a fresh session gives free; run serially and pass under xcodebuild test on both runtimes, or the task log says exactly why they cannot and what replaces them
- [ ] The .storekit file is not in the built app bundle (checked in the build products)
- [ ] Suite passes on both runtimes; the app's existing behaviour is unchanged

## Relevant files

- ios/Seasign/Subscription
- ios/SeasignTests
- ios/project.yml

## What's been tried


## Log

- 2026-11-24T19:09:50Z [li] created (backlog)
- 2026-11-24T19:10:14Z [li] User, 2026-11-24: product ID technology.artisan.seasign.monthly; inGracePeriod and inBillingRetryPeriod both map to Lapsed (stop as soon as a renewal fails).
- 2026-11-24T19:57:05Z [li] status: backlog → todo
- 2026-11-24T19:57:05Z [implementer-1] status: todo → in-progress — claimed by implementer-1
