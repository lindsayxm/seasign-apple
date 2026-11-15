---
id: 3
title: API: GET /v1/sky (zip to weather, sun and moon)
status: todo
owner: 
depends_on: [2]
created: 2026-11-15T22:33:55Z
updated: 2026-11-15T22:33:55Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. Add GET /v1/sky?zip=NNNNN. Validate a 5-digit US zip. Geocode with Open-Meteo's geocoding API (name=zip, countryCode=US; cache in KV for 30 days), then fetch the Open-Meteo forecast (current: temperature_2m in Fahrenheit, weather_code, cloud_cover, wind_speed_10m, wind_gusts_10m, is_day; daily: sunrise, sunset, moonrise, moonset, moon_phase; timezone=auto; cache in KV for 15 minutes). Return place name, timezone, and those values. Unknown zip returns 404. Regenerate the OpenAPI spec and Swift client.

## Acceptance criteria

- [ ] Route defined with createRoute and Zod; invalid zip returns 400, unknown zip 404
- [ ] Tests use recorded Open-Meteo fixtures and cover cache hit and miss
- [ ] npm test and npx tsc --noEmit pass; wrangler dev returns live data for a sample zip
- [ ] openapi/openapi.json regenerated and the iOS app still builds

## Relevant files

- api/src/routes/sky.ts
- api/src/index.ts
- api/test/
- openapi/openapi.json

## What's been tried


## Log

- 2026-11-15T22:33:55Z [li] created (todo)
