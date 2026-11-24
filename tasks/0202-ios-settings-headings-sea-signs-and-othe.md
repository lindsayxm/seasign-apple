---
id: 202
title: iOS Settings: headings SEA SIGNS and OTHER CALENDARS, field WEB PAGE ADDRESS
status: done
owner: lead
depends_on: []
created: 2026-11-24T03:04:40Z
updated: 2026-11-24T03:09:37Z
---

## Goal

At the user's request: the Sites heading reads Sea signs (more than websites will go there), its Page address field reads Web page address, and the Calendars heading under Google reads Other calendars.

## Acceptance criteria

- [x] The three labels read as asked; xcodebuild test passes on both runtimes

## Relevant files

- ios/Seasign/Feed/SitesSettingsSection.swift
- ios/Seasign/Calendar/CalendarSettingsSection.swift

## What's been tried


## Log

- 2026-11-24T03:04:40Z [li] created (todo)
- 2026-11-24T03:04:40Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-24T03:09:37Z [lead] Headings 'Sea signs' and 'Other calendars' (drawn in capitals), field label 'Web page address' (also its VoiceOver label). Lead runs: iPhone 16 / iOS 18.3.1 830 tests passed, TEST SUCCEEDED; iPhone 17 / iOS 27.2 830 tests passed, TEST SUCCEEDED. Installed on the iPhone 17; not looked at on screen.
- 2026-11-24T03:09:37Z [lead] criterion 1 met: The three labels read as asked; xcodebuild test passes on both runtimes
- 2026-11-24T03:09:37Z [lead] status: in-progress → review
- 2026-11-24T03:09:37Z [lead] status: review → done
