---
id: 8
title: iOS: followed sites with categories, Today headlines, reading view
status: todo
owner: 
depends_on: [4, 7]
created: 2026-11-15T22:33:55Z
updated: 2026-11-15T22:33:55Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. Settings gets a Sites section: enter a page URL and a user-defined category, resolved through /v1/sites/resolve (SwiftData Site). On open, the app calls /v1/feed, stores items as FeedItem and prunes those older than 7 days. Today shows only the newest headlines published since yesterday that fit in the water area, without scrolling. Tapping a headline opens the reading view (ref-img/00-reading.png): source, title, date, the site's excerpt, a save button, and Read on original site.

## Acceptance criteria

- [ ] Adding a site with a category shows its recent headlines on Today
- [ ] Today never scrolls and shows only headlines that fit
- [ ] The reading view shows the excerpt and opens the original article
- [ ] Simulator screenshots of Today with headlines and of the reading view recorded in the task log; tests pass on both simulators

## Relevant files

- ios/Seasign/Settings/
- ios/Seasign/Today/
- ios/Seasign/Feed/
- ios/Seasign/Reading/

## What's been tried


## Log

- 2026-11-15T22:33:55Z [li] created (todo)
