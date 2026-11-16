---
id: 10
title: iOS: Do/Get list
status: review
owner: implementer-2
depends_on: [4]
created: 2026-11-15T22:33:55Z
updated: 2026-11-16T01:06:23Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. The do/get button opens one screen with two sections, DO on top and GET below, each with its own items, circle checkbox, text field and ADD button (ref-img/00-do-get-list.png; the mockup shows GET on top, the user asked for DO on top). SwiftData ListItem (kind, title, done, created). Stored on the device only for now.

## Acceptance criteria

- [ ] Items can be added to and checked off in each section and survive relaunch
- [ ] Simulator screenshot recorded in the task log; layout resembles the mockup with DO on top
- [ ] Tests pass on both simulators

## Relevant files

- ios/Seasign/Lists/

## What's been tried

- proxy.scrollTo(addRow, anchor: .bottom) to keep the field above the keyboard: on iOS 27 the bottom edge is measured under the keyboard, so the list jumped back to the top and hid the field. Use anchor .center.
- .safeAreaPadding(.bottom) on the List to get more room above the keyboard: with it the list no longer avoided the keyboard on iOS 27. Removed.
- accessibilityElement(children: .ignore) on the row and ADD buttons to stop CapsStyle's textCase uppercasing their labels: it left a nested button element and dropped the disabled state. Uppercasing the string in the view instead keeps one clean element.

## Log

- 2026-11-15T22:33:55Z [li] created (todo)
- 2026-11-16T00:17:40Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-16T01:03:11Z [implementer-2] Built ios/Seasign/Lists/: ListItem (@Model: id UUID, kindRaw do/get, title, isDone, createdAt, updatedAt), ListsModel (@MainActor @Observable: add/toggle/delete/validTitle, saves on every change, sorted by createdAt in memory) and DoGetView. ListItem added to SeasignSchema.models (Store/Models.swift); ListsModel created in SeasignApp and injected with .environment; TodayView opens DoGetView instead of the placeholder. Commit bf5cfc7. No api/ or openapi/ change.
- 2026-11-16T01:03:11Z [implementer-2] Design choices: the whole sheet is one plain List (both sections scroll together) so rows get the system swipe-to-delete; DO on top. Close sits on the DO label line (mockup has no close control). The whole item row is the checkbox button (44 pt+ tall, full width). Return or ADD adds and keeps focus; return on an empty field puts the keyboard away. Titles are stored as typed and uppercased only for display (not with textCase, which also uppercased the VoiceOver label). After focus or an add, the field row is scrolled to the screen centre so field, underline and ADD stay above the keyboard. Sizes measured from the mockup at 2.67 px/pt: margin 20, circle 22.5, row pitch 46, item type Jost 12 pt tracking 0.13, labels 9.5 pt, ADD pill 36 pt tall. Looked up swipeActions, defaultMinListRowHeight, ScaledMetric and ModelContext.save in sosumi.
- 2026-11-16T01:03:11Z [implementer-2] tried: proxy.scrollTo(addRow, anchor: .bottom) to keep the field above the keyboard: on iOS 27 the bottom edge is measured under the keyboard, so the list jumped back to the top and hid the field. Use anchor .center.
- 2026-11-16T01:03:11Z [implementer-2] tried: .safeAreaPadding(.bottom) on the List to get more room above the keyboard: with it the list no longer avoided the keyboard on iOS 27. Removed.
- 2026-11-16T01:03:11Z [implementer-2] tried: accessibilityElement(children: .ignore) on the row and ADD buttons to stop CapsStyle's textCase uppercasing their labels: it left a nested button element and dropped the disabled state. Uppercasing the string in the view instead keeps one clean element.
- 2026-11-16T01:03:11Z [implementer-2] Verified: XcodeBuildMCP test_sim 73 passed, 0 failed on iPhone 16 (iOS 18.3) and iPhone 17 (iOS 27.2), including the 9 ListsModelTests (persistence across a fresh ModelContext). In the Simulator: add by ADD and by return in both sections, whitespace-only return adds nothing, toggle done and back, swipe-to-delete, Close, and items plus done state survive stop/relaunch (iPhone 16) and a full simulator reboot (iPhone 17). First launch on the existing task-4 store did not crash (new entity migrates). Screenshots (iOS 18.3): /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task10/empty.jpg (iPhone 16e) /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task10/with-items.jpg /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task10/one-done.jpg /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task10/after-relaunch.jpg /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task10/swipe-delete.jpg (iPhone 16) /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task10/keyboard-up.jpg (iPhone 16e). iOS 27.2: /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task10/ios27/empty.jpg /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task10/ios27/with-items.jpg /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task10/ios27/one-done.jpg /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task10/ios27/after-relaunch.jpg /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task10/ios27/dynamic-type-ax-large.jpg (iPhone 17) /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task10/ios27/keyboard-up.jpg (iPhone 17e). Keyboard shots are on the 16e/17e because HID typing from the automation tools switched iPhone 16 and 17 to the hardware keyboard, which hides the software one.
- 2026-11-16T01:03:11Z [implementer-2] Differences from the mockup: DO on top (as asked); a CLOSE control on the DO line; the gap under each field is a fixed 48 pt instead of the mockup's ~114 pt (the mockup splits the screen in half, this list flows); type is slightly lighter-looking than the mockup; while typing, the field shows the text as typed, not in caps. Open: the UI snapshot tool lists the checkmark image and title of a done row as extra elements even though the image is accessibilityHidden; not checked with real VoiceOver.
- 2026-11-16T01:06:23Z [implementer-2] Correction to the safeAreaPadding 'tried' entry: unconfirmed. The same failure (list back at the top, field hidden) happened again without the padding and stopped only when the scroll anchor became .center, so the .bottom anchor explains it. Also checked on iPhone 17 (iOS 27.2): swipe-to-delete removes the row without a crash, and Close returns to Today. The iOS 18 one-done.jpg is the same capture as after-relaunch.jpg (the earlier one was overwritten).
- 2026-11-16T01:06:23Z [implementer-2] status: in-progress → review
