---
id: 203
title: Add the X API MCP server (https://api.x.com/mcp) to the project's MCP servers
status: review
owner: li
depends_on: []
created: 2026-11-24T03:15:33Z
updated: 2026-11-24T03:17:11Z
---

## Goal

Claude Code sessions in this project can use X's hosted MCP server.

## Acceptance criteria

- [x] .mcp.json has the server and .claude/settings.json enables it; both files parse
- [x] AGENTS.md TOOLS lists it, with ask-before-posting

## Relevant files

- .mcp.json
- .claude/settings.json
- AGENTS.md

## What's been tried


## Log

- 2026-11-24T03:15:33Z [li] created (todo)
- 2026-11-24T03:15:37Z [li] status: todo → in-progress — claimed by li
- 2026-11-24T03:17:04Z [li] criterion 1 met: .mcp.json has the server and .claude/settings.json enables it; both files parse
- 2026-11-24T03:17:04Z [li] criterion 2 met: AGENTS.md TOOLS lists it, with ask-before-posting
- 2026-11-24T03:17:05Z [li] Added x-api (http, https://api.x.com/mcp) to .mcp.json and enabledMcpjsonServers; not in permissions.allow, so calls prompt. AGENTS.md TOOLS row and a decision record added. Endpoint answers 401 + OAuth metadata; no registration_endpoint, so sign-in may need a client ID from the user's X developer app. Sign-in itself not tested (needs an interactive session).
- 2026-11-24T03:17:11Z [li] status: in-progress → review
