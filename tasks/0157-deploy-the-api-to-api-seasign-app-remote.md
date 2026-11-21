---
id: 157
title: Deploy the API to api.seasign.app: remote D1 and KV, migration, custom domain, APNs secrets, app base URL per build configuration
status: backlog
owner: 
depends_on: [156]
created: 2026-11-20T22:28:10Z
updated: 2026-11-20T22:28:10Z
---

## Goal

Plan plans/2026-11-19-google-calendar-push.md, task D. Put the Worker on https://api.seasign.app so Google can call the webhook and the app can reach the API from outside this Mac. Run by the lead with the user present: every command that creates a resource, touches remote data, deploys or sets a secret is announced and approved first (AGENTS.md). Pre-deploy list: memory/decisions/2026-11-16-rate-limits-and-deploy-limits.md.

## Acceptance criteria

- [ ] Before anything is created (cloudflare-api MCP, read only, and cloudflare-docs): the account is on Workers Paid (needed by /v1/feed and /v1/calendar/events), or the user upgrades it; price or plan need of the Rate Limiting binding rechecked; rate-limit namespace IDs 19001-19007 are unused in the account; seasign.app is a zone in the same account with no record at api
- [ ] With the user's go-ahead for each: wrangler d1 create seasign and wrangler kv namespace create; the real IDs replace the placeholders in api/wrangler.jsonc; routes entry for api.seasign.app with custom_domain true; wrangler d1 migrations apply seasign --remote creates calendar_channels; npm test and tsc still pass
- [ ] The user types the three secrets themselves (wrangler secret put APNS_KEY, APNS_KEY_ID, APNS_TEAM_ID); the agent never sees the key file or its text; wrangler secret list shows the three names
- [ ] wrangler deploy with the user's go-ahead; https://api.seasign.app/v1/sky?zip=60611 answers 200 over a valid certificate
- [ ] Post-deploy checks 1-3 of the decision file: a burst to /v1/sky?zip=abc gets 429 with Retry-After 60; observability and logs record no X-LLM-Key, X-Google-Token, X-Goog-Channel-Token or calendar link; a tokenless POST from the deployed Worker to the APNs sandbox answers 403 MissingProviderToken (if the Worker cannot reach APNs, stop and tell the user: a relay would be a new service). Any temporary probe route is removed and redeployed
- [ ] iOS: the API base URL comes from the build configuration (Debug keeps http://localhost:8787, Release uses https://api.seasign.app) through project.yml and Info.plist, with a launch argument or setting to point a Debug build at the deployed API; xcodegen generate; xcodebuild test passes on both runtimes; a Simulator run against the deployed API shows sky and events
- [ ] Results written to the decision file; PROJECT-STATUS and AGENTS.md STACK say what is deployed and where

## Relevant files

- api/wrangler.jsonc
- ios/project.yml
- ios/Seasign/API/SeasignAPI.swift
- memory/decisions/2026-11-16-rate-limits-and-deploy-limits.md

## What's been tried


## Log

- 2026-11-20T22:28:10Z [li] created (backlog)
