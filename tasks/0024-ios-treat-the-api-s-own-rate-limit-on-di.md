---
id: 24
title: iOS: treat the API's own rate limit on discover correctly
status: done
owner: implementer-2
depends_on: []
created: 2026-11-16T16:16:42Z
updated: 2026-11-16T16:30:29Z
---

## Goal

From task 19. POST /v1/discover now answers 429 rate_limited both when the provider limits the user's key and when our own per-IP limiter refuses the request; ours carries a Retry-After header and is refused before any provider call, so nothing is billed. The app (ios/Seasign/API/SeasignAPI.swift discover, ios/Seasign/AISearch/AISearchModel.swift) currently counts every 429 against the day's searches and shows 'Your provider is limiting searches'. Distinguish the two by the Retry-After header (present on ours; read openapi/openapi.json for how it is declared): refund the search for our 429, as is done for 400 and 401, show a message that does not blame the provider (for example 'Too many searches from this network. Try again in a minute.'), and do not retry automatically sooner than the Retry-After. Also give sky, calendar, sites and feed a quiet, correct handling of the newly declared 429 (they fall into the default 'unavailable' path today; keep cached data on screen, no error on Today). Nothing under api/ changes.

## Acceptance criteria

- [x] Unit tests: our 429 on discover refunds the search and maps to its own message; a provider 429 without Retry-After still counts
- [x] Tests pass on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2)

## Relevant files

- ios/Seasign/API/SeasignAPI.swift
- ios/Seasign/AISearch/
- ios/SeasignTests/

## What's been tried


## Log

- 2026-11-16T16:16:42Z [li] created (todo)
- 2026-11-16T16:16:42Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-16T16:25:43Z [implementer-2] SeasignAPI maps the declared 429 explicitly on all five routes. sky/calendar/sites/feed: .rateLimited(retryAfter:), also when the generated client cannot decode the 429 (read status + Retry-After from ClientError only, fallback 60). Discover: Retry-After with a whole number => .limitedByServer(retryAfter:) (refunded, own message, no key-refused stop); missing/unparsable => .rateLimited (provider, counted). Delay clamped 1...3600 (ServerRateLimit.delay). Confirmed api/src/routes/discover.ts forwards no provider headers and rate-limit.ts always sets Retry-After.
- 2026-11-16T16:25:43Z [implementer-2] Retry hold: each model keeps an in-memory retryNotBefore. Sky and calendar hold every refresh (Today's 60 s loop); feed holds automatic refresh, 'Refresh headlines now' still sends; resolve holds nothing (separate limiter group). Settings actions (zip, add calendar, add site) always send and show 'Too many requests from this network. Try again in a minute.'. Discover: SearchGate.retryNotBefore folded into the spacing (later wins); it cannot bind today because aiLastSentAt is set at charge and the minimum spacing (72 min at cap 20) exceeds the 3600 s clamp, so it is in memory only and proven in SearchGateTests.
- 2026-11-16T16:25:43Z [implementer-2] Tests: RateLimitFixtures.swift (RateLimitTransport wraps the existing stubs), RateLimitTests.swift (API mapping per route incl. clamp/missing/unparsable header; models keep cache, hold, Settings messages), DiscoverAPITests (429 header matrix, no key in error), AISearchModelTests (refund, provider still counts, hold, clamp, leak loop with our 429), AIRulesTests (refund set, messages, gate). 377 tests pass on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2.
- 2026-11-16T16:29:18Z [implementer-2] Model-level hold test now moves aiLastSentAt a day back so only the delay can hold; checked it fails when retryNotBefore is not passed to the gate. Settings add handlers (calendar, sites) already show the typed AddProblem.message. 378 tests pass on both runtimes.
- 2026-11-16T16:29:18Z [implementer-2] status: in-progress → review
- 2026-11-16T16:30:24Z [implementer-2] criterion 1 met: Unit tests: our 429 on discover refunds the search and maps to its own message; a provider 429 without Retry-After still counts
- 2026-11-16T16:30:24Z [implementer-2] criterion 2 met: Tests pass on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2)
- 2026-11-16T16:30:24Z [implementer-2] review (lead): ran the suite on both runtimes at 429d516 (results in the lead's session log); accepted open points: after a refunded search the next automatic one still waits a full spacing gap; the 'try again in a minute' message stays in Settings until the next search.
- 2026-11-16T16:30:29Z [implementer-2] review (lead), result: 378 tests passed on iPhone 16 (iOS 18.3.1) and on iPhone 17 (iOS 27.2).
- 2026-11-16T16:30:29Z [implementer-2] status: review → done
