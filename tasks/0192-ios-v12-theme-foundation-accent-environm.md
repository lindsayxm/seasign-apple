---
id: 192
title: iOS v12: theme foundation (accent environment value, mono type tokens, hue-to-colour rule, Settings.hudHue)
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-23T20:25:09Z
updated: 2026-11-23T20:46:04Z
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
- 2026-11-23T20:33:43Z [implementer-1] Added Design/HUDAccent.swift: SRGB (WCAG luminance/contrast, HSV), HUDAccent.rgb(hue:) (nil or non-finite = rgb(235,78,39) exactly; hue mod 360; every hue set to the default's luminance 0.2326 at the default's HSV saturation 0.834: darkened when too bright, mixed toward white when too dark; 8-bit rounded), EnvironmentValues.hudAccent (@Entry, default orange-red), HUDAccentRoot (@Query Settings.first?.hudHue, never creates the row) wrapping TodayView inside .modelContainer. Band: floor L >= 0.1898 (max of 4.5:1 on plate rgb(8,9,12) = 0.1873 and 4.5:1 for on-fill rgb(14,10,8) = 0.1898; both are lower bounds), ceiling L <= 0.2630 (3:1 vs date tile rgb(244,242,238), covers pure white too). Default: 5.36 plate, 5.30 on-fill, 3.32 date tile. Palette gains hudAccent, hudPlate(RGB), onAccent(RGB), dateTile(RGB). Typography gains MonoStyle + HUDType tokens (12/.24 place, 12/.12 tile, 11 foot, 13/.39 tab, 12 frame label, 11.3 events, 10.5/0.5pt titles), CSS em spacing converted to points where set. Settings.hudHue: Double? + Task191Schema old-store test.
- 2026-11-23T20:46:04Z [implementer-1] Verified: xcodebuild test passed on iPhone 17 / iOS 27.2 (767 tests in 90 suites, TEST SUCCEEDED) and iPhone 16 / iOS 18.3.1 (767 tests in 90 suites, TEST SUCCEEDED). App launched on iPhone 17 with -debugEvents -debugFeed: Today looks as v11 did (nothing reads hudAccent yet). Sky clause measured on the v12 stills, not tested: sky in the frame-label rows (y 186-218, between the labels) has 99th-percentile luminance <= 0.029 in all 12 states, so the accent (L 0.233, any hue) is >= 3.6:1 there; the brightest pixels (sun/moon glow, L up to 0.33) are near-equal luminance, so visibility there rests on the labels' black shadow. Hue-on-hue (e.g. a blue accent on blue sky) is not covered by a luminance check.
