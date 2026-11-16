# User decisions, 2026-11-16

Decided by the user during the 2026-11-16 session. Implementation detail is in `memory/architecture.md`.

| topic | decision | reason | rejected |
|---|---|---|---|
| Event times | Follow the phone's 24-hour setting (task 23) | The user asked for it | Always 12-hour |
| Calendar link that fails | That calendar's last known events stay on Today while its link temporarily fails (already built in task 6; kept) | A brief network failure should not empty the screen | Dropping the events on any failure |
| AI headlines on Today | "Every other": AI-found headlines alternate with headlines from the user's own sites (task 23) | AI results should be blended in with what the user chose, not grouped or ranked above it | Ranking purely by date; AI items in a block |
| Rate limiting | Workers Rate Limiting binding, per client IP, on the open `/v1` routes (task 19). Detail in `2026-11-16-rate-limits-and-deploy-limits.md` | Approved by the user as the mechanism | KV counters |
| Default zip | A fresh install starts with zip 60611 (Chicago). Written only when the settings row is first created, so a zip the user changes or removes stays as they left it (task 25) | Today shows a real sky before any setup | No default (neutral scene until a zip is typed) |
| Models | Lead session on Fable 5.2; `implementer` and `reviewer` on Opus 5.5 (`.claude/settings.json`, `.claude/agents/`) | The user's choice | |

Still open with the user: move calendar links from SwiftData to the Keychain (the lead recommends yes); whether titles of private events should be hidden.
