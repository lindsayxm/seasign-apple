---
id: 145
title: iOS: Today v11 — geometry, rules, the scene and the marks tied to the sun, moon and horizon
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-19T03:09:05Z
updated: 2026-11-19T03:31:35Z
---

## Goal

Read plans/2026-11-18-today-v11.md first; it is the spec. Then design-ideas/v11-artemis/index.html (draw(t) and show()) and its twelve stills. Rebuild the Today scene to v11: the path and sizes, the looks and ink colour on real data, stars, day sky and sunrise/sunset bands, the sun as light with its churning face and rippling outer line, the moon with phases, weather gathered round the body, the sea with glints and faint wave lights to the bottom of the screen, the dark veils, bloom and grain; and everything placed from the sun, moon or horizon: hourly ticks, rise and set times, the square, the drop line, and the rise/set tag with its leader. Put the pure rules in SkyMath / SceneState with tests and keep the renderer free of decisions. Expose what task 146 needs (horizon y, ink colour, whether the tag is showing, the wind value) from SceneState / SceneLayout. Leave the header, events, buttons, titles and the history button where they are for now, only keeping them legible over the new scene; task 146 rebuilds them. Do not change Palette values or type styles other screens use. Look up GraphicsContext in sosumi before writing the renderer and pre-render static layers.

## Acceptance criteria

- [ ] Pure rules from the plan (path, radius, looks, ink colour, star strength, tick count, tag and square conditions, labels in both clock styles, null rise or set, neutral scene) are in SkyMath / SceneState with unit tests; all tests pass on iPhone 16 / iOS 18.3 and iPhone 17 / iOS 27.2
- [ ] Twelve iPhone 16 Simulator screenshots, one per v11 state (sunrise, mid-day, sunset, clouds, rain, snow, moon-rise, mid-night, waxing, waning, full, moon-set) through the DEBUG override, are saved and their paths recorded in the task log; the scene in each resembles the matching still in design-ideas/v11-artemis/
- [ ] The animation runs smoothly in the Simulator on both runtimes; Reduce Motion gives a still frame
- [ ] The neutral scene (no zip) and a sky with a missing rise or set draw without ticks, times or tag for the missing parts and without crashing

## Relevant files

- plans/2026-11-18-today-v11.md
- design-ideas/v11-artemis/
- ios/Seasign/Scene/
- ios/SeasignTests/SkyMathTests.swift
- ios/SeasignTests/SceneStateTests.swift

## What's been tried


## Log

- 2026-11-19T03:09:05Z [lead] created (todo)
- 2026-11-19T03:09:16Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-19T03:09:22Z [lead] status: in-progress → todo
- 2026-11-19T03:09:22Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-19T03:31:35Z [implementer-1] Built the v11 scene. Rules in SkyMath (SkyPath: v11 path, lowness, body radius; SkyPass + RiseSetTimeline.pass(at:) for the known rise/set of the drawn pass) and SceneState (look, ink, starStrength, cloudAmount, windMph/windLabel, tickCount, tagEdge/showsTag, showsSquare, riseMark/setMark, tagLines, markTime). Geometry and resolved marks in SceneLayout.swift (SceneLayout v11: horizon 386*s, headlinesTop; SceneMarks). Renderer ported from draw(t): light layers in one drawLayer with a 1.56 colour-matrix gain standing in for the whole-frame bloom; sharp light drawn at 0.68; disc drawn outside the gain with a soft brightening. Stars and other bits from the mockup's own mulberry32 seeds (SceneAssets.swift), grain tile and moon face pre-rendered with Core Graphics. SceneMotion removed: the scene redraws at 30 fps (still frame under Reduce Motion). Headlines now hang from headlinesTop and are coloured Palette.seaText; history button in the ink colour.
