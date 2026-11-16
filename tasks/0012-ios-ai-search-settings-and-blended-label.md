---
id: 12
title: iOS: AI search settings and blended, labelled feed
status: done
owner: implementer-2
depends_on: [8, 11]
created: 2026-11-15T22:33:55Z
updated: 2026-11-16T13:56:09Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. Settings gets an AI section: provider picker, API key field stored in the Keychain only, comma-separated interests, max searches per day, and the pill toggle Use My List / Let AI Search. When the toggle is on Let AI Search and the day's count is under the cap, a feed refresh also calls /v1/discover and blends the results into the feed. AI items show a visible AI label on Today, in History and in Saved. The cap is counted on the device (SearchCount per day).

## Acceptance criteria

- [x] The key is saved in the Keychain and never in SwiftData or logs
- [x] With the toggle on Use My List no /v1/discover call is made
- [x] Searches stop once the daily cap is reached
- [x] AI items carry a visible label; Simulator screenshots of the AI settings and a labelled item recorded in the task log; tests pass on both simulators

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
- 2026-11-16T13:55:10Z [implementer-2] criterion 1 met: The key is saved in the Keychain and never in SwiftData or logs
- 2026-11-16T13:55:10Z [implementer-2] criterion 2 met: With the toggle on Use My List no /v1/discover call is made
- 2026-11-16T13:55:11Z [implementer-2] criterion 3 met: Searches stop once the daily cap is reached
- 2026-11-16T13:55:11Z [implementer-2] criterion 4 met: AI items carry a visible label; Simulator screenshots of the AI settings and a labelled item recorded in the task log; tests pass on both simulators
- 2026-11-16T13:55:11Z [implementer-2] review: PASS on all four criteria, verified by the reviewer. xcodegen generate leaves the tree clean; 312 tests pass on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2; a full Release simulator build has no warnings from our code, and the Release binary holds none of debugAI/debugFeed/debugSaved/test-key-not-real/InMemoryKeyStore/addSampleAIItems/sample titles. Key-leak tests are meaningful: persisting the key in Settings.zip fails the SwiftData-row and store-file checks, keeping the raw key on the model fails the dump check, and charging after the response fails 8 cap/count tests (all restored, git diff clean). Keychain: generic password, AfterFirstUnlockThisDeviceOnly, synchronizable false, update-then-add, delete tolerates errSecItemNotFound, no entitlements or access group. Gate, count and isSearching are all set synchronously on the main actor before the first await. Screenshots read: AI marks on Today and the Settings AI section; they are stored in the session scratchpad, which is not durable. Follow-ups (none block): MEDIUM, before any deploy: URLSession follows redirects and re-sends X-LLM-Key to the new host (reproduced locally with a 307 to another origin), so discover should use a session or delegate that refuses redirects. LOW: there is no https check on the base URL before the key is attached (ATS covers only qualified http hosts). LOW: interests are limited to 80 Characters on iOS but 80 code points / 400 UTF-16 units in the API, so long emoji interests get a 400, which is refunded. LOW: the day key follows the zip's zone, so changing zip (Guam to American Samoa) or travelling opens a new day for manual searches. LOW: hasKey is not re-read after a Keychain that was unreadable at launch, and the key outlives uninstall.
- 2026-11-16T13:56:09Z [implementer-2] lead: reviewer passed all four criteria (312 tests on both runtimes, Release clean, three leak/charge mutations each caught). Its findings are moved to task 21: redirects carry the key to another host (medium, before any deploy), no https guard, interest length measured differently from the API, key status after a locked launch.
- 2026-11-16T13:56:09Z [implementer-2] status: review → done
