---
id: 3
title: Decide the feed format and fetch path for followed sites
status: backlog
owner: 
depends_on: []
created: 2026-11-15T19:03:53Z
updated: 2026-11-15T19:03:53Z
---

## Goal

Below the waterline the Today screen lists what the sites the user follows published since yesterday, and the app suggests new publications from topics the user sets. STACK says Workers KV caches fetched news with a Cron Trigger refresh, but not what is fetched. Decide: RSS/Atom only or also sites without feeds; how a user adds a site; how topic-based discovery finds publications without an opaque algorithm (BUILD.md requires the user to see and control it). Record the choice.

## Acceptance criteria

- [ ] The user has agreed the feed format and how sites are added
- [ ] The discovery approach is written down and is visible to and controlled by the user
- [ ] Decision file exists in memory/decisions/

## Relevant files

- BUILD.md
- AGENTS.md
- memory/decisions/

## What's been tried


## Log

- 2026-11-15T19:03:53Z [lead] created (backlog)
