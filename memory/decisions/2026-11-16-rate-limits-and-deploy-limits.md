# 2026-11-16 — rate limits on the open routes, and Workers plan limits for deploy (task 19)

The plan (`plans/2026-11-15-v1-build.md`, "Rules for these open endpoints") requires a per-client-IP rate limit on the routes that need no account. This file records how it is built, the numbers, and the deployment constraints found so far. Docs were read on 2026-11-16 through the cloudflare-docs MCP server.

## Mechanism: the Workers Rate Limiting binding

- **Decision.** One `ratelimits` binding per route group in `api/wrangler.jsonc`, checked by `rateLimit(group)` in `api/src/lib/rate-limit.ts`. The user approved this binding on 2026-11-16. Declaring the bindings creates no cloud resource.
- **Source.** https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/ (page dated 2026-11-12). Config is `{ name, namespace_id, simple: { limit, period } }`. `namespace_id` is a string holding a positive integer, unique in the Cloudflare account; bindings that share one also share counters. `period` must be 10 or 60. `limit({ key })` resolves `{ success }`, and a refused call does not add to the count.
- **Approximate and per location.** Counts are kept separately in each Cloudflare location, and each location's count is eventually consistent: a check reads a locally cached count and the count is synced in the background. So a burst can get past a limit, and a client reaching several locations gets each location's allowance. A strict limit would need a Durable Object. Our limits slow abuse and cap cost; they are not exact quotas.
- **Price.** Neither the binding page nor https://developers.cloudflare.com/workers/platform/pricing/ (dated 2026-11-13) gives a price or plan requirement for the binding. Recheck before deploy.
- **Namespace IDs** are 19001 to 19007 (19006 is the `google` group, 19007 the `notify` group, both added 2026-11-19). Before the first deploy, check that no other Worker in the account uses them.

## The limits

All limits count requests per client per 60 seconds per location. They are in `RATE_LIMITS` (`api/src/lib/rate-limit.ts`) and in `api/wrangler.jsonc`, and a test fails if the two differ.

