---
id: 200
title: iOS Do / Get: CLEAR CHECKED button on each list
status: done
owner: lead
depends_on: []
created: 2026-11-24T01:54:46Z
updated: 2026-11-24T02:00:47Z
---

## Goal

At the user's request: when a list (DO or GET) has at least one checked item, show a CLEAR CHECKED button for that list; tapping it deletes that list's checked items and nothing else.

## Acceptance criteria

- [x] The button shows only on a list with a checked item, and clears only that list's checked items (model tests)
- [x] Screenshot on the iPhone 17; xcodebuild test passes on both runtimes

## Relevant files

- ios/Seasign/Lists/ListsModel.swift
- ios/Seasign/Lists/DoGetView.swift

## What's been tried


## Log

- 2026-11-24T01:54:46Z [li] created (todo)
- 2026-11-24T01:54:46Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-24T02:00:47Z [lead] ListsModel.hasChecked(kind) and clearChecked(kind) (one save; only that list's checked items); DoGetView shows a CLEAR CHECKED link at the right of a list's heading while that list has a checked item (VoiceOver: 'Clear checked Do items'). New test clearCheckedRemovesOnlyThatListsCheckedItems. Lead runs: iPhone 16 / iOS 18.3.1 830 tests passed, TEST SUCCEEDED; iPhone 17 / iOS 27.2 830 tests passed, TEST SUCCEEDED. On the iPhone 17 the lead ticked an item and saw the button appear on DO only; the tap on the button itself was not exercised on screen (model test only). No separate reviewer for this small change.
- 2026-11-24T02:00:47Z [lead] criterion 1 met: The button shows only on a list with a checked item, and clears only that list's checked items (model tests)
- 2026-11-24T02:00:47Z [lead] criterion 2 met: Screenshot on the iPhone 17; xcodebuild test passes on both runtimes
- 2026-11-24T02:00:47Z [lead] status: in-progress → review
- 2026-11-24T02:00:47Z [lead] status: review → done
