---
id: 217
title: iOS subscription A3: the gate on Settings: popup, UPGRADE NOW, Restore, free zip code; read-only when Lapsed
status: review
owner: implementer-1
depends_on: [216]
created: 2026-11-24T19:09:50Z
updated: 2026-11-24T23:47:47Z
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

- xcrun simctl spawn <udid> defaults write technology.artisan.seasign debugSubscription subscribed: writes data/Library/Preferences (the simulator's global domain), which the sandboxed app does not read; the app's own Debug chip is the way to persist it.

## Log

- 2026-11-24T19:09:50Z [li] created (backlog)
- 2026-11-24T20:46:52Z [li] From task 215 (lead): until the product exists in App Store Connect every real read is Unknown, so the gate would lock the user out of Settings on their own Debug builds. Add a DEBUG-only way to set the subscription state that persists across launches (the existing Settings › Debug scene pattern, reachable from the popup too), besides the -debugSubscription launch argument; Release builds have neither. Unknown shows the popup like Free, with wording that does not claim the person has no subscription (for example a 'Couldn't check your subscription' line and a retry) — bring the exact wording to the lead for the user.
- 2026-11-24T21:13:49Z [li] From the #215 re-review: (1) transactions returned by Product.purchase() are, as far as the reviewer knows, not delivered on Transaction.updates (verify in sosumi): the purchase code must verify, finish and refresh itself. (2) Unknown needs Restore and a retry, and the state is re-read when the app comes to the foreground: with the expiry clock check, a paying customer whose renewal StoreKit has not yet reported reads Lapsed for a moment and could see the renew popup. (3) If StoreKit ever gives two disagreeing entries the state is Unknown until they agree; nothing on the phone resolves it (sandbox check after the deploy; phase B's server check).
- 2026-11-24T21:50:10Z [li] From task 216 (lead): (1) DEBUG hazard to close in this task: -debugSubscription free|lapsed|unknown without a sample flag acts on the user's real store (it wrote my_list in task 216's design); a debug subscription state must never write to the real store or Keychain: either it only applies together with the sample stores, or the lapse handler's write is skipped for it; test it. (2) Remove SubscribedUntilTheGate (SeasignApp.swift) and wire the real model in, as its comments say. (3) Before the first subscription read lands, the state is the starting Unknown: nothing is sent and AI items are hidden, but the saved AI toggle is not moved; at each launch AI-found items stay hidden until the first read lands. (4) Swift Testing starts parameterized result lines with a zero-width space: grep '✘ Test' without the ^ anchor when reading logs.
- 2026-11-24T21:57:14Z [li] Lead, widening the DEBUG note (from the #216 review): any launch with -debugSubscription but without -debugAI builds AI search on the user's real store and Keychain; with 'subscribed' it could send real searches once the default is gone. In this task a debug subscription state must only ever act together with the sample stores (or be refused with a console note), never on the real store or Keychain; test it.
- 2026-11-24T22:21:17Z [li] From the second #216 review: the DEBUG note narrows to -debugSubscription subscribed (or any debug state) without the sample stores acting on the user's real store and Keychain. Also: Search now is disabled while the subscription is checked but its label does not change (say 'Checking…' or reuse 'Searching…'); fix the suite doc comment at AISubscriptionRuleTests.swift:51 (the choice is kept; the toggle shows Use My List).
- 2026-11-24T22:21:17Z [li] status: backlog → todo
- 2026-11-24T22:21:17Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-24T22:28:08Z [implementer-1] implementer-1 started: design = gate model (UpgradeModel) over the real StoreKit SubscriptionModel; AI search always on the real model unless -debugAI sample; DEBUG gate state persisted in the debugSubscription default, applied to the gate only.
- 2026-11-24T22:29:50Z [implementer-1] Fail-first (iPhone 17, before the fix, wiring extracted unchanged into SeasignApp.subscriptionWiring): SubscriptionWiringTests 3 tests failed with 15 issues: production AI source was not the real model (SubscribedUntilTheGate answered Subscribed with no read), and -debugSubscription subscribed without -debugAI sent a discover request on an unreadable real store (stub.count 1, expected 0).
- 2026-11-24T22:50:21Z [implementer-1] Seen to fail (iPhone 17, mutations put in and taken out again): purchase code not finishing -> storeKitPurchaseUnlocksSettingsAndFinishesTheTransaction failed; unverified mapped to purchased -> storeKitPurchaseUnverifiedUnlocksNothing failed; one read after a purchase -> aPurchaseReportedLateStillUnlocks and aPurchaseTheStoreNeverConfirmsSaysSo failed; restore saying 'none found' on Unknown -> aRestoreThatCouldNotCheckSaysSo failed; UPGRADE NOW on the Unknown popup -> theUnknownPopup failed; followSite usable when read-only -> theReadOnlyRule, settingsAccessFollowsTheState failed; debug state using the real storefront -> aDebugPurchaseSucceedsWithoutTheStore, aDebugStateWithNoProductShowsTheUnreachableLine failed. 50 tests, 23 issues, TEST FAILED; all pass with the code restored.
- 2026-11-24T23:33:24Z [implementer-1] Built in 028c5aa. Suites: iPhone 17 iOS 27.2 'Test run with 999 tests in 107 suites passed after 89.787 seconds' + '** TEST SUCCEEDED **'; iPhone 16 iOS 18.3.1 'Test run with 999 tests in 107 suites passed after 569.843 seconds' + '** TEST SUCCEEDED **' (no ✘ lines, unanchored grep). Release build (generic iOS Simulator, unsigned) succeeds; grep -a of the Release binary finds none of debugSubscription, DebugStorefront, 'Debug subscription', debugProductUnavailable, SubscribedUntilTheGate (positive control: the Free headline is there). Screenshots with sample flags only in the session scratchpad shots217/. Simulators: the persistent Debug subscription state was set to subscribed on iPhone 17 and iPhone 16 by tapping the app's own Debug chip (container plist shows debugSubscription = subscribed), and a plain launch then opens editable Settings on both. Note: 'simctl spawn defaults write' lands in the simulator's global domain, not the app's container, so it does not work for this; tried and undone.
- 2026-11-24T23:33:24Z [implementer-1] tried: xcrun simctl spawn <udid> defaults write technology.artisan.seasign debugSubscription subscribed: writes data/Library/Preferences (the simulator's global domain), which the sandboxed app does not read; the app's own Debug chip is the way to persist it.
- 2026-11-24T23:47:47Z [implementer-1] Second commit: ZipCodeSection field holds a @State string fed to ZipEditor.type through onChange and put back to the filtered text (a refusing binding setter could leave a sixth digit or a letter on screen); aPurchaseReportedLateStillUnlocks now uses SequenceSubscriptionStore (Free, Free, Free, then Subscribed) instead of a timed poller. Rerun: iPhone 17 iOS 27.2 'Test run with 999 tests in 107 suites passed after 182.063 seconds' + '** TEST SUCCEEDED **'; iPhone 16 iOS 18.3.1 'Test run with 999 tests in 107 suites passed after 89.523 seconds' + '** TEST SUCCEEDED **'. Both simulators: container plist debugSubscription = subscribed; plain launch on iPhone 17 rechecked after the rerun: Settings opens editable. Typing into the zip field through XcodeBuildMCP type_text did not reach the field (number pad), so the zip filter was not checked by hand.
- 2026-11-24T23:47:47Z [implementer-1] status: in-progress → review
