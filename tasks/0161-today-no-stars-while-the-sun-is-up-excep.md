---
id: 161
title: Today: no stars while the sun is up, except fading out through sunrise and in through sunset
status: done
owner: lead
depends_on: []
created: 2026-11-22T03:53:23Z
updated: 2026-11-22T03:57:58Z
---

## Goal

User, 2026-11-21: the mid-day screen still shows stars (they were kept in cloud, rain and snow); stars should only start appearing during sunset and disappear during sunrise. Changes the v11 star rule in plans/2026-11-18-today-v11.md.

## Acceptance criteria

- [x] SceneState.starStrength is 0 for the day, cloudy, rain and snow looks; through the sunrise look it fades from 0.95 at the horizon to 0 where the look ends (12 % of the path); through the sunset look it grows from 0 to 0.95 at the horizon; dusk, night and full stay 1.25
- [x] SceneLookTests updated for the new rule; plan line on stars updated; full iOS suite passes on both runtimes
- [x] A Simulator screenshot (not the Pro Max, not the iPhone 16) of a forced cloudy mid-day shows no stars

## Relevant files

- ios/Seasign/Scene/SceneState.swift
- ios/SeasignTests/SceneLookTests.swift
- plans/2026-11-18-today-v11.md

## What's been tried


## Log

- 2026-11-22T03:53:23Z [li] created (todo)
- 2026-11-22T03:53:26Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-22T03:57:55Z [lead] Lead: SceneState.starStrength is 0 for day, cloudy, rain and snow; fades 0.95 -> 0 through the sunrise look and 0 -> 0.95 through the sunset look (lowSunShare 0.12 now one constant shared with the look rule); night unchanged. SceneLookTests.starsShowOnlyFromSunsetToSunrise replaces the old test. Plan line updated with the user's words and the old rule kept beneath it; the v11 mockup and its cloudy/rain/snow stills now differ from the app and were left alone. Full suite, own run, one at a time: iPhone 16 / iOS 18.3.1 '✔ Test run with 580 tests in 76 suites passed after 18.302 seconds.' '** TEST SUCCEEDED **'; iPhone 17 / iOS 27.2 '✔ Test run with 580 tests in 76 suites passed after 27.364 seconds.' '** TEST SUCCEEDED **'. Screenshots on iPhone 17 / iOS 27.2 (forced states): -debugTime midday -debugWeather cloudy shows cloud and no stars; -debugTime sunset-20 shows stars over the setting sun. Closed by the lead without a separate reviewer (one rule, look only).
- 2026-11-22T03:57:56Z [lead] criterion 1 met: SceneState.starStrength is 0 for the day, cloudy, rain and snow looks; through the sunrise look it fades from 0.95 at the horizon to 0 where the look ends (12 % of the path); through the sunset look it grows from 0 to 0.95 at the horizon; dusk, night and full stay 1.25
- 2026-11-22T03:57:56Z [lead] criterion 2 met: SceneLookTests updated for the new rule; plan line on stars updated; full iOS suite passes on both runtimes
- 2026-11-22T03:57:56Z [lead] criterion 3 met: A Simulator screenshot (not the Pro Max, not the iPhone 16) of a forced cloudy mid-day shows no stars
- 2026-11-22T03:57:58Z [lead] status: in-progress → review
- 2026-11-22T03:57:58Z [lead] status: review → done
