---
id: 197
title: iOS v12: read view, Do / Get, Saved and History restyled
status: in-progress
owner: implementer-1
depends_on: [196]
created: 2026-11-23T20:25:09Z
updated: 2026-11-24T00:57:18Z
---

## Goal

Read plans/2026-11-23-v12-in-the-app.md and memory/decisions/2026-11-23-v12-replaces-v11.md first. Restyle lightly, layouts kept: the read view (details at the top, larger title, summary or article text in the reading face, link to the original site), Do / Get, Saved and History. Mono labels and buttons, accent from the environment, dark ground, the shared sheet scaffold and close mark in the new style. Guardrails: never commit fonts/ (use git add with named paths, never git add -A at the root); do not delete bundled fonts or other files that fall out of use; rewrite pinned layout tests to new numbers, do not delete them; screenshots on the iPhone 17 simulator with sample data only, never the iPhone 16 Pro Max; one xcodebuild at a time with your own -derivedDataPath.

## Acceptance criteria

- [ ] Screenshots of each of the four screens on the iPhone 17 with sample data
- [ ] No behaviour change; xcodebuild test passes on both runtimes

## Relevant files

- ios/Seasign/Reading/ReadingView.swift
- ios/Seasign/Lists/DoGetView.swift
- ios/Seasign/Saved/SavedView.swift
- ios/Seasign/History/HistoryView.swift
- ios/Seasign/Design/SheetScaffold.swift

## What's been tried


## Log

- 2026-11-23T20:25:09Z [li] created (todo)
- 2026-11-24T00:44:25Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-24T00:57:18Z [implementer-1] HueTouch carry-over (HUDColourSettingsSection.swift): removed the states the screen never reached (Kind undecided/tracking/ignored, slop, beganSideways, moved/ended deciding by translation). HueTouch now is: isSideways (the pan's gate, unchanged), handle(_ phase: began|changed|ended|cancelled, atX:width:) -> Write (.set(hue, save: false) while moving and owesSave; .set(hue, save: true) at the end and reset; .saveWaiting on cancel if owed, else .none) and tap(atX:width:) -> .set(hue, save: true). HueTrackPan maps the recognizer state to a Phase and applies the Write; the SwiftUI tap goes through HueTouch.tap. Same writes as before on screen. Doc comments of HueTouch, HueTrack and HueTrackPan rewritten. Tests (HueTouchTests, 7 before and after): aScrollThatStartsOnTheTrackChangesNothing -> isSideways refuses up/down first moves and a pan that never began owes nothing; aSidewaysDragSetsTheHueAsItMovesAndSavesAtTheEnd -> began/changed give unsaved sets at the finger (clamped), ended gives a saved set and resets; onlyASidewaysFirstMoveStartsTheDrag -> same gate checks + a small began/ended; aTapSetsTheHueWhereItLands -> HueTouch.tap whole degrees, saved; theOrderOfEndAndResetDoesNotMatter (SwiftUI end/reset order, gone with the UIKit pan) -> theEndOrTheCancelSavesOnce (UIKit ends once; a late cancel after the end owes nothing; a cancel after moves saves once); aCancelledDragSavesWhatItSet -> through handle(.cancelled); closingSettingsMidDragKeepsTheHue unchanged.
