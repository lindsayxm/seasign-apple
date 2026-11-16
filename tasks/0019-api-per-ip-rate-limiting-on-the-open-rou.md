---
id: 19
title: API: per-IP rate limiting on the open routes, and deployment limits
status: review
owner: implementer-1
depends_on: [7]
created: 2026-11-16T03:45:09Z
updated: 2026-11-16T16:10:45Z
---

## Goal

The plan calls for a per-client-IP rate limit on the routes that need no account (/v1/sky, /v1/calendar/events, /v1/sites/resolve, /v1/feed, later /v1/discover); it is not built. Choose the mechanism from current Cloudflare docs (the Workers Rate Limiting binding is the likely fit; it is configured in api/wrangler.jsonc and creates no separate resource) and ask the user before adding anything that is a new service. Also record the deployment constraints found so far: /v1/feed needs the Workers Paid plan (CPU time and subrequest count), and consider limits.cpu_ms. Must be done before any deploy.

## Acceptance criteria

- [ ] Each open route returns 429 with a fixed body past its limit, with tests
- [ ] The plan requirement and chosen limits are recorded in memory/decisions/

## Relevant files

- api/src/app.ts
- api/wrangler.jsonc
- api/test/
- memory/decisions/

## What's been tried


## Log

- 2026-11-16T03:45:09Z [li] created (backlog)
- 2026-11-16T15:59:36Z [li] User approved (2026-11-16) using Cloudflare's Workers Rate Limiting binding for this task.
- 2026-11-16T15:59:36Z [li] status: backlog → todo
- 2026-11-16T15:59:36Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-16T16:04:27Z [implementer-1] Docs read 2026-11-16 via cloudflare-docs MCP: https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/ (last updated 2026-11-12): wrangler.jsonc key "ratelimits": [{ name, namespace_id (string holding a positive integer, unique in the account; bindings sharing it share counters), simple: { limit, period } }]; period must be 10 or 60; limit() takes { key, delta? } and resolves { success }; a refused call does not add to the count; counts are per Cloudflare location and approximate/eventually consistent (each check uses a local cached count, synced in the background, so a burst can pass more than the limit; other locations count separately; strict limits need a Durable Object); docs advise against IP keys because mobile carriers/proxies share IPs. Wrangler >= 4.36 (we have 4.162). https://developers.cloudflare.com/workers/local-development/ : rate limiting is local-only in dev. Miniflare in node_modules (vitest-plugin and wrangler) ships a real local implementation: a SQLite Durable Object per namespace, fixed windows aligned to the wall clock, exact counts. Pricing: neither the binding page nor https://developers.cloudflare.com/workers/platform/pricing/ (updated 2026-11-13) states a price or plan requirement for the binding (docs silent as of 2026-11-16). Limits: https://developers.cloudflare.com/workers/platform/limits/ (Free 10 ms CPU, 50 subrequests/request; Paid 5 min CPU max, 10,000 subrequests default) and https://developers.cloudflare.com/workers/wrangler/configuration/#limits (cpu_ms max 300,000; default 30,000 per the limits page; only Standard usage model; not enforced locally). CF-Connecting-IP: https://developers.cloudflare.com/fundamentals/reference/http-headers/ (cross-zone Worker subrequests arrive as 2a06:98c0:3600::103).
- 2026-11-16T16:09:42Z [implementer-1] Limits (RATE_LIMITS in api/src/lib/rate-limit.ts = ratelimits in api/wrangler.jsonc; all per 60 s, per client key, per Cloudflare location). How the app calls (ios/Seasign, read only): TodayModel.refreshInterval 10 min (sky, checked on a 60 s loop and on foreground; plus one call per zip typed in Settings); EventsModel.refreshInterval 10 min (calendar, same loop; plus one call per link added); FeedModel.refreshInterval 15 min (feed at launch/foreground; resolve once per site added); discover: DailyCap 1-20/day (default 3), automatic searches spaced >= 24h/cap, Search now ignores spacing but not the cap. So one person normally sends at most ~1 request per route per 10-15 min. Headroom is mainly for carrier-grade NAT (many phones share one IPv4; the binding docs warn about IP keys) and for bursts while editing settings. sky 60: cheap (KV cached, upstream only on a miss), ~600 phones behind one IPv4 at the 10-min cadence. calendar 20: up to 10 outbound fetches and up to ~3.5 s CPU worst case per request. feed 15: up to 50 sites with redirects, ~10 s CPU worst case by arithmetic; called least often (15 min). resolve 10: only when adding a site; 10 adds a minute is more than any person types. discover 5: relays the user's paid key and its 401 is a key-checking oracle; a person is capped at 20/day on the phone. period can only be 10 or 60, so the lowest possible discover limit still allows thousands per IP per day; see the decision file.
- 2026-11-16T16:09:42Z [implementer-1] Design: middleware rateLimit(group) in api/src/lib/rate-limit.ts, registered in app.ts per path before the 64 KB body cap (a mutation check moving it after the cap fails the bodyUsed assertions). Key: CF-Connecting-IP only (X-Forwarded-For ignored); IPv4 whole address; IPv6 its /64 ('6:2001:db8:a:b::/64'), IPv4-mapped IPv6 as IPv4; anything unparsable used raw, cut to 64 chars. No CF-Connecting-IP: not limited, one log line per isolate (Cloudflare sets it on every internet request and wrangler dev sets it to the local address; the vitest exports.default.fetch path has none, which is why the existing suites, hundreds of requests each, are not throttled; a test proves it with 11 header-less discover requests). Missing binding: served, logged once. limit() throws or returns something without success:false: served, fixed line 'rate-limit: <group> limiter failed; request served' each time. Over: 429 {error:'rate_limited', message:'Too many requests from this network; try again in a minute'}, Retry-After: 60, Cache-Control: no-store. The address is never logged or returned.
- 2026-11-16T16:10:45Z [implementer-1] Verified: npx tsc --noEmit clean; npm test 3 runs, 16 files / 1613 tests passed each time (48 new in test/rate-limit.test.ts); npm run openapi regenerated openapi/openapi.json (429 + Retry-After header on sky, calendar, sites, feed; discover 429 description broadened, Retry-After declared not required; rate_limited added to SkyError, CalendarError, SitesError, FeedError enums). Real local binding: Miniflare implements it, tests burst 2x limit+1 per group through it. npx wrangler dev --port 8788 listed the five bindings as local; 70 x GET /v1/sky?zip=abc gave 60 x 400 then 10 x 429 (Retry-After: 60, fixed body); 30 x /v1/health all 200; 7 discover posts gave 5 x 400 then 429; no address in the dev log. Server stopped. iOS (read only): sky/calendar/resolve/feed switch with default: -> .unavailable, so the new .tooManyRequests case compiles and reads as unavailable; discover already maps .tooManyRequests -> .rateLimited. Lead must rerun the iOS build after the spec change.
- 2026-11-16T16:10:45Z [implementer-1] Follow-ups for the lead: (1) iOS: our server-side 429 on discover counts against the phone's daily cap (refundsSearch is only 400/401) and shows 'Your provider is limiting searches right now', which is wrong when it is our limiter; a 429 with Retry-After could be refunded and worded differently. (2) A daily per-IP limit for discover would need a Durable Object or KV counter (binding period max is 60 s). (3) Before deploy: check namespace IDs 19001-19005 are unused in the account; after deploy, the checks listed in memory/decisions/2026-11-16-rate-limits-and-deploy-limits.md (burst test, X-LLM-Key not in logs, measure CPU then set limits.cpu_ms).
- 2026-11-16T16:10:45Z [implementer-1] status: in-progress → review
