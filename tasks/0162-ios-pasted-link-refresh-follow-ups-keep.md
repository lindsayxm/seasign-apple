---
id: 162
title: iOS: pasted-link refresh follow-ups: keep a good scheduled answer when the fresh request fails; missing tests
status: todo
owner: 
depends_on: []
created: 2026-11-22T04:00:26Z
updated: 2026-11-22T04:00:26Z
---

## Goal

Low findings from the #160 review. (1) EventsModel (about line 206) discards a scheduled answer that overlapped a fresh request even when the fresh request then fails (for example our 429), so Today stays stale, or empty right after a zone change, until the hold ends. Discard only once the fresh request has succeeded. (2) Only the last fresh request is remembered (lastFresh); a contrived fresh-A, fresh-B, back-to-A sequence lets a scheduled answer overwrite a fresh one.

## Acceptance criteria

- [ ] A scheduled answer is kept when the overlapping fresh request fails; test with a held transport and a 429
- [ ] Tests added: the minute loop's call never forces (extract the loop's decision so it can be tested); the foreground wiring sends fresh only when isDue; the links half of the same-links-and-zone match
- [ ] Check in the Simulator (not the Pro Max or iPhone 16) how many calendar requests a launch and a return to the foreground send with one pasted link, and record it in the log; iOS suite passes on both runtimes

## Relevant files

- ios/Seasign/Calendar/EventsModel.swift
- ios/Seasign/Today/TodayView.swift
- ios/SeasignTests/EventsModelTests.swift

## What's been tried


## Log

- 2026-11-22T04:00:26Z [li] created (todo)
