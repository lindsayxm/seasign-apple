---
id: 198
title: iOS v12 follow-ups: History chip touch area, AI key row case, sample flags, unseen states
status: backlog
owner: 
depends_on: []
created: 2026-11-24T01:33:59Z
updated: 2026-11-24T01:37:30Z
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
