---
id: 146
title: iOS: Today v11 — the fixed overlay: header, events box, hairline, wind line, buttons, titles, ∀
status: todo
owner: 
depends_on: [145]
created: 2026-11-19T03:09:05Z
updated: 2026-11-19T03:09:05Z
---

## Goal

Read plans/2026-11-18-today-v11.md first (section 'Fixed overlay'), then design-ideas/v11-artemis/index.html and its stills. Rebuild the Today screen's fixed parts to v11 over the scene from task 145: the white left column (date, condensed day name sized to the date's width, temperature), the events box with ink-coloured rules and two-column times, the hairline, the wind line (only when the tag is not showing), the three muted buttons in a column centred on x 331, up to five numbered serif article titles 57 points apart, and the ∀ button centred at the bottom that opens the 7-day history. Use the geometry, ink colour and tag/wind state that task 145 exposes; do not redefine them. Keep every existing behaviour listed under Scope in the plan (zip prompt, no-sites prompt, AI mark, status lines, fewer than three events, 12/24-hour, 44-point targets, accessibility, DEBUG samples). Add new colours and type styles; do not change the ones other screens use. Update memory/architecture.md is the lead's job; list what changed in the task log.

## Acceptance criteria

- [ ] Twelve iPhone 16 Simulator screenshots, one per v11 state, are saved with paths in the task log; header, events, hairline, wind line, buttons, titles and ∀ match the positions, type and colours of the matching still
- [ ] Real-text cases are checked with screenshots: no zip (prompt), no sites (prompt), one event, a long event title that wraps, an AI-found item, a 24-hour phone; nothing overlaps or clips
- [ ] A second screen size (smaller or larger iPhone) is checked; nothing overlaps or clips, and ∀ clears the home bar
- [ ] All tests pass on iPhone 16 / iOS 18.3 and iPhone 17 / iOS 27.2; VoiceOver labels for the header, events, buttons, titles and ∀ are present

## Relevant files

- plans/2026-11-18-today-v11.md
- design-ideas/v11-artemis/
- ios/Seasign/Today/
- ios/Seasign/Calendar/EventsColumn.swift
- ios/Seasign/Feed/HeadlinesColumn.swift
- ios/Seasign/Design/

## What's been tried


## Log

- 2026-11-19T03:09:05Z [lead] created (todo)
