---
id: 192
title: iOS v12: theme foundation (accent environment value, mono type tokens, hue-to-colour rule, Settings.hudHue)
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-23T20:25:09Z
updated: 2026-11-23T20:25:09Z
---

## Goal

Read plans/2026-11-23-v12-in-the-app.md and memory/decisions/2026-11-23-v12-replaces-v11.md first. Add what every v12 screen needs, with no visible change yet: (1) the HUD accent as one environment value read by views, default orange-red rgb(235,78,39); (2) system-mono type tokens for the sizes v12 uses; (3) a pure function from a hue in degrees to the accent colour that holds relative luminance in a band per the plan's Colour rule; (4) Settings.hudHue: Double? (nil = default) stored in SwiftData, and the app root feeding the environment value from it. Guardrails: never commit fonts/ (use git add with named paths, never git add -A at the root); do not delete bundled fonts or other files that fall out of use; rewrite pinned layout tests to new numbers, do not delete them; screenshots on the iPhone 17 simulator with sample data only, never the iPhone 16 Pro Max; one xcodebuild at a time with your own -derivedDataPath.

## Acceptance criteria

- [ ] Hue function tested for every whole degree: at least 4.5:1 against rgb(8,9,12), at least 4.5:1 for the dark on-fill text rgb(14,10,8) on the accent, and never closer to white than a stated threshold; the default orange-red passes the same checks
- [ ] Old-schema store test for the new optional Settings field, as memory/architecture.md requires
- [ ] No visible change: the app looks as before; xcodebuild test passes on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2)

## Relevant files

- ios/Seasign/Design/Palette.swift
- ios/Seasign/Design/Typography.swift
- ios/Seasign/Store/Models.swift
- ios/Seasign/SeasignApp.swift

## What's been tried


## Log

- 2026-11-23T20:25:09Z [li] created (todo)
- 2026-11-23T20:25:09Z [implementer-1] status: todo → in-progress — claimed by implementer-1
