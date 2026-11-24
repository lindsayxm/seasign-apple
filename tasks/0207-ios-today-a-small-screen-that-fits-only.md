---
id: 207
title: iOS Today: a small screen that fits only one title at the 54 pitch gets two on a tighter pitch (iPhone SE)
status: done
owner: lead
depends_on: []
created: 2026-11-24T10:45:05Z
updated: 2026-11-24T11:07:17Z
---

## Goal

User's choice 2026-11-24: the iPhone SE gets its second feed title back by a tighter gap between titles; other phones do not change. Layout rule, not a device check: when fewer than two rows fit at Mockup.titlePitch (54) but two fit at a pitch of at least 46 (gap 8), use the largest whole-point pitch that fits two rows. On the SE (375x667) room is 88.68, so the pitch is 50 (gap 12). The pitch becomes an instance value of TodayOverlayLayout read by titleRowTop and titleBand.

## Acceptance criteria

- [x] At 375x667 titleCapacity is 2, the pitch is 50, and row 2 ends at least 17 points above the tiles; at 393x852 and the iPhone 17 size the pitch is 54 and capacity 5 (TodayOverlayLayoutTests)
- [x] Row tops, tap bands and star-drop bands all use the same pitch (no remaining read of Mockup.titlePitch outside the rule)
- [x] Screenshot of Today with two titles at the SE size in the Simulator
- [x] xcodebuild test passes on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2

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
- 2026-11-24T11:06:49Z [lead] criterion 1 met: At 375x667 titleCapacity is 2, the pitch is 50, and row 2 ends at least 17 points above the tiles; at 393x852 and the iPhone 17 size the pitch is 54 and capacity 5 (TodayOverlayLayoutTests)
- 2026-11-24T11:06:49Z [lead] criterion 2 met: Row tops, tap bands and star-drop bands all use the same pitch (no remaining read of Mockup.titlePitch outside the rule)
- 2026-11-24T11:06:49Z [lead] criterion 3 met: Screenshot of Today with two titles at the SE size in the Simulator
- 2026-11-24T11:06:49Z [lead] criterion 4 met: xcodebuild test passes on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2
- 2026-11-24T11:06:50Z [lead] review: pass. Reviewer read the code and did NOT rerun xcodebuild (lead's instruction: another task is building in the tree). C1: rule checked at its edges by hand: the pitch tightens only for room 84 to 91.5 (one row at 54 means room 37.5 to 91.5; floor(room-38) >= 46 means room >= 84). Tightened capacity is always exactly 2; the SE room is 88.68, so the pitch is 50 and row 2 ends 0.68 clear of the 17. Room per size (H-210-386W/393): 393x852 256.0, 402x874 269.2, 430x932 299.7, 440x956 313.8 (all 54/5); 375x812 233.7 and 390x844 250.9 (54/4, unchanged); 320x568 43.7 (54/1, unchanged); 375x667 88.68 (50/2). Only the SE changes. C2: titleRowTop and titleBand read the instance pitch; TodayView.bands and StarDrop go through titleBand; HeadlinesColumn places rows through titleRowTop; the star outline (titleRowHeight+10) and headlineSpinnerCenter (titlesTop) do not depend on the pitch; the 44pt tap targets are 6 apart at 50 and 2 apart at the 46 floor. The only other read is the unused default argument on titleRows (TodayOverlayLayout.swift:292), a nit. C3: the scratchpad se-today.png shows two titles with row tops about 105px apart at 2.1x, which is 50pt (not a durable copy). C4: not rerun; the raw logs t16.log and t17.log in the scratchpad show 842 tests passed and TEST SUCCEEDED on iPhone 16 / 18.3.1 and iPhone 17 / 27.2, both naming thePitchTightensOnlyToFitASecondRow and aSmallScreenScalesEverything; they ran after the last edit to the sources, and the tree matches HEAD. Nits: stale 'rows 54 points apart' at HeadlinesColumn.swift:6; the SE doc comment sits on the wrong test at TodayOverlayLayoutTests.swift:327-330; dead min() at TodayOverlayLayout.swift:287; the pre-existing 0.5 tolerance lets row 2 sit up to 0.5 into the clearance for room 91.5 to 92 (no device lands there); not pinned by tests: a 53 case, the 91.5 seam, and capacity at 375x812, 390x844 and 320x568.
- 2026-11-24T11:07:17Z [lead] status: review → done
