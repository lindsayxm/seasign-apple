---
id: 205
title: iOS Today: three events in larger type, larger feed titles (tester feedback)
status: review
owner: implementer-1
depends_on: []
created: 2026-11-24T03:55:57Z
updated: 2026-11-24T04:14:02Z
---

## Goal

A tester found Today's text too small. The user asks: show only the next 3 calendar events in the events box (was 4) so there is more room, and make that text a bit bigger; and make the feed titles on the plate a bit bigger. Keep the box, tiles and everything else where they are. Targets (the lead's reading of 'a bit bigger'; adjust slightly if a figure does not fit, and say so): event rows 11.3 -> 13 points on a 22-point pitch, three rows centred in the same 78-point box, columns per row still computed from the box width (fewer characters fit; the row formatter already handles any width); feed titles 10.5 -> 12 points with a 19-point line, two-line rows (38) on a pitch that still fits five titles above the tiles on a 393x852 screen with the existing 17-point clearance (about 54), numbers and title x unchanged. Other screen sizes keep the existing rules (whole rows only; SE shows fewer).

## Acceptance criteria

- [ ] Today shows at most 3 events; event text and title text are larger as specified; nothing overlaps or clips on 393x852, iPhone 17, iPhone SE and Pro Max sizes (layout tests)
- [ ] Pinned layout and formatter tests rewritten to the new numbers, none deleted; VoiceOver labels unchanged
- [ ] Screenshots on the iPhone 17 (sample data) of mid-day and one night state, and the iPhone SE; xcodebuild test passes on both runtimes

## Relevant files

- ios/Seasign/Today/TodayOverlayLayout.swift
- ios/Seasign/Design/Typography.swift
- ios/Seasign/Calendar/EventsColumn.swift
- ios/Seasign/Feed/HeadlinesColumn.swift

## What's been tried

- Installing the app built for the iPhone 17 (iOS 27.2 destination) on the iPhone SE simulator (iOS 18.3) crashes at launch: libswiftCompatibilitySpan.dylib not loaded. Use the app from the iOS 18.3 build (the iPhone 16 test build's Debug-iphonesimulator/Seasign.app) for the SE.

## Log

- 2026-11-24T03:55:57Z [li] created (todo)
- 2026-11-24T03:56:13Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-24T04:04:02Z [implementer-1] Figures: HUDType.eventRow 13/22 (kern 0), HUDType.title 12 kern 0.5 /19. Mockup.eventRows 3 (TodayView's limit and the prompt rule follow: prompt takes row index count, at most 2). eventsPaddingTop now computed from the box: (78 - 2*1.4 - 3*22)/2 = 4.6, rows at y 111/133/155 on 393x852. Titles: titleLine 19, titleRowHeight 38, titlePitch 54; five fit on 393x852 (fifth ends 715 <= 717) and iPhone 17; SE drops from 2 titles to 1 (54+38=92 > room 88.7). Columns per row: SE 27, 393 29, iPhone 17 30, Pro Max 34 (was 32/34/35/39). Title line holds 37 chars at 290 pt (38 on iPhone 17's 299). Only EventsColumn/TodayOverlayLayout/HeadlinesColumn use these two tokens; nothing else changed size.
- 2026-11-24T04:04:02Z [implementer-1] Deviation: the zip prompt 'Set your zip code in Settings' (29 chars) would be cut mid-word below 32 columns ('...Setti/'). TodayOverlayLayout.zipPrompt(columns:) draws it whole when it fits (Pro Max) and otherwise the short 'Set zip code in Settings' (fits 27+). VoiceOver label unchanged. The no-sites line 'Follow sites in Settings...' at 12 pt (~370 pt) is now held to the title band width so minimumScaleFactor(0.8) shrinks it instead of running off screen.
- 2026-11-24T04:04:02Z [implementer-1] Tests rewritten (none deleted): TodayOverlayLayoutTests (rows 3, columns 27/29/30/34, row y 111/133/155, prompt index 2 and short text, side-gap rule now half a cell to a cell, SE titleCapacity 1, title break 'A short explainer on quantum' / 'mechanics and its uses', 22/19-point heights), TodayPullTests spinner y (4.6 and 22/2, 19/2), HUDAccentTests title tracking 0.5/12. Added theZipPromptIsNeverCutMidWord.
- 2026-11-24T04:11:22Z [implementer-1] Verified: xcodebuild test 831 tests passed, TEST SUCCEEDED on iPhone 17 (OS 27.2) and iPhone 16 (OS 18.3.1) (830 baseline + new theZipPromptIsNeverCutMidWord). Screenshots in scratchpad/t205: iphone17-midday.png, iphone17-night.png, iphone17-realdata-mockevents.png (no-sites line shrunk inside the band), se-midday.png (one title), before-after.png. iPhone 17 shows 30 characters per event row and 38 per title line (37 at 393). Zip prompt state not screenshotted (the simulator's store has a zip; -debugPlace hides the prompt); covered by layout tests.
- 2026-11-24T04:14:02Z [implementer-1] tried: Installing the app built for the iPhone 17 (iOS 27.2 destination) on the iPhone SE simulator (iOS 18.3) crashes at launch: libswiftCompatibilitySpan.dylib not loaded. Use the app from the iOS 18.3 build (the iPhone 16 test build's Debug-iphonesimulator/Seasign.app) for the SE.
- 2026-11-24T04:14:02Z [implementer-1] Zip prompt on screen not seen: the iPhone 17 and SE stores both hold a zip (Chicago) and -debugPlace suppresses the prompt; the new drawn text is covered by TodayOverlayLayoutTests.theZipPromptIsNeverCutMidWord only. Left running on the iPhone 17 with its normal data (screenshot scratchpad/t205/iphone17-normal-data.png).
- 2026-11-24T04:14:02Z [implementer-1] status: in-progress → review
