---
id: 157
title: Deploy the API to api.seasign.app: remote D1 and KV, migration, custom domain, APNs secrets, app base URL per build configuration
status: todo
owner: 
depends_on: [156]
created: 2026-11-20T22:28:10Z
updated: 2026-11-22T04:02:51Z
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
- 2026-11-21T13:53:28Z [li] status: backlog → todo
- 2026-11-21T13:53:28Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-21T13:53:49Z [lead] Lead: read-only pre-deploy checks (cloudflare-api MCP, 2026-11-21). One account. seasign.app is an active zone in it (Free website plan), with zero DNS records, so api.seasign.app is free. The account has no Workers, no D1 databases and no KV namespaces, so rate-limit namespace IDs 19001-19007 cannot clash. Workers plan NOT determined: the subscriptions endpoint answers 403 for this connection; account settings show default_usage_model standard, which does not prove Paid. Ask the user to confirm Workers Paid (5 USD a month minimum) in the dashboard before deploy. Rate Limiting binding: docs still give no separate price (binding page dated 2026-11-12, pricing page); GA since 2025-09-19. Worker fetch to APNs over HTTP/2: docs still silent; stays a post-deploy check. Nothing was created or changed.
- 2026-11-21T14:07:02Z [lead] Lead: carry into the deploy round (small API follow-ups from the #159 review, none blocking): the watch 500 text 'nothing was changed' is untrue when the batch commits and then throws (earlier channels are deleted but not stopped; fixing the text changes the spec); optionally race the APNs provider-token await against the 3 s deadline (apns.ts about 228); decision-record nit: after a commit-then-throw the sweep did run.
- 2026-11-22T03:11:34Z [lead] Lead: for distribution (from the #158 review): the entitlement is aps-environment development while Release builds send environment production. A TestFlight/App Store build is re-signed with production and is fine; a Release build run from Xcode with development signing would send production with a sandbox device token, and pushes fail silently. When a distribution task is created, add a check or derive the environment from the embedded entitlement.
- 2026-11-22T04:02:51Z [lead] Lead: user, 2026-11-21: 'we are not ready to deploy - i want to add more features first - please put the deploy tasks in to do for now'. Released to todo. The read-only pre-deploy findings and the follow-up notes above stand. The user has no Workers Paid plan; a Free-plan deploy was discussed (push routes fit; /v1/feed and large pasted calendars likely exceed 10 ms CPU; KV 1,000 writes a day) and not decided.
- 2026-11-22T04:02:51Z [lead] status: in-progress → todo
