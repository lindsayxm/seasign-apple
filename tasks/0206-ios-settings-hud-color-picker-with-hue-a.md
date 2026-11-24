---
id: 206
title: iOS Settings: HUD color picker with hue and lightness (a color field that fades to white)
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-24T04:39:55Z
updated: 2026-11-24T04:39:55Z
---

## Goal

The user (2026-11-23): replace the hue slider with a color picker: a block where the existing colors (the current per-hue accent) are the floor along the bottom and fade all the way up to white at the top; the user can pick any point in the block. Horizontal position is hue, vertical is lightness. Add Settings.hudLightness: Double? (nil or 0 = the existing color for that hue, 1 = white), keep Settings.hudHue. HUDAccent gets a pure function of (hue, lightness) that returns exactly today's color at lightness 0 and white at 1, rising evenly in between. The user's request replaces the old ceiling (3:1 from the white date tile): the two floors stay and must hold everywhere in the block (4.5:1 on the plate, 4.5:1 for dark text on a fill). Default is still the orange-red (hue nil, lightness nil); the Default link resets both. The preview and note stay as they are.

## Acceptance criteria

- [ ] Pure color function tested over a grid of every whole degree by at least 21 lightness steps: both floors hold; lightness 0 equals the existing color for every degree; lightness 1 is white; luminance never falls as lightness rises
- [ ] Old-schema store test for Settings.hudLightness; a picked color survives relaunch; Default clears hue and lightness (model tests)
- [ ] The block is drawn from the color function (not a stock gradient that could differ from what is picked), with a marker at the current choice; a drag or tap anywhere in it sets both values; VoiceOver can adjust hue and lightness separately with spoken values
- [ ] Screenshots on the iPhone 17: Settings with the picker at the default, a pale pick and white; Today at a pale pick and at white; xcodebuild test passes on both runtimes

## Relevant files

- ios/Seasign/Design/HUDAccent.swift
- ios/Seasign/Settings/HUDColourSettingsSection.swift
- ios/Seasign/Store/Models.swift
- ios/Seasign/Store/SkyStore.swift

## What's been tried


## Log

- 2026-11-24T04:39:55Z [li] created (todo)
- 2026-11-24T04:39:55Z [implementer-1] status: todo → in-progress — claimed by implementer-1
