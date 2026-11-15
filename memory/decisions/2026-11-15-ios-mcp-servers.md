# 2026-11-15 — MCP servers for iOS work

## Decision

- **XcodeBuildMCP** (`npx -y xcodebuildmcp@latest mcp`) for building, testing, Simulator control, screenshots and UI automation.
- **sosumi** (`https://sosumi.ai/mcp`) for Apple developer documentation, the Human Interface Guidelines and WWDC transcripts.

Both are defined in `.mcp.json`. The Svelte server from the earlier SvelteKit stack was removed.

## Why

- Apple's own Xcode MCP server (`xcrun mcpbridge`) needs Xcode 26.3 or later. This Mac has Xcode 16.2, where the tool does not exist.
- XcodeBuildMCP works with Xcode 16 and covers what the lead and subagents need to check UI work in the Simulator.
- Apple publishes no documentation MCP server for Xcode 16, and developer.apple.com pages need JavaScript, so plain web fetches often fail. sosumi returns the same pages as Markdown.

## Configuration notes

- XcodeBuildMCP telemetry is off (`XCODEBUILDMCP_SENTRY_DISABLED=true`).
- Its workflows are limited with `XCODEBUILDMCP_ENABLED_WORKFLOWS` to simulator, simulator-management, ui-automation, project-discovery, utilities, debugging, coverage and swift-package. The `device` workflow is left out because installing on a physical device is on the "ask the user first" list; `project-scaffolding` is left out because the project is generated with XcodeGen.
- Both servers are third-party. `.mcp.json` runs `xcodebuildmcp@latest`; pin a version there if a release misbehaves.

## Revisit

When Xcode is upgraded to 26.3 or later, consider adding Apple's server (`claude mcp add --transport stdio xcode -- xcrun mcpbridge`, plus the MCP toggle in Xcode's Intelligence settings). It adds SwiftUI preview rendering and Apple's own documentation search.
