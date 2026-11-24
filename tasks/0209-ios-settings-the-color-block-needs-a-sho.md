---
id: 209
title: iOS Settings: the color block needs a short press before a drag picks a color; a swipe that starts on it scrolls
status: todo
owner: 
depends_on: []
created: 2026-11-24T10:45:05Z
updated: 2026-11-24T10:45:05Z
---

## Goal

User's choice 2026-11-24: in Settings a scroll that starts with the finger on the HUD color block changes the color (task 206: HUDColourFieldPan, a UIPanGestureRecognizer the scroll view's pan waits on). Change it so a swipe that starts on the block scrolls the page, and the block picks a color only after a short press (about 0.15 s) followed by an optional drag, or on a tap. Likely shape: a UILongPressGestureRecognizer (minimumPressDuration about 0.15, small allowableMovement) in place of the pan, keeping shouldReceive (touch-down inside the block only) and making the scroll view's pan wait for it to fail; check in sosumi that it keeps reporting .changed as the finger moves, and the UIGestureRecognizerRepresentable API on iOS 18. Keep HUDColourTouch as the tested rule for what is written and saved. Update the doc comment on HUDColourTouch and HUDColourFieldPan, and the color block lines in memory/architecture.md. iOS 18 is where the previous version broke scrolling across all of Settings: check it there with care. Use the iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2) simulators; never the iPhone 16 Pro Max.

## Acceptance criteria

- [ ] By hand on both runtimes (XcodeBuildMCP touch/swipe/long-press), noted in the task log: a quick swipe that starts on the block scrolls Settings with no noticeable delay and leaves the color unchanged; a swipe that starts just outside the block scrolls; slow swipes elsewhere in Settings scroll
- [ ] By hand on both runtimes: press about 0.2 s then drag changes the color as the finger moves, never scrolls, and saves once at the end; a quick tap sets and saves the color once; press and lift without moving writes and saves exactly once (tap and recognizer do not both fire, nor neither)
- [ ] HUDColourTouch tests cover the new sequence, including a press cancelled before it begins writing nothing
- [ ] VoiceOver's two adjustable elements are unchanged
- [ ] xcodebuild test passes on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2 (the two voice timing tests can fail under load: rerun before blaming the change)

## Relevant files

- ios/Seasign/Settings/HUDColourSettingsSection.swift
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-24T10:45:05Z [li] created (todo)
