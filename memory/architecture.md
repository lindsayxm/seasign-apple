# Architecture

Kept current by the lead session. The STACK section of `AGENTS.md` lists the chosen libraries; this file says how the parts fit together.

## Shape

```
iPhone app (ios/)  ──HTTPS, JSON──▶  API on Cloudflare Workers (api/)  ──▶  D1 (users, lists, follows)
   SwiftUI + SwiftData                  Hono + Zod + Better Auth        ──▶  KV (fetched news)
        ▲                                        │                      ◀──  Cron Trigger (morning refresh)
        └──── generated Swift client ◀── openapi/openapi.json ◀─────────┘
```

- **Business logic lives in the API** (weather and sun/moon, reading calendar links, fetching followed sites, AI search) so a later Android client can reuse it. The iOS app is UI plus local storage; it uses no location or calendar permission.
- **Signed out by default.** The v1 routes need no account: the app sends what the Worker needs with each request (zip, calendar links, site list, the user's LLM key) and keeps the user's data in SwiftData. Sign in with Apple and D1 sync come last (tasks 13 and 14).
- **User-supplied URLs** go through one safe-fetch helper in the Worker (https only, no private hosts, size and time caps). LLM keys and calendar links are never logged or stored; KV cache keys for calendars are hashes.
- **The OpenAPI spec is the contract.** It is generated from the Hono routes; the Swift client is generated from the spec. Neither is edited by hand.
- **Local first on the phone.** The UI reads SwiftData, then syncs from the API.
- **Auth.** Sign in with Apple on the device → Apple ID token → Better Auth → bearer session token in the Keychain. Every D1 query on user data is scoped by the session's user ID.

## Status

Not scaffolded yet. `api/`, `openapi/` and `ios/` are created by the `scaffold-app` skill (task 2). The v1 plan is `plans/2026-11-15-v1-build.md`; the decisions behind it are in `memory/decisions/2026-11-15-v1-product-decisions.md`.
