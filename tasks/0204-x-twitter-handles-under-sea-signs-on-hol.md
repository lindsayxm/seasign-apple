---
id: 204
title: X (Twitter) handles under SEA SIGNS: on hold until the user decides whether to offer it as a paid feature
status: backlog
owner: 
depends_on: []
created: 2026-11-24T03:23:05Z
updated: 2026-11-24T03:23:05Z
---

## Goal

The user asked on 2026-11-23 to follow a person's X handle (first sentence of each post in the feed, full post in the read view), then put it on hold on learning the X API is paid. Nothing was built. What was found, unconfirmed on X's own pricing page: pay-per-use since February 2026, about 0.005 USD per post read and 0.01 USD per account lookup (third-party guides). From docs.x.com: GET /2/users/by/username/{username}, then GET /2/users/{id}/tweets with an app-only Bearer token, exclude=replies,retweets, max_results 5 to 100. Open questions put to the user and not answered: whose token (a server secret paid by the user as owner, or each user's own), which posts (originals only, reposts, replies), how often to refresh and how many posts per handle (this sets the cost), and how a post looks in the feed and reader. The x-api MCP server in .mcp.json was not loaded in that session.

## Acceptance criteria

- [ ] The user has decided whether to build it; if yes, the four open questions are answered and X's own pricing page has been read

## Relevant files


## What's been tried


## Log

- 2026-11-24T03:23:05Z [li] created (backlog)
