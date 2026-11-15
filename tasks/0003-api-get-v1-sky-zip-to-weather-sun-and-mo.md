---
id: 3
title: API: GET /v1/sky (zip to weather, sun and moon)
status: done
owner: implementer-1
depends_on: [2]
created: 2026-11-15T22:33:55Z
updated: 2026-11-15T23:20:23Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. Add GET /v1/sky?zip=NNNNN. Validate a 5-digit US zip. Geocode with Open-Meteo's geocoding API (name=zip, countryCode=US; cache in KV for 30 days), then fetch the Open-Meteo forecast (current: temperature_2m in Fahrenheit, weather_code, cloud_cover, wind_speed_10m, wind_gusts_10m, is_day; daily: sunrise, sunset, moonrise, moonset, moon_phase; timezone=auto; cache in KV for 15 minutes). Return place name, timezone, and those values. Unknown zip returns 404. Regenerate the OpenAPI spec and Swift client.

## Acceptance criteria

- [x] Route defined with createRoute and Zod; invalid zip returns 400, unknown zip 404
- [x] Tests use recorded Open-Meteo fixtures and cover cache hit and miss
- [x] npm test and npx tsc --noEmit pass; wrangler dev returns live data for a sample zip
- [x] openapi/openapi.json regenerated and the iOS app still builds

## Relevant files

- api/src/routes/sky.ts
- api/src/index.ts
- api/test/
- openapi/openapi.json

## What's been tried


## Log

- 2026-11-15T22:33:55Z [li] created (todo)
- 2026-11-15T23:00:55Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-15T23:10:58Z [implementer-1] Added GET /v1/sky: api/src/routes/sky.ts (createRoute + Zod, named schemas Sky, SkyPlace, SkyCurrent, SkyDay, SkyError; defaultHook gives a plain 400 body) and api/src/lib/open-meteo.ts (geocode + forecast, both upstream bodies safeParsed). Mounted in src/app.ts. KV keys sky:geo:v1:<zip> (30 days) and sky:forecast:v1:<zip> (15 min); failures and unknown zips are not cached.
- 2026-11-15T23:10:58Z [implementer-1] Forecast is requested with timeformat=unixtime (a change from the URL in the brief): the local-time strings all share one utc_offset_seconds, which is wrong across a DST change inside the 2-day window. Times go out as UTC instants with second precision (no fractional seconds, which the Swift client's default date decoding rejects), plus timezone (IANA) and utcOffsetSeconds.
- 2026-11-15T23:10:58Z [implementer-1] Live probes: a missing moonrise/moonset is null upstream (seen for NYC and Utqiagvik). In polar night Open-Meteo does NOT send null for the sun: sunrise and sunset both equal the day's start. The route maps sunrise == sunset to null for both, so sunrise/sunset are nullable too. A zip counts only if it is in the result's postcodes list, otherwise 404.
- 2026-11-15T23:10:58Z [implementer-1] Tests (api/test/sky.test.ts) mock outbound fetch with vi.spyOn(globalThis, 'fetch'), the mechanism the docs give for vitest-pool-workers 0.23.0 (fetchMock was removed); unmatched requests throw. Fixtures in api/test/fixtures recorded 2026-11-15 for zip 10001 and 00000 with the exact URLs the code builds; null-moonset, polar and loose-match cases are derived from them in the test and marked synthetic. Added resolveJsonModule to api/tsconfig.json for the JSON fixtures. KV persists across tests in a file, so keys are deleted in beforeEach.
- 2026-11-15T23:13:25Z [implementer-1] Correction to the DST note, from two more live probes. (1) With timeformat=unixtime the daily day starts are 86400 s apart at today's fixed offset (NYC, past_days=16 across the 1 Nov fall-back: every delta 86400), so they are not true local midnights; days[].date is now read at day start + 12 h in the IANA zone, with a synthetic fall-back test. Sun and moon values are exact instants and unaffected. (2) Midnight sun (lat -80) uses a different sentinel from polar night: sunrise = day start, sunset = next day start. Both cases now map to null sunrise and sunset (sunrise == sunset, or sunset - sunrise >= 86400); the client tells them apart with current.isDay.
- 2026-11-15T23:13:25Z [implementer-1] status: in-progress → review
- 2026-11-15T23:17:58Z [implementer-1] criterion 1 met: Route defined with createRoute and Zod; invalid zip returns 400, unknown zip 404
- 2026-11-15T23:17:58Z [implementer-1] criterion 2 met: Tests use recorded Open-Meteo fixtures and cover cache hit and miss
- 2026-11-15T23:17:58Z [implementer-1] criterion 3 met: npm test and npx tsc --noEmit pass; wrangler dev returns live data for a sample zip
- 2026-11-15T23:17:58Z [implementer-1] criterion 4 met: openapi/openapi.json regenerated and the iOS app still builds
- 2026-11-15T23:17:58Z [implementer-1] review: pass. All four criteria verified by running them: npm test 24/24 and tsc clean; npm run openapi leaves openapi/openapi.json with no diff; wrangler dev gave live data for 10001 and 94103, 400 for 1234 (also repeated param, trailing newline, full-width digits, missing), 404 for 00000 twice (not cached); xcodegen + xcodebuild test on iPhone 16 / iOS 18.3.1 succeeded. Route output for 10001, 94103, 96813, 99501, 99762, 99723 matched Open-Meteo queried directly in local time: every sun and moon instant within the truncated minute, every days[].date equal, null moon times agree. Polar mapping cannot null an ordinary day; no one-sided sentinel seen on transition days (Utqiagvik 15-22 Nov, lat -66..-72). 50 ordinary zips all matched at count=1. No new dependencies, no ios source changes, 60647 absent. Non-blocking notes: (a) some real zips are missing from the geocoder and 404 (82190, 88901, Puerto Rico 00901); (b) forecast cache is keyed by zip, so days[0] can be yesterday for up to 15 min after local midnight and zips of one city refetch the same coordinates; (c) sunset after local midnight (far-west Alaska in June) could not be probed in November, task 4 should not assume sunset falls inside days[i].date.
- 2026-11-15T23:19:44Z [implementer-1] review: follow-up to (c), now probed. With a zone about 3-5 h ahead of solar time (lat -64..-67.5, lon 0, explicit timezone) Open-Meteo reports a sunset after local midnight as a real instant later than the next day's start, paired with that day's sunrise (day length up to 23.2 h); the route passes it through and does not null it. So days[i].sunset can fall on the next local date (far-west Alaska in June); task 4 should place the sun from the instants, not assume sunset is inside days[i].date. Also: the live-path evidence is 94103, 96813, 99501, 99762, 99723; the 10001 response was identical to the fixture and may have come from local KV left by the implementer.
- 2026-11-15T23:20:23Z [implementer-1] status: review → done
