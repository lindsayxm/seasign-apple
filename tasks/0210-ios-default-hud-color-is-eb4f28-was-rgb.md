---
id: 210
title: iOS: default HUD color is #EB4F28 (was rgb 235,78,39 = #EB4E27)
status: done
owner: lead
depends_on: []
created: 2026-11-24T14:52:25Z
updated: 2026-11-24T15:12:36Z
---

## Goal

User, 2026-11-24: set the default color to eb4f28. HUDAccent.defaultRGB becomes SRGB(235, 79, 40); tests, comments and memory/architecture.md follow. Finding before the change: the app and the v12 mockup both already draw exactly rgb(235,78,39) (sampled from Simulator screenshots and from 02-mid-day.png), so this one-step change cannot explain the Simulator looking darker than the web page.

## Acceptance criteria

- [x] HUDAccent.defaultRGB == SRGB(235, 79, 40) and a Simulator screenshot's filled tile samples as (235, 79, 40)
- [x] xcodebuild test passes on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2

## Relevant files

- ios/Seasign/Design/HUDAccent.swift
- ios/SeasignTests/HUDAccentTests.swift

## What's been tried

- Changing only defaultRGB: defaultHue and saturation were written out from the old components (78, 39), so theDefaultsHueGivesTheDefault failed until both followed.

## Log

- 2026-11-24T14:52:25Z [li] created (todo)
- 2026-11-24T14:52:25Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-24T15:12:35Z [lead] Lead: defaultRGB (235,79,40); defaultHue and saturation derive from it (12 degrees, 195/235); hand-worked numbers in HUDAccentTests redone in Python with the same formulas. Suite: 845 passed, TEST SUCCEEDED, on iPhone 17 / iOS 27.2 and iPhone 16 / iOS 18.3.1. iPhone 17 simulator screenshot of the day screen: the accent samples as exactly (235,79,40). Closed by the lead without a separate reviewer (a constant and its dependent numbers). The v12 mockup page and stills still use (235,78,39).
- 2026-11-24T15:12:35Z [lead] tried: Changing only defaultRGB: defaultHue and saturation were written out from the old components (78, 39), so theDefaultsHueGivesTheDefault failed until both followed.
- 2026-11-24T15:12:36Z [lead] criterion 1 met: HUDAccent.defaultRGB == SRGB(235, 79, 40) and a Simulator screenshot's filled tile samples as (235, 79, 40)
- 2026-11-24T15:12:36Z [lead] criterion 2 met: xcodebuild test passes on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2
- 2026-11-24T15:12:36Z [lead] status: in-progress → review
- 2026-11-24T15:12:36Z [lead] status: review → done
