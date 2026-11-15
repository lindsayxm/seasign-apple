---
id: 5
title: Upgrade Xcode and reconsider Apple's Xcode MCP server
status: backlog
owner: 
depends_on: []
created: 2026-11-15T19:03:54Z
updated: 2026-11-15T19:03:54Z
---

## Goal

This Mac has Xcode 16.2 (iOS 18.3 Simulator), which is enough to build and run in the Simulator. Before any TestFlight or App Store upload, check Apple's current minimum Xcode/SDK for submissions and upgrade if 16.2 is below it. Once Xcode is 26.3 or later, decide whether to add Apple's MCP server (xcrun mcpbridge); see memory/decisions/2026-11-15-ios-mcp-servers.md. The user installs Xcode; agents do not.

## Acceptance criteria

- [ ] Apple's current submission requirement is recorded in the task log with its source
- [ ] Xcode is at or above that version, or the user has chosen to wait
- [ ] AGENTS.md states the installed Xcode and Simulator versions
- [ ] The decision on Apple's MCP server is recorded in memory/decisions/

## Relevant files

- AGENTS.md
- .mcp.json
- memory/decisions/2026-11-15-ios-mcp-servers.md

## What's been tried


## Log

- 2026-11-15T19:03:54Z [lead] created (backlog)
