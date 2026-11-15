---
id: 4
title: iOS: design system, Today screen and living scene, zip setting
status: in-progress
owner: implementer-1
depends_on: [3]
created: 2026-11-15T22:33:55Z
updated: 2026-11-15T23:26:44Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. Build the design system (colours from ref-img/palette.png and the mockups, bundled Jost plus a condensed bold font for the day name, letter-spaced caps style), the Today layout (date, day name, temperature, divider, three icon buttons, >> button, headline area with placeholder data) and the scene drawn with Canvas + TimelineView from /v1/sky data: sun and moon on an arc between rise and set in the zip's timezone, large sun at the horizon at sunrise and sunset, moon phase, stars at night, clouds, wind dashes and streaked reflection, rain and snow. Settings screen with the zip field (SwiftData Settings model). A DEBUG-only control forces time and weather. Match ref-img/01 to 11 and 00-button-meanings.png.

## Acceptance criteria

- [ ] Today matches the layout of ref-img/02-midday.png in a Simulator screenshot
- [ ] Screenshots for sunrise, midday, sunset, a moon phase, windy day, cloudy day and a night state are recorded in the task log and resemble the matching ref-img files
- [ ] Entering a zip in Settings changes the temperature and scene; no location permission is requested
- [ ] Unit tests cover sun/moon position and the weather-code mapping; tests pass on iOS 18.3 and 27.2 simulators

## Relevant files

- ios/Seasign/Today/
- ios/Seasign/Design/
- ios/Seasign/Settings/
- ios/project.yml
- ref-img/

## What's been tried


## Log

- 2026-11-15T22:33:55Z [li] created (todo)
- 2026-11-15T23:20:23Z [li] From the task 3 review, for the client: (1) pick today's entry in Sky.days by its date field, not by index; days[0] can be yesterday for up to 15 minutes after local midnight. (2) Place the sun and moon from the UTC instants; a sunset or moonset can fall on the next local date, and sunrise/sunset/moonrise/moonset can each be null (polar days, or no moonrise that day; use current.isDay to tell polar day from polar night). (3) Some real zips are missing from Open-Meteo's geocoder and return 404 unknown_zip (for example PO-box-only zips and Puerto Rico); Settings needs a clear message such as 'We couldn't find that zip code. Try a nearby one.' (4) Start with a stub-transport Swift test that decodes a real /v1/sky payload into Components.Schemas.Sky (dates are second-precision UTC ISO 8601).
- 2026-11-15T23:26:44Z [implementer-1] status: todo → in-progress — claimed by implementer-1
