# 2026-11-23 — X API MCP server

## Decision

The user asked for X's hosted MCP server, `https://api.x.com/mcp`, to be added. It is in `.mcp.json` as `x-api` (type `http`) and enabled in `.claude/settings.json` (`enabledMcpjsonServers`).

## Configuration notes

- It is not in `permissions.allow`, the same as `cloudflare-api`: the server's scopes include posting, direct messages, blocks and lists, so each call prompts. Agents read freely and ask before posting or changing anything (AGENTS.md, TOOLS).
- The server answers 401 without a token and points to OAuth at `https://api.x.com` (authorize at `https://x.com/i/oauth2/authorize`, PKCE S256, public clients allowed).
- Checked on 2026-11-23: the authorization server's metadata lists no `registration_endpoint`, so a client cannot register itself. If sign-in through `/mcp` fails for that reason, the entry needs the client ID of an app from the user's X developer account (an `oauth.clientId` field on the entry). A client secret never goes in `.mcp.json`, which is checked in.
- Nothing in the app uses X; this server is for Claude Code sessions only.
