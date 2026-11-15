# Architecture

Kept current by the lead session. The STACK section of `AGENTS.md` lists the chosen libraries; this file says how the parts fit together.

## Shape

```
iPhone app (ios/)  ──HTTPS, JSON──▶  API on Cloudflare Workers (api/)  ──▶  D1 (users, lists, follows)
   SwiftUI + SwiftData                  Hono + Zod + Better Auth        ──▶  KV (fetched news)
        ▲                                        │                      ◀──  Cron Trigger (morning refresh)
        └──── generated Swift client ◀── openapi/openapi.json ◀─────────┘
```

- **Business logic lives in the API** (news fetching, summarization, voice-command parsing) so a later Android client can reuse it. The iOS app is UI plus platform integrations (EventKit, Speech, App Intents, notifications).
- **The OpenAPI spec is the contract.** It is generated from the Hono routes; the Swift client is generated from the spec. Neither is edited by hand.
- **Local first on the phone.** The UI reads SwiftData, then syncs from the API.
- **Auth.** Sign in with Apple on the device → Apple ID token → Better Auth → bearer session token in the Keychain. Every D1 query on user data is scoped by the session's user ID.

## Status

Not scaffolded yet. `api/`, `openapi/` and `ios/` are created by the `scaffold-app` skill. Open stack questions (weather source, location and sun/moon, feed format, do/get list storage) are tracked as tasks on the board.
