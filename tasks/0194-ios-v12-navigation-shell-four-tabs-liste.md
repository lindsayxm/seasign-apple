---
id: 194
title: iOS v12: navigation shell (four tabs), Listen placeholder, History from Saved
status: todo
owner: 
depends_on: [193]
created: 2026-11-23T20:25:09Z
updated: 2026-11-23T20:25:09Z
---

## Goal

Read plans/2026-11-23-v12-in-the-app.md and memory/decisions/2026-11-23-v12-replaces-v11.md first. Make DAY (Today), LIST (Do / Get), SAVE (Saved) and LISTEN tabs: the four-tile bar sits at the bottom of those four pages, the filled tile is the page showing, pages switch in place with no close mark. Settings, the day calendar, the read view and History stay full-screen covers with a close mark. Add the Listen page (title LISTEN, the line 'Coming later.'). Move History's ∀ button to the Saved page and remove it from Today. Today's scene animation and refresh loops pause while another tab shows and resume on return, as they do under a cover. On SAVE: tap switches to Saved; the star drag on Today still saves. Guardrails: never commit fonts/ (use git add with named paths, never git add -A at the root); do not delete bundled fonts or other files that fall out of use; rewrite pinned layout tests to new numbers, do not delete them; screenshots on the iPhone 17 simulator with sample data only, never the iPhone 16 Pro Max; one xcodebuild at a time with your own -derivedDataPath.

## Acceptance criteria

- [ ] Each tile switches page and shows filled on its page; tested at the model level
- [ ] History opens from Saved and no longer from Today; Listen shows its placeholder
- [ ] Today's loops pause and resume across tab switches (test)
- [ ] Screenshots of the four pages on the iPhone 17; xcodebuild test passes on both runtimes

## Relevant files

- ios/Seasign/SeasignApp.swift
- ios/Seasign/Today/TodayView.swift
- ios/Seasign/Lists/DoGetView.swift
- ios/Seasign/Saved/SavedView.swift
- ios/Seasign/History/HistoryView.swift

## What's been tried


## Log

- 2026-11-23T20:25:09Z [li] created (todo)
