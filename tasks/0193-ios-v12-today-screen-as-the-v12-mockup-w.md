---
id: 193
title: iOS v12: Today screen as the v12 mockup, with the four-tile bar
status: todo
owner: 
depends_on: [192]
created: 2026-11-23T20:25:09Z
updated: 2026-11-23T20:25:09Z
---

## Goal

Read plans/2026-11-23-v12-in-the-app.md and memory/decisions/2026-11-23-v12-replaces-v11.md first. Rebuild the Today overlay to match design-ideas/v12-imago (index.html, README.md with positions in points, stills 01 to 12): mark top left, place name and framed settings top right, white date tile, four-row events box, corner brackets with temperature/wind and daylight labels, rise and set marks, five two-line titles on the dark plate that runs rim to rim with a fading top, the rim outline, and the four bottom tiles (DAY filled, LIST, SAVE, LISTEN with their icons) as a reusable view. In this task the tiles and settings open the existing covers (LISTEN does nothing yet; History's old button goes when task 4 moves it, keep it reachable until then in the least intrusive way). The scene itself is unchanged. Events rows come from a pure tested formatter per the plan's defaults (four events, ALL, weekday, cut with slash; spoken label is the plain event). Tapping the date tile or the events box opens the day calendar; tapping a title opens the read view; dragging the star from SAVE onto a title saves it (read ios/Seasign/Saved/SaveControls.swift first). States the mockup does not draw keep their behaviour in the new style. Other screen sizes per the plan. Guardrails: never commit fonts/ (use git add with named paths, never git add -A at the root); do not delete bundled fonts or other files that fall out of use; rewrite pinned layout tests to new numbers, do not delete them; screenshots on the iPhone 17 simulator with sample data only, never the iPhone 16 Pro Max; one xcodebuild at a time with your own -derivedDataPath.

## Acceptance criteria

- [ ] Simulator screenshots of all twelve scene states on the iPhone 17 match the v12 stills in layout, words and positions (side by side, listed differences explained)
- [ ] Events row formatter is pure and tested: full row, cut title, all-day, other day, widths other than 34
- [ ] Tap targets and the star drag work (tests for both gestures' models; VoiceOver labels for mark, settings, tiles, events, titles)
- [ ] Screens checked on iPhone SE (3rd gen) and iPhone 16 Pro Max sizes via layout tests or a non-Google simulator; pinned layout tests rewritten, none deleted
- [ ] xcodebuild test passes on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2)

## Relevant files

- ios/Seasign/Today/TodayView.swift
- ios/Seasign/Today/TodayOverlayLayout.swift
- ios/Seasign/Calendar/EventsColumn.swift
- ios/Seasign/Feed/HeadlinesColumn.swift
- ios/Seasign/Design/Icons.swift

## What's been tried


## Log

- 2026-11-23T20:25:09Z [li] created (todo)
