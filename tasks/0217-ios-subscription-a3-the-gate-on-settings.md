---
id: 217
title: iOS subscription A3: the gate on Settings: popup, UPGRADE NOW, Restore, free zip code; read-only when Lapsed
status: backlog
owner: 
depends_on: [216]
created: 2026-11-24T19:09:50Z
updated: 2026-11-24T19:09:50Z
---

## Goal

Read plans/2026-11-24-account-and-subscription.md (phase A), memory/decisions/2026-11-24-subscription-gate-and-ai-lapse-rule.md and memory/notes/2026-11-24-storekit-research.md first. Tapping settings when Free or Lapsed shows the popup: 'You need an account to update settings.', what the subscription includes, '2.99 a month' from the product's own display price with the renewal terms, links to https://artisan.technology/seasign-terms for terms and privacy, UPGRADE NOW (runs the StoreKit purchase; the Apple sign-in joins in phase C), Restore Purchases (AppStore.sync on tap only), and a 'Change zip code' row that works without a subscription. Subscribed opens Settings as today. Lapsed can also open Settings read-only: nothing can be added or edited, but Disconnect Google, removing a pasted calendar link, Restore, a link to Apple's manage-subscription page and the zip code stay usable (a lapsed person must never be trapped). Production default is locked (Free) and a test pins it; existing tests and every -debug* screenshot path inject Subscribed unless they test the gate; -debugSubscription sets the state for screenshots. v12 style (HUDForm roles); wording is the user's where given. Keep the AI rule (task A2). Do not install a gated build on the iPhone 16 Pro Max, the iPhone 16 or the iPhone 17 simulators without the lead's say: they hold the user's data and would show as Free; use a simulator with no user data for fresh-install checks.

## Acceptance criteria

- [ ] Tests: the gate's decision for free, subscribed, lapsed and unknown; the production default is locked; purchase success unlocks, cancel and failure change nothing; restore; zip code change while Free; what stays usable when Lapsed
- [ ] Screenshots on both runtimes of the popup (Free), Settings read-only (Lapsed), and Settings (Subscribed), from -debugSubscription
- [ ] The AI rule's tests still pass; a reviewer has checked the rule
- [ ] Suite passes on both runtimes

## Relevant files

- ios/Seasign/Settings
- ios/Seasign/Subscription
- ios/Seasign/Today
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-24T19:09:50Z [li] created (backlog)
