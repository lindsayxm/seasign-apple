---
id: 2
title: Decide how location and sun/moon position are computed
status: backlog
owner: 
depends_on: []
created: 2026-11-15T19:03:53Z
updated: 2026-11-15T19:03:53Z
---

## Goal

The Today horizon follows the real sun, moon and weather over Lake Michigan. Decide: is the location fixed (Lake Michigan) or the user's (CoreLocation, with a permission prompt and usage string); and are sun/moon positions computed on the device or returned by the API. Record the choice and add it to STACK.

## Acceptance criteria

- [ ] The user has chosen fixed or user location
- [ ] Decision file exists in memory/decisions/ covering location and sun/moon calculation
- [ ] STACK in AGENTS.md is updated

## Relevant files

- AGENTS.md
- BUILD.md
- memory/decisions/

## What's been tried


## Log

- 2026-11-15T19:03:53Z [lead] created (backlog)
