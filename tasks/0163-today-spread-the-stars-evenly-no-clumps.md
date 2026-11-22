---
id: 163
title: Today: spread the stars evenly (no clumps)
status: done
owner: lead
depends_on: []
created: 2026-11-22T04:04:17Z
updated: 2026-11-22T04:32:05Z
---

## Goal

User, 2026-11-21: on a long-running Today the stars 'are kind of collecting like particles around the moon'. 45 % of the 2,600 stars sit in 11 clumps (from the v11 mockup) and the field turns about the middle of the horizon, so a clump passing the moon looks like stars gathering. The user chose the quick fix: keep the invented field but spread every star evenly. (A real sky from a star catalog was offered and not chosen.)

## Acceptance criteria

- [x] SceneBits places every star evenly over the wheel's disc (no clumps); count, sizes, twinkle and colours unchanged
- [x] A test that the field has no clump: no cell of a coarse grid over the disc holds far more stars than an even spread would give
- [x] Full iOS suite passes on both runtimes; a night screenshot on the iPhone 17 simulator shows an even field

## Relevant files

- ios/Seasign/Scene/SceneAssets.swift
- ios/SeasignTests/SceneLookTests.swift

## What's been tried


## Log

- 2026-11-22T04:04:17Z [li] created (todo)
- 2026-11-22T04:04:17Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-22T04:32:05Z [lead] Lead: SceneBits now places all 2,600 stars evenly over the wheel's disc (clump code removed; starCount is a constant); SceneLookTests.theStarFieldHasNoClumps checks 48 equal-area cells. Full suite, own run at f20ae6e plus these edits: iPhone 16 / iOS 18.3.1 '✔ Test run with 588 tests in 76 suites passed after 25.879 seconds.' '** TEST SUCCEEDED **'; iPhone 17 / iOS 27.2 '✔ Test run with 588 tests in 76 suites passed after 28.481 seconds.' '** TEST SUCCEEDED **'. Forced night screenshot on iPhone 17 shows an even field with no cluster. The field no longer matches the v11 stills star for star. Closed by the lead without a separate reviewer (look only).
- 2026-11-22T04:32:05Z [lead] criterion 1 met: SceneBits places every star evenly over the wheel's disc (no clumps); count, sizes, twinkle and colours unchanged
- 2026-11-22T04:32:05Z [lead] criterion 2 met: A test that the field has no clump: no cell of a coarse grid over the disc holds far more stars than an even spread would give
- 2026-11-22T04:32:05Z [lead] criterion 3 met: Full iOS suite passes on both runtimes; a night screenshot on the iPhone 17 simulator shows an even field
- 2026-11-22T04:32:05Z [lead] status: in-progress → review
- 2026-11-22T04:32:05Z [lead] status: review → done
