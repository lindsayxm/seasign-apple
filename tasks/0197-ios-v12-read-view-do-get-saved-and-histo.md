---
id: 197
title: iOS v12: read view, Do / Get, Saved and History restyled
status: in-progress
owner: implementer-1
depends_on: [196]
created: 2026-11-23T20:25:09Z
updated: 2026-11-24T00:44:25Z
---

## Goal

Read plans/2026-11-23-v12-in-the-app.md and memory/decisions/2026-11-23-v12-replaces-v11.md first. Restyle lightly, layouts kept: the read view (details at the top, larger title, summary or article text in the reading face, link to the original site), Do / Get, Saved and History. Mono labels and buttons, accent from the environment, dark ground, the shared sheet scaffold and close mark in the new style. Guardrails: never commit fonts/ (use git add with named paths, never git add -A at the root); do not delete bundled fonts or other files that fall out of use; rewrite pinned layout tests to new numbers, do not delete them; screenshots on the iPhone 17 simulator with sample data only, never the iPhone 16 Pro Max; one xcodebuild at a time with your own -derivedDataPath.

## Acceptance criteria

- [ ] Screenshots of each of the four screens on the iPhone 17 with sample data
- [ ] No behaviour change; xcodebuild test passes on both runtimes

## Relevant files

- ios/Seasign/Reading/ReadingView.swift
- ios/Seasign/Lists/DoGetView.swift
- ios/Seasign/Saved/SavedView.swift
- ios/Seasign/History/HistoryView.swift
- ios/Seasign/Design/SheetScaffold.swift

## What's been tried


## Log

- 2026-11-23T20:25:09Z [li] created (todo)
- 2026-11-24T00:44:25Z [implementer-1] status: todo → in-progress — claimed by implementer-1
