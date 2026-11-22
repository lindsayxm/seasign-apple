---
id: 165
title: Today: horizon rise and set times the same size as the event times
status: done
owner: lead
depends_on: []
created: 2026-11-22T04:44:23Z
updated: 2026-11-22T04:47:18Z
---

## Goal

User, 2026-11-21: 'The times on the horizon are too small - try making them the same size as the day/time on the calendar view (SUN ALL, SUN 8:25 PM, etc.)'. The horizon marks were 8.5 mockup points; the event times are 10.

## Acceptance criteria

- [x] The rise and set times under the horizon are drawn at the event-time size (one shared constant, 10 mockup points, same mono face); their position under the end ticks is unchanged and they do not touch the ticks or the screen edge
- [x] Full iOS suite passes on both runtimes; a screenshot on the iPhone 17 simulator shows the larger times

## Relevant files

- ios/Seasign/Scene/SceneRenderer.swift
- ios/Seasign/Today/TodayOverlayLayout.swift

## What's been tried


## Log

- 2026-11-22T04:44:23Z [li] created (todo)
- 2026-11-22T04:44:23Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-22T04:47:18Z [lead] Lead: the horizon rise and set times use TodayOverlayLayout.Fonts.timeSize (10 mockup points, was 8.5), the constant the event times use; position unchanged; letter spacing left at the marks' own 0.1 (event times use 0.04). Full suite, own run: iPhone 16 / iOS 18.3.1 '✔ Test run with 588 tests in 76 suites passed after 40.232 seconds.' '** TEST SUCCEEDED **'; iPhone 17 / iOS 27.2 '✔ Test run with 588 tests in 76 suites passed after 27.778 seconds.' '** TEST SUCCEEDED **'. Screenshot on iPhone 17 (forced mid-day, sample events from -debugGoogle): the horizon times match the event times in size and clear the ticks and the edges. Closed by the lead without a separate reviewer (look only).
- 2026-11-22T04:47:18Z [lead] criterion 1 met: The rise and set times under the horizon are drawn at the event-time size (one shared constant, 10 mockup points, same mono face); their position under the end ticks is unchanged and they do not touch the ticks or the screen edge
- 2026-11-22T04:47:18Z [lead] criterion 2 met: Full iOS suite passes on both runtimes; a screenshot on the iPhone 17 simulator shows the larger times
- 2026-11-22T04:47:18Z [lead] status: in-progress → review
- 2026-11-22T04:47:18Z [lead] status: review → done
