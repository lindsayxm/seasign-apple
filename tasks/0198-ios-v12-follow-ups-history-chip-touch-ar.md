---
id: 198
title: iOS v12 follow-ups: History chip touch area, AI key row case, sample flags, unseen states
status: backlog
owner: 
depends_on: []
created: 2026-11-24T01:33:59Z
updated: 2026-11-24T18:03:16Z
---

## Goal

Small items left from the v12 build reviews (tasks 193 to 197).

## Acceptance criteria

- [ ] History's save chip has its 44-point touch area inside the button style (HistoryView.swift:129-131), checked on both runtimes
- [ ] 'Key can't be read now' and 'Key saved' in AISettingsSection.swift follow one case rule
- [ ] DEBUG flags to seed Do / Get items in memory and to show a Saved problem; screenshots of the states nobody has seen: Saved empty, Saved problem line, 'Notes are full', AI key warning, add-event sheet warnings, the day screen's Added note; day screen re-screenshotted with ended events at 70%
- [ ] Settings and the main screens looked at with large Dynamic Type and on iOS 18.3.1

## Relevant files


## What's been tried


## Log

- 2026-11-24T01:33:59Z [li] created (backlog)
- 2026-11-24T01:37:30Z [li] Also from the #195 review, not yet carried anywhere: StarFlight.land's guard depends on SwiftUI delivering the drag's end before the @GestureState reset (StarDrop.swift:79, HUDTileBar.swift:86), an order SwiftUI does not document; the iOS 18 proof shot was doubted. Needs a by-hand drag of the star on both runtimes (and on a phone), or a guard that does not depend on the order. Lead check 2026-11-23: accent over the sky looked at on the iPhone 17 with hue-matched cases (blue at mid-day, pink and orange at sunset, cyan with the moon up): every accent part stayed readable, because they all sit over the dark top of the sky.
- 2026-11-24T04:23:27Z [li] From task 205: rename theBoxNeverShowsMoreThanFourRows and thePromptAndThreeEventsAlwaysFit (they now check three rows and two events); the short zip prompt has not been seen on screen; a second voice timing test (theAnswerWindowClosesAfterAFewSeconds) failed once under load on iPhone 16.
- 2026-11-24T06:00:57Z [li] From task 206: VoiceOver's hue and lightness adjust actions have never fired in the running app; the choice label at large Dynamic Type; the marker ring overhangs the block's edge at white; three voice timing tests have now failed under load on iPhone 16 (worth making them independent of wall-clock time).
- 2026-11-24T11:07:18Z [li] From the #207 review (2026-11-24), low and nits: remove the default pitch on TodayOverlayLayout.titleRows(fitting:pitch:); the min(tight, 54) that never takes effect; HeadlinesColumn.swift:6 still says rows 54 apart; the SE doc comment in TodayOverlayLayoutTests sits above the wrong test; add tests for pitch 53, the 91.5 seam, titleRows(fitting: 84, pitch: 46), capacity at 375x812, 390x844 and 320x568, and star-drop bands at the SE size.
- 2026-11-24T14:43:34Z [li] From the #208 review (2026-11-24), low: check at native resolution that the now line's piece inside the filled box lines up with the white line outside it; the line is half clipped when now is exactly on the box's top; tests for now on a box's top and bottom edge.
- 2026-11-24T18:03:16Z [li] From the #214 review (2026-11-24), low: (b) a hold that starts while the Google sheet is up, or the app's own 429 on the new-list read, still says 'couldn't reach Google'; show the busy note when the failure is rateLimited. (c) tests: a back-off or Google's hold still lets Connect again open the sheet; a sign-in that ends during the sheet and comes back as another account or with an unreadable list; Disconnect plus a newer Connect at the sheet guard. (d) an exchange failure as the sign-in ends shows no message. (e) Google's 60 s hold replacing the app's own resets holdIsServerLimit (also noted in tasks 164 and 213).
