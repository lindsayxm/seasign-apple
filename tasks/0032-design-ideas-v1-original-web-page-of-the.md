---
id: 32
title: design-ideas/v1-original: web page of the current app look
status: done
owner: lead
depends_on: []
created: 2026-11-17T01:14:45Z
updated: 2026-11-17T01:17:09Z
---

## Goal

The user asked for a web page for v1 like the ones for v2-v4. Recreate the app's current Today look (flat charcoal sky, coral sun, white moon, pale water) as a self-contained page with the same twelve states, using the real colours, icon paths, cloud shapes and sizes from ios/Seasign (read only). Keep the real app screenshots already in the folder; do not replace them with renders of the page.

## Acceptance criteria

- [x] design-ideas/v1-original/index.html shows the twelve states and was compared with the real screenshots

## Relevant files

- design-ideas/v1-original/

## What's been tried


## Log

- 2026-11-17T01:14:45Z [lead] created (todo)
- 2026-11-17T01:14:45Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-17T01:17:09Z [lead] Built design-ideas/v1-original/index.html at the app's 402x874 points, using the palette, icon paths, cloud shapes, sun and moon sizes and header positions read from ios/Seasign (Palette.swift, Icons.swift, SceneRenderer.swift, TodayView.swift); nothing under ios/ changed. Compared seven states side by side with the real screenshots (sunrise, clouds, rain, snow, moon-rise, mid-night, waxing): colours, positions and wrapping match closely. Known differences: the app softens the corners of the day name and the page does not; the reflection is a gradient, not a true blur; rain and snow marks fall in different places; the status bar is simplified. The real screenshots were kept and no stills were rendered from the page. Animation not watched. Found while doing this: the settings and list icons in v2-halo, v3-cyclo and v4-cartography were drawn from memory and differ from the app's real icons.
- 2026-11-17T01:17:09Z [lead] status: in-progress → review
- 2026-11-17T01:17:09Z [lead] criterion 1 met: design-ideas/v1-original/index.html shows the twelve states and was compared with the real screenshots
- 2026-11-17T01:17:09Z [lead] status: review → done
