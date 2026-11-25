---
id: 218
title: iOS subscription A4: fresh-install content: three starter sites, two list items, 'Add your calendar... ↑'
status: in-progress
owner: implementer-1
depends_on: [217]
created: 2026-11-24T19:09:50Z
updated: 2026-11-25T01:03:30Z
---

## Goal

Read plans/2026-11-24-account-and-subscription.md (phase A), memory/decisions/2026-11-24-subscription-gate-and-ai-lapse-rule.md and memory/notes/2026-11-24-storekit-research.md first. On a fresh install (when the stores are first created, like the default zip; never put back after removal): followed sites Hacker News (https://news.ycombinator.com/, feed https://news.ycombinator.com/rss), Wired Science (https://www.wired.com/category/science/, feed mode with https://www.wired.com/feed/category/science/latest/rss) and Ars Technica Space (https://arstechnica.com/space/, feed https://arstechnica.com/space/feed/), stored as the API's resolve would return them; 'Go outside' on the Do list and 'Concert tickets' on the Get list, for everyone, no subscription needed; with no calendar the events box says 'Add your calendar... ↑' with the arrow toward the settings button (keep the zip prompt rule and the narrow-box rule from task 205). A subscriber can remove the sites. Check on a simulator with no user data; never delete the app from the iPhone 16 Pro Max, iPhone 16 or iPhone 17 simulators.

## Acceptance criteria

- [ ] Tests: seeds written once when the store is first created and not again after removal; an existing store is not seeded; the events box text with and without a calendar and on the iPhone SE width
- [ ] Screenshot of a fresh install on a clean simulator against local wrangler dev: three sites' headlines on Today, the two list items, the calendar prompt
- [ ] Suite passes on both runtimes

## Relevant files

- ios/Seasign/Store
- ios/Seasign/Feed
- ios/Seasign/Lists
- ios/Seasign/Today
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-24T19:09:50Z [li] created (backlog)
- 2026-11-25T01:03:30Z [li] status: backlog → todo
- 2026-11-25T01:03:30Z [implementer-1] status: todo → in-progress — claimed by implementer-1
