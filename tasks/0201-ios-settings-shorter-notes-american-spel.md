---
id: 201
title: iOS Settings: shorter notes, American spelling 'Color', calendar and AI text as the user wrote it
status: done
owner: lead
depends_on: []
created: 2026-11-24T02:55:14Z
updated: 2026-11-24T03:01:19Z
---

## Goal

Text changes in Settings requested by the user on 2026-11-23: shorter notes under Zip code, HUD color, Google Calendar, Calendars (no Google iCal instructions, a line about Apple and Outlook, no 'next three events' note), Follow site and AI search; the interests placeholder; 'Color' wherever the user sees 'colour'. Google iCal links are still accepted.

## Acceptance criteria

- [x] Each text reads as the user gave it; no user-visible or spoken 'colour' remains in the app
- [x] Screenshots of Settings on the iPhone 17; xcodebuild test passes on both runtimes

## Relevant files

- ios/Seasign/Settings/SettingsView.swift
- ios/Seasign/Settings/HUDColourSettingsSection.swift
- ios/Seasign/Calendar/CalendarSettingsSection.swift
- ios/Seasign/Google/GoogleSettingsSection.swift
- ios/Seasign/Feed/SitesSettingsSection.swift
- ios/Seasign/AISearch/AISettingsSection.swift

## What's been tried


## Log

- 2026-11-24T02:55:14Z [li] created (todo)
- 2026-11-24T02:55:14Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-24T03:01:18Z [lead] Texts changed as the user wrote them: zip note; 'HUD color' (heading and both VoiceOver labels) and its one-sentence note; Google Calendar's not-connected note; Calendars: Google instructions removed (links still accepted), the 'next three events' note removed, one line about Apple and Outlook added under their instructions; Follow site note; AI search note ('enables' in the request written as 'enabled'); interests placeholder 'New Tech, Scientific Breakthroughs'. No visible or spoken 'colour' left (code names keep the old spelling). Lead runs: iPhone 16 / iOS 18.3.1 830 tests passed, TEST SUCCEEDED; iPhone 17 / iOS 27.2 830 tests passed, TEST SUCCEEDED. Seen on the iPhone 17: Settings top by screenshot; the Google, Calendars and color notes in the UI snapshot. Follow site and AI search notes not looked at on screen.
- 2026-11-24T03:01:18Z [lead] criterion 1 met: Each text reads as the user gave it; no user-visible or spoken 'colour' remains in the app
- 2026-11-24T03:01:18Z [lead] criterion 2 met: Screenshots of Settings on the iPhone 17; xcodebuild test passes on both runtimes
- 2026-11-24T03:01:18Z [lead] status: in-progress → review
- 2026-11-24T03:01:19Z [lead] status: review → done
