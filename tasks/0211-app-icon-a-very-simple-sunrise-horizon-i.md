---
id: 211
title: App icon: a very simple sunrise / horizon illustration, first try
status: in-progress
owner: lead
depends_on: []
created: 2026-11-24T14:52:25Z
updated: 2026-11-24T15:12:36Z
---

## Goal

User, 2026-11-24: create an image to use for the app icon; try a very simple sunrise / horizon illustration. Draw it as SVG, render a 1024x1024 PNG (no transparency, square corners; iOS rounds them), keep sources in design-ideas/app-icon/, and show the user. Wire it into the app (asset catalog through ios/project.yml) only after the user likes it.

## Acceptance criteria

- [x] design-ideas/app-icon/ holds the SVG source and a 1024x1024 opaque PNG; the lead has looked at the PNG at full size and at 120 px
- [ ] The user has seen it

## Relevant files

- design-ideas/app-icon

## What's been tried


## Log

- 2026-11-24T14:52:25Z [li] created (todo)
- 2026-11-24T14:52:25Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-24T15:12:36Z [lead] Lead: icon-v1 (near-black, horizon line edge to edge after the user's first note) and icon-v2 (bigger sun r 290, deep blue-grey sky, lighter blue-grey water) in design-ideas/app-icon/, SVG and 1024 opaque PNG each, rendered with headless Chrome; viewed at 512 and 120 px. User said v1 'looks good' and asked for v2's changes; waiting for their view of v2. Not wired into the app.
- 2026-11-24T15:12:36Z [lead] criterion 1 met: design-ideas/app-icon/ holds the SVG source and a 1024x1024 opaque PNG; the lead has looked at the PNG at full size and at 120 px
