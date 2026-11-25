---
id: 220
title: iOS subscription: follow-ups from the #217 reviews
status: backlog
owner: 
depends_on: []
created: 2026-11-25T01:03:30Z
updated: 2026-11-25T02:31:13Z
---

## Goal

Left from task 217's two reviews; none breaks the hard rule. (1) A lapsed person cannot remove their AI key (the whole AI section is disabled in read-only Settings): waits for the user's decision on the AI key section. (2) Free and Unknown popups have no VIEW SETTINGS, so someone offline cannot disconnect Google or remove a calendar link: the user's decision. (3) The 'Checking your subscription…' popup has no Try again if the first read never lands; Settings that turns read-only on an Unknown re-read has none either. (4) Disabled category chips, field rules and the 'New events go to' chevron do not look disabled. (5) Tests that pass with the view wiring removed: the .settingsAction tags, the colour block's isEnabled pass-through and VoiceOver guards; no test for a cancelled newest read with an older one in flight; the finish check runs on iOS 26+ only. (6) The zip prompt on Today could open the zip sheet directly for a person who is not Subscribed. (7) -debug* flags other than -debugAI and -debugOpenSettings that reach Settings by a tap need -debugSubscription subscribed.

## Acceptance criteria

- [ ] Each item fixed, or closed with the user's decision recorded
- [ ] Suite passes on both runtimes

## Relevant files

- ios/Seasign/Subscription
- ios/Seasign/Settings
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-25T01:03:30Z [li] created (backlog)
- 2026-11-25T02:29:59Z [li] From task 218's review: no test that SeasignApp.start calls StarterContent.open() or that TodayView passes showsCalendarPrompt (screenshots only); a crash or failed save between creating the store file and the seed save leaves that install empty with no sign; seeded rows have random IDs and will duplicate across devices when sync lands (phase B/C needs stable IDs or a de-duplication rule); VoiceOver says 'Add your calendar in Settings' but a tap on the box opens the day screen.
- 2026-11-25T02:31:13Z [li] From task 218's implementer, unexplained: on a brand-new iOS 27.2 simulator ('T218 Test') the StoreKit purchase/restore tests failed, while they pass on iPhone 17 and iPhone 16. They may depend on StoreKit test-environment state left on those two simulators. Find out why before relying on them on a new machine. Also left on this Mac: three simulators the implementer created ('T218 iPhone 17 Pro', 'T218 Test', 'T218 iPhone SE') and an XcodeBuildMCP profile t218.
