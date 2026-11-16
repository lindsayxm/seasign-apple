---
id: 12
title: iOS: AI search settings and blended, labelled feed
status: in-progress
owner: implementer-2
depends_on: [8, 11]
created: 2026-11-15T22:33:55Z
updated: 2026-11-16T13:14:12Z
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
