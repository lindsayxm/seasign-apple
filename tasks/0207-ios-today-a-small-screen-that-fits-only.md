---
id: 207
title: iOS Today: a small screen that fits only one title at the 54 pitch gets two on a tighter pitch (iPhone SE)
status: review
owner: lead
depends_on: []
created: 2026-11-24T10:45:05Z
updated: 2026-11-24T11:03:46Z
---

## Goal

User's choice 2026-11-24: the iPhone SE gets its second feed title back by a tighter gap between titles; other phones do not change. Layout rule, not a device check: when fewer than two rows fit at Mockup.titlePitch (54) but two fit at a pitch of at least 46 (gap 8), use the largest whole-point pitch that fits two rows. On the SE (375x667) room is 88.68, so the pitch is 50 (gap 12). The pitch becomes an instance value of TodayOverlayLayout read by titleRowTop and titleBand.

## Acceptance criteria

- [ ] At 375x667 titleCapacity is 2, the pitch is 50, and row 2 ends at least 17 points above the tiles; at 393x852 and the iPhone 17 size the pitch is 54 and capacity 5 (TodayOverlayLayoutTests)
- [ ] Row tops, tap bands and star-drop bands all use the same pitch (no remaining read of Mockup.titlePitch outside the rule)
- [ ] Screenshot of Today with two titles at the SE size in the Simulator
- [ ] xcodebuild test passes on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2

## Relevant files

- ios/Seasign/Today/TodayOverlayLayout.swift
- ios/SeasignTests/TodayOverlayLayoutTests.swift

## What's been tried

- Pitch from floor(room + 0.5 - 38): gave 51 on the SE and the second row ended 0.32 into the 17-point clearance; dropped the tolerance, floor(room - 38) = 50.

## Log

- 2026-11-24T10:45:05Z [li] created (todo)
- 2026-11-24T10:45:09Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-24T11:03:45Z [lead] Lead: titlePitch is now an instance value (titlePitch(fitting:)); titleRowTop and titleBand read it; no other reader of Mockup.titlePitch (grep). SE room 88.68 gives pitch 50, capacity 2. Suite: 842 tests passed on iPhone 17 / iOS 27.2 and iPhone 16 / iOS 18.3.1 (TEST SUCCEEDED both). Screenshot on the iPhone SE (3rd gen) simulator with -debugFeed YES -debugEvents YES -debugTime midday shows two titles above the tiles: /private/tmp/claude-501/-Users-li-seasign-seasign-apple/9f3372c6-3fea-4cb1-8afe-f6224e28ebe8/scratchpad/se-today.png (scratchpad, not kept).
- 2026-11-24T11:03:45Z [lead] tried: Pitch from floor(room + 0.5 - 38): gave 51 on the SE and the second row ended 0.32 into the 17-point clearance; dropped the tolerance, floor(room - 38) = 50.
- 2026-11-24T11:03:46Z [lead] status: in-progress → review
