---
id: 196
title: iOS v12: full-day calendar and add-event sheet restyled
status: in-progress
owner: implementer-1
depends_on: [195]
created: 2026-11-23T20:25:09Z
updated: 2026-11-24T00:28:10Z
---

## Goal

Read plans/2026-11-23-v12-in-the-app.md and memory/decisions/2026-11-23-v12-replaces-v11.md first. Restyle the day calendar (timeline, header, event boxes, now line, notices) and the add-event sheet and confirm popup to v12: mono type, accent outlines and fills from the environment accent, dark ground. Mic, + and close stay in the header row. Layout and behaviour unchanged. Guardrails: never commit fonts/ (use git add with named paths, never git add -A at the root); do not delete bundled fonts or other files that fall out of use; rewrite pinned layout tests to new numbers, do not delete them; screenshots on the iPhone 17 simulator with sample data only, never the iPhone 16 Pro Max; one xcodebuild at a time with your own -derivedDataPath.

## Acceptance criteria

- [ ] Screenshots with -debugDaySample normal, overlap, allday, short and empty on the iPhone 17, plus the add sheet and confirm popup
- [ ] No behaviour change: existing tests pass unchanged apart from pinned style values; xcodebuild test passes on both runtimes

## Relevant files

- ios/Seasign/Calendar/DayView.swift
- ios/Seasign/Calendar/DayTimelineView.swift
- ios/Seasign/Calendar/AddEventSheet.swift

## What's been tried

- Slider fix attempt 1: SwiftUI .simultaneousGesture(DragGesture(minimumDistance: 0)) with the HueTouch gate: the hue no longer changed on a vertical swipe, but the page still did not scroll when the swipe started on the track (axe swipe on iPhone 17). Attempt 2: DragGesture(minimumDistance: 8) simultaneous + onTapGesture: same, no scroll. Working: UIKit UIPanGestureRecognizer via UIGestureRecognizerRepresentable that refuses to begin on a vertical first move, with the scroll pan required to wait for it. Also: axe's zero-length tap never registers on the track (scroll view touch delay); a 0.15 s touch does, so a UIKit tap recognizer was not needed.

## Log

- 2026-11-23T20:25:09Z [li] created (todo)
- 2026-11-24T00:00:10Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-24T00:28:10Z [implementer-1] Built: Day screen (DayView): plate ground + statusBarCover(hudPlate); date in a white tile (Palette.dateTile, onAccent text, mono .section semibold, same caps wording, lineLimit 2/minScale 0.8); accent hairline (HUDRule); mic and + drawn in the accent inside Today's settings frame (HUDGlyph.frame, now internal, via new HUDFrameShape, 24 pt in a 44 pt target), filled with the accent and an onAccent icon while listening; CloseMark unchanged. Notes use HUDForm roles (follow Dynamic Type, still clamped at xxLarge): Listening (accent .section), prompt/hint grey, heard words white .field medium, voice notice HUDNote(warning) + 'Open iPhone Settings' as an accent underlined link, Added note white .note semibold, problem/empty HUDNote. Timeline (DayTimelineView): titles in SF Mono 9 medium (tracking 0.02, was Jost Medium 9 at 0.12), measured with the same font; boxes/chips on the plate outlined 1 pt in the accent, radius 4 (HUDShape.radius), accent titles, grey times; the event under way (or with none the next one; ties all) filled with the accent and onAccent words: new pure DayTimelineFocus.highlighted(rows:day:now:); ended events at 0.5 opacity (was 0.4; accent at 0.4 on the plate was hard to read); +N more chip grey outline; hour labels/lines dim grey; now line, dot and time white. DayTimeline.swift untouched. AddEventSheet: plate ground and presentationBackground, accent .title header, accent hairlines, voice status accent .label, field .hudField with accent underline, draft title mono headline semibold white, rows .label grey / .rowName white, notes HUDNote (warnings Palette.sun), Confirm/Continue/Try again etc. .hudFilled, Cancel/Change/Type it .hudLink(minWidth 44). voice?.popupTouched() still first in every button action; labels, wording and stages unchanged.
- 2026-11-24T00:28:10Z [implementer-1] Slider carry-overs (HUDColourSettingsSection.swift): (1) pure HueTouch gate (slop 8 pt; decided once: sideways tracks, up/down ignored for the rest of the touch; beganSideways; ended(translation) decides an undecided touch by where it lifted so end/reset order cannot matter; cancelled() reports a write owed). On screen the drag is now a UIKit pan through UIGestureRecognizerRepresentable (HueTrackPan, iOS 18+): gestureRecognizerShouldBegin only when HueTouch.isSideways, and shouldBeRequiredToFailBy makes the ScrollView's pan wait for it; taps stay a SwiftUI onTapGesture. (2) SkyStore.saveHUDHue() saves only when the context has changes; called on a cancelled/failed pan and in the section's onDisappear (Settings closing mid-drag). Tests: HueTouchTests (7) incl. order independence, cancel save, and a LocalStore relaunch after a save:false write + saveHUDHue; DayTimelineFocusTests (4).
- 2026-11-24T00:28:10Z [implementer-1] tried: Slider fix attempt 1: SwiftUI .simultaneousGesture(DragGesture(minimumDistance: 0)) with the HueTouch gate: the hue no longer changed on a vertical swipe, but the page still did not scroll when the swipe started on the track (axe swipe on iPhone 17). Attempt 2: DragGesture(minimumDistance: 8) simultaneous + onTapGesture: same, no scroll. Working: UIKit UIPanGestureRecognizer via UIGestureRecognizerRepresentable that refuses to begin on a vertical first move, with the scroll pan required to wait for it. Also: axe's zero-length tap never registers on the track (scroll view touch delay); a 0.15 s touch does, so a UIKit tap recognizer was not needed.
