---
id: 195
title: iOS v12: Settings hue slider and Settings restyle
status: in-progress
owner: implementer-1
depends_on: [194]
created: 2026-11-23T20:25:09Z
updated: 2026-11-23T23:21:54Z
---

## Goal

Read plans/2026-11-23-v12-in-the-app.md and memory/decisions/2026-11-23-v12-replaces-v11.md first. Add 'HUD colour' to Settings: one hue slider with a live preview (a sample tile and a line of text in the resulting accent) and a 'Default' control that returns to orange-red. It writes Settings.hudHue; every screen follows at once. Restyle Settings to v12 (dark ground, mono labels, accent outlines), layout and sections kept. Guardrails: never commit fonts/ (use git add with named paths, never git add -A at the root); do not delete bundled fonts or other files that fall out of use; rewrite pinned layout tests to new numbers, do not delete them; screenshots on the iPhone 17 simulator with sample data only, never the iPhone 16 Pro Max; one xcodebuild at a time with your own -derivedDataPath.

## Acceptance criteria

- [ ] Slider changes the accent across the app immediately and survives relaunch; Default restores orange-red (tests at the model level)
- [ ] Screenshots of Settings and of Today in two non-default hues on the iPhone 17; xcodebuild test passes on both runtimes

## Relevant files

- ios/Seasign/Settings/SettingsView.swift

## What's been tried


## Log

- 2026-11-23T20:25:09Z [li] created (todo)
- 2026-11-23T23:21:54Z [implementer-1] status: todo → in-progress — claimed by implementer-1
