---
id: 4
title: iOS: design system, Today screen and living scene, zip setting
status: review
owner: implementer-1
depends_on: [3]
created: 2026-11-15T22:33:55Z
updated: 2026-11-16T00:06:06Z
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
- 2026-11-15T23:43:28Z [implementer-1] Design from the mockups (1179x2556 px = 393x852 pt at 3x): horizon at 50.7% of height; sky stays charcoal #302F2C day and night; water #B5DCE6 by day, #93BCC9 at night (sampled; not palette sea blue); rule/icons #676663; clouds = charcoal 44% + white 6%; sun radius 141pt at the horizon, 29.5pt at midday; rising sun at 40% of width, midday 50%, setting 60%. Day-name font: PT Sans Narrow Bold (matches 'Sun' in the Nov 15 mockups 00/08-11 glyph for glyph; the older 'Tue' mockups 01-06 use a rounder face, PT Sans Narrow is still closest in width). Jost Book + Medium static files from indestructible-type/Jost; PT Sans Narrow from google/fonts. Font comparison sheets: scratchpad/task4/fontcmp-sun.png and fontcmp-tue.png.
- 2026-11-16T00:00:33Z [implementer-1] Built: Design/ (Palette, Typography incl. SoftenedText, Icons, WrappedCaps), Scene/ (SkySnapshot, SkyMath, SceneState, SceneRenderer, SceneView, SceneDebug), Store/ (SwiftData Settings + CachedSky, SkyStore), Today/ (TodayModel, TodayView, placeholders), Settings/SettingsView, SeasignAPI.sky(zip:). Sun/moon come from a flattened rise/set timeline (events either side of now), never from pairing one day's rise with its set; today's entry is matched by date in the zip's time zone; a stale cache or no zip gives the neutral scene (06-18 day on the clock, clear, no temperature). The moon is drawn only while the sun is down because both share one arc. Headlines use WrappedCaps (own line breaking) because SwiftUI Text cannot set a 14.5pt pitch for 11pt type on iOS 18. Debug override rewrites the inputs (clock + snapshot), set in Settings or with launch args -debugTime sunrise|midday|sunset|night -debugMoon 0..1 -debugWeather clear|cloudy|windy|rain|snow; Release binary has no debug strings (checked with strings).
- 2026-11-16T00:00:33Z [implementer-1] Verified: 64 tests pass on iPhone 16 (iOS 18.3) and iPhone 17 (iOS 27.2); Release configuration builds. Zip typed in Settings on both sims against wrangler dev: 10001 -> New York 43F night scene with waxing crescent; 94103 -> San Francisco 56F rain; 00601 -> 'We couldn't find that zip code. Try a nearby one.' No CoreLocation import or NSLocation key anywhere. Screenshots (iPhone 16, 1179x2556, same size as the mockups) in /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task4/: sunrise.png midday.png sunset.png moon-waxing.png moon-full.png moon-waning.png windy-day.png windy-night.png cloudy-day.png cloudy-night.png rain.png snow.png settings.png live-zip.png no-zip.png; iPhone 17 set in /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task4/ios27/ (same names plus settings-unknown-zip.png). Not checked visually: Reduce Motion (code path draws one still frame).
- 2026-11-16T00:06:05Z [implementer-1] Follow-up checks: Reduce Motion verified on iPhone 17 (setting on: two rain screenshots 2 s apart are byte-identical; off: they differ). Do/Get, Saved and >> each open their placeholder and Close returns. With the API stopped the app relaunches straight into the cached 10001 sky. Today header now exposes one accessibility element; not checked with VoiceOver itself. Final suite: 64 tests pass on iPhone 16 / iOS 18.3 after the last change (iPhone 17 / iOS 27.2 passed the same 64 one commit earlier; the last commit only changed accessibility modifiers and was built and run there). Left for the lead: ios/Seasign/Today/HealthModel.swift and its tests in SeasignAPITests.swift are no longer used by any screen (not deleted: not created in this session); memory/architecture.md needs the new ios layout.
- 2026-11-16T00:06:06Z [implementer-1] status: in-progress → review
