---
id: 9
title: iOS: 7-day history and Saved screens
status: todo
owner: 
depends_on: [8]
created: 2026-11-15T22:33:55Z
updated: 2026-11-15T22:33:55Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. The >> button opens History: every FeedItem from the last 7 days, newest first, with keyword search, a category filter and a save action per item. The asterisk button opens Saved (ref-img/00-save-list.png): keyword search, category filter, notes per item, Remove (SwiftData SavedItem, kept after the feed item is pruned). Both open the reading view on tap.

## Acceptance criteria

- [ ] History lists items from the last 7 days and nothing older; search and category filter work
- [ ] Saving from History or the reading view adds the item to Saved; notes persist; Remove deletes it
- [ ] Simulator screenshots of History and Saved recorded in the task log; Saved resembles ref-img/00-save-list.png
- [ ] Tests pass on both simulators

## Relevant files

- ios/Seasign/History/
- ios/Seasign/Saved/
- ios/Seasign/Feed/

## What's been tried


## Log

- 2026-11-15T22:33:55Z [li] created (todo)
