---
id: 1
title: Decide the weather source for the Today screen
status: backlog
owner: 
depends_on: []
created: 2026-11-15T19:03:53Z
updated: 2026-11-15T19:03:53Z
---

## Goal

BUILD.md shows temperature and weather on the Today horizon, but STACK names no weather source. Choose between WeatherKit on the device (needs paid Apple Developer Program membership and the WeatherKit capability, which is an 'ask the user first' change) and a weather API called from the Worker and cached in KV (keeps logic in the API for a later Android client). Record the choice in memory/decisions/ and add it to STACK in AGENTS.md.

## Acceptance criteria

- [ ] The user has chosen the source
- [ ] Decision file exists in memory/decisions/
- [ ] STACK in AGENTS.md names the weather source

## Relevant files

- AGENTS.md
- BUILD.md
- memory/decisions/

## What's been tried


## Log

- 2026-11-15T19:03:53Z [lead] created (backlog)
