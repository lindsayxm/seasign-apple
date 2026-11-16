---
id: 12
title: iOS: AI search settings and blended, labelled feed
status: review
owner: implementer-2
depends_on: [8, 11]
created: 2026-11-15T22:33:55Z
updated: 2026-11-16T13:43:56Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. Settings gets an AI section: provider picker, API key field stored in the Keychain only, comma-separated interests, max searches per day, and the pill toggle Use My List / Let AI Search. When the toggle is on Let AI Search and the day's count is under the cap, a feed refresh also calls /v1/discover and blends the results into the feed. AI items show a visible AI label on Today, in History and in Saved. The cap is counted on the device (SearchCount per day).

## Acceptance criteria

- [ ] The key is saved in the Keychain and never in SwiftData or logs
- [ ] With the toggle on Use My List no /v1/discover call is made
- [ ] Searches stop once the daily cap is reached
- [ ] AI items carry a visible label; Simulator screenshots of the AI settings and a labelled item recorded in the task log; tests pass on both simulators

## Relevant files

- ios/Seasign/Settings/
- ios/Seasign/Feed/
- ios/Seasign/Auth/

## What's been tried


## Log

- 2026-11-15T22:33:55Z [li] created (todo)
- 2026-11-16T13:14:12Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-16T13:27:51Z [implementer-2] Slice 1 committed: AISearch/ (AIRules, APIKeyStore with Keychain + in-memory fake, AISearchModel, AISettingsSection), PillToggle and AIMark in Design, SeasignAPI.discover with payload-free DiscoverFailure and a RawKeyHeader middleware (the generated client percent-encodes header values, so a key with / + = % would arrive changed), FeedItem/SavedItem/Settings gain optional fields only, SearchCount model in the user store. Builds on iOS 27.2.
- 2026-11-16T13:34:26Z [implementer-2] Tests added (AIRulesTests, DiscoverAPITests, AISearchModelTests incl. AIKeyLeakTests and KeychainKeyStoreTests, LocalStoreTests.storesFromBeforeAISearchOpenAndKeepEverything with Task11Schema legacy classes). Full suite: 309 passed on iPhone 16 / iOS 18.3. Real Keychain round trip passes in the Simulator with no entitlement. Fixed along the way: Foundation names UTC 'GMT', so SearchDay.ianaName maps GMT/UTC to 'UTC'.
- 2026-11-16T13:40:43Z [implementer-2] Verified: full suite 309 passed on iPhone 16 / iOS 18.3 and on iPhone 17 / iOS 27.2 (separate builds, default DerivedData). Release build succeeds; grep -a of the Release app finds none of debugAI, debugFeed, debugSaved, test-key-not-real, addSampleAIItems, InMemoryKeyStore or the sample titles (positive control: the Keychain service name is found). Screenshots (iPhone 17, iOS 27.2, -debugAI YES -debugSaved YES -debugTime midday -debugWeather clear): Today with two AI-marked headlines /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task12/today-ai-labelled.png ; Settings AI section with the pill on Let AI Search and 'Key saved' /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task12/settings-ai-section.png . VoiceOver labels seen in the UI snapshot: 'AI-found: <title>, <source>' on Today, pill as one element 'AI search' value 'Let AI Search', '2 of 3 searches used today'.
- 2026-11-16T13:43:56Z [implementer-2] Review fixes from the advisor: (1) the pill and Search now commit the typed interests first, and a non-empty draft is committed as typed; (2) at launch, AI search on with no key in the Keychain (store restored to another phone) or no interests is written back to Use My List; an unreadable Keychain leaves it. Tests added for both and for count-not-written (injected commit). Leak test now has a positive control (dump contains the interests and the key store type). grep for print/Logger/os_log/NSLog/dump in AISearch/, SeasignAPI.swift, Feed/, Saved/: none. 312 tests pass on iPhone 16 / iOS 18.3 and iPhone 17 / iOS 27.2.
- 2026-11-16T13:43:56Z [implementer-2] status: in-progress → review