| group | route | limit / 60 s | why |
|---|---|---|---|
| sky | `GET /v1/sky` | 60 | Cheap: KV-cached, with an upstream call only on a cache miss. The app asks at most every 10 minutes (`TodayModel.refreshInterval`), plus one call per zip typed in Settings. |
| calendar | `POST /v1/calendar/events` | 20 | Up to 10 outbound fetches and up to about 3.5 s of CPU per request in the worst case. The app asks at most every 10 minutes (`EventsModel.refreshInterval`), plus one call per link added. |
| feed | `POST /v1/feed` | 15 | Up to 50 sites, each with redirects; about 10 s of CPU in the worst case (estimated, not measured). The app asks at most every 15 minutes (`FeedModel.refreshInterval`). |
| resolve | `POST /v1/sites/resolve` | 10 | Used only while the user adds a site. |
| discover | `POST /v1/discover` | 5 | Relays the user's paid key, and its 401 tells a caller whether a key works. The phone caps searches at 1 to 20 a day (`DailyCap`). |
| google | `GET /v1/google/calendars`, `POST /v1/google/events`, `POST /v1/google/watch`, `POST /v1/google/unwatch` | 600 | Added 2026-11-19 (tasks 153, 155). Until push exists the app polls events every 5 s while Today is open (12 a minute a phone), so 600 allows about fifty phones behind one shared address. A request is cheap for us (short JSON, at most 10 calendars of 4 pages, no KV) and spends the caller's own Google quota; a bad token costs one 401 per calendar. Revisit once push replaces polling. |
| notify | `POST /v1/google/notify` (Google's webhook) | 1200 | Added 2026-11-19 (task 156). The callers are Google's servers, which every channel shares, so a limit sized for one phone would refuse Google itself; `app.ts` sends this path to its own group instead of `google`. 1200 a minute per address per location is far above one notification per calendar edit at this scale. A refused call is a lost wake-up, not lost data: Google retries only some 5xx answers, and the app reloads when it opens. A forged call costs a header check, or one D1 read by primary key when its channel id has our UUID shape, and cannot cause a push without the 256-bit channel token. Revisit if real traffic nears it. |

**Why the headroom is large.** One person sends about one request per route every 10 to 15 minutes. The headroom covers carrier-grade NAT, where many phones share one IPv4 address (the binding docs advise against IP keys for this reason), and bursts while the user edits settings. For example, sky at 60 a minute allows about 600 phones behind one address at the app's cadence.

## Key, failure handling and privacy

- **Key.** The key is the `CF-Connecting-IP` header only; `X-Forwarded-For` is never used. An IPv4 address is used whole. An IPv6 address is cut to its /64, so one host cannot step through its own addresses to escape the limit. An IPv4-mapped IPv6 address counts as the IPv4 address.
- **No `CF-Connecting-IP`.** The request is served without a limit, and nothing is logged.
  - A log line here would show up in the existing tests that assert a route's exact log lines, and would make them depend on test order.
  - We assume Cloudflare sets the header on every request from the internet. The docs page (https://developers.cloudflare.com/fundamentals/reference/http-headers/) describes the header on edge-to-origin traffic and Worker subrequests, not on requests arriving at a Worker, so this is not confirmed. Post-deploy check 1 confirms it; until then the limiter is unproven in production.
  - `wrangler dev` sets the header to the local address.
  - The vitest `exports.default.fetch` path sends no such header, so the existing suites, which send hundreds of requests, are not throttled.
  - A cross-zone subrequest from another Worker arrives as `2a06:98c0:3600::103`, so all such callers share one bucket.
  - The header could still be missing if a zone rule removed it: the "Remove visitor IP headers" Managed Transform, or a request header rule. Do not enable either on the zone that serves the Worker.
- **Binding missing from the environment.** The request is served and one line is logged per isolate.
- **`limit()` throws.** The request is served and a fixed line is logged, without the address. Only an explicit `success: false` refuses a request.
- **Fail-closed for discover?** For a missing binding, fail-closed would be defensible on discover: the limiter is its only server-side brake, and the app already handles a 429 there. We kept fail-open everywhere for these reasons:
  - The test that compares the binding config with `RATE_LIMITS` makes a missing binding unlikely.
  - Failing closed would turn a config slip into an outage of a feature that costs us almost nothing to serve. The user pays the provider, and a request uses one subrequest and little CPU.
  - The bigger gap is the window: the shortest period is 60 s, so even 5 a minute allows about 7,200 key checks per address per location per day. A daily limit needs a Durable Object or KV counter. That is a follow-up, not part of this task.
- **Privacy.** The address is never logged and never put in a response. Only the limiter's key contains it.
- **Response.** Past a limit, the Worker answers 429 `{ "error": "rate_limited", "message": "Too many requests from this network; try again in a minute" }` with `Retry-After: 60` and `Cache-Control: no-store`. The 429 is declared on every limited route, and `rate_limited` was added to each route's error enum. On discover, this 429 has the same shape as the provider-limit 429 that already existed; `Retry-After` is declared there but not required, because a provider 429 does not carry it.

## Workers plan limits (deployment constraints)

From https://developers.cloudflare.com/workers/platform/limits/ (read 2026-11-16):

| | Workers Free | Workers Paid |
|---|---|---|
| CPU time per request | 10 ms | 5 min (default 30 s) |
| Subrequests per request | 50 | 10,000 (up to 10M) |
| Subrequests to Cloudflare services | 1,000 | matches the configured limit |
| Memory | 128 MB | 128 MB |

Each hop in a redirect chain counts as a subrequest.

- **The Workers Paid plan is required.**
  - `/v1/feed` does not fit the Free plan: parsing one ordinary feed takes more than 10 ms, and 50 sites with redirects pass 50 subrequests.
  - `/v1/calendar/events` does not fit either: one large calendar takes up to about 0.35 s of CPU to read.
- **`limits.cpu_ms`.** https://developers.cloudflare.com/workers/wrangler/configuration/#limits says it applies only on the Standard usage model (Paid), can be at most 300,000, and is not enforced in local development. The default is 30,000 ms. We do not set it yet. The only whole-request figure we have is an estimate: about 10 s for a feed request of 50 worst-case sites, and about 3.5 s for 10 worst-case calendars, both well under the 30 s default. Picking a lower cap now would be guessing.
  - Recommendation: after the first deploy, read real per-request CPU in Workers observability, then set `cpu_ms` to about twice the largest honest figure.
  - Also consider a Workers spending limit (https://developers.cloudflare.com/workers/platform/pricing/, "Control usage costs").
  - Rough cost of abuse within the limits: 15 worst-case feed requests a minute is about 150 CPU-seconds per minute per address per location. That is roughly $0.20 an hour at $0.02 per million CPU ms, so many addresses would be needed for real cost.
- **Calendar memory.** The calendar path can need up to 112 MB on a hostile 2 MB file (task 18). The isolate limit is 128 MB.

## Checks after the first deploy

1. **Rate limits.** Send a burst to the deployed `/v1/sky?zip=abc` from one machine and confirm 429s with `Retry-After: 60`. This checks that `CF-Connecting-IP` arrives and the binding works in production, which local runs cannot prove.
2. **Observability and logs.** Open Workers observability and logs, including request traces and any recorded headers, and confirm that neither the `X-LLM-Key` nor the `X-Google-Token` header (added 2026-11-19) is recorded; originally: confirm that the `X-LLM-Key` header and calendar links are not recorded anywhere (`"observability": { "enabled": true }` is set in `wrangler.jsonc`). Confirm also that no client address appears beyond what Cloudflare itself shows.
3. **APNs from the Worker (task 156).** Send one background push from the deployed Worker (or a tokenless POST to `https://api.sandbox.push.apple.com/3/device/<64 zeros>`, which should answer 403 `{"reason":"MissingProviderToken"}`). APNs speaks only HTTP/2; Cloudflare's docs do not say whether a Worker's `fetch` uses HTTP/2 to an outside host, and the local runtime does not (its fetch to APNs fails with "Network connection lost", while curl over HTTP/2 gets the 403). Also confirm that `X-Goog-Channel-Token` is not recorded by observability, like `X-Google-Token`.
4. **Unexplained 429s.** If honest users get 429s behind a shared address, raise the limit in both places: `RATE_LIMITS` and `wrangler.jsonc`.
