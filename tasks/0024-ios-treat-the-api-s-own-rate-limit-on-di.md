---
id: 24
title: iOS: treat the API's own rate limit on discover correctly
status: in-progress
owner: implementer-2
depends_on: []
created: 2026-11-16T16:16:42Z
updated: 2026-11-16T16:16:42Z
---

## Goal

From task 19. POST /v1/discover now answers 429 rate_limited both when the provider limits the user's key and when our own per-IP limiter refuses the request; ours carries a Retry-After header and is refused before any provider call, so nothing is billed. The app (ios/Seasign/API/SeasignAPI.swift discover, ios/Seasign/AISearch/AISearchModel.swift) currently counts every 429 against the day's searches and shows 'Your provider is limiting searches'. Distinguish the two by the Retry-After header (present on ours; read openapi/openapi.json for how it is declared): refund the search for our 429, as is done for 400 and 401, show a message that does not blame the provider (for example 'Too many searches from this network. Try again in a minute.'), and do not retry automatically sooner than the Retry-After. Also give sky, calendar, sites and feed a quiet, correct handling of the newly declared 429 (they fall into the default 'unavailable' path today; keep cached data on screen, no error on Today). Nothing under api/ changes.

## Acceptance criteria

- [ ] Unit tests: our 429 on discover refunds the search and maps to its own message; a provider 429 without Retry-After still counts
- [ ] Tests pass on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2)

## Relevant files

- ios/Seasign/API/SeasignAPI.swift
- ios/Seasign/AISearch/
- ios/SeasignTests/

## What's been tried


## Log

- 2026-11-16T16:16:42Z [li] created (todo)
- 2026-11-16T16:16:42Z [implementer-2] status: todo → in-progress — claimed by implementer-2
