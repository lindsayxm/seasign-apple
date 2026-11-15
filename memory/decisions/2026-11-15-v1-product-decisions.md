# 2026-11-15 — v1 product and stack decisions

Made by the user in the planning session. The full plan is `plans/2026-11-15-v1-build.md`.

## Calendars: pasted links, not device calendars

- **Decision.** The user pastes calendar links in Settings: Google's "Secret address in iCal format", an Apple published calendar link, an Outlook published link. The Worker fetches each `.ics`, parses it with `ical.js` and expands repeating events.
- **Why.** One code path for all three providers, it lives in the API so an Android client can reuse it, and the app needs no calendar permission.
- **Rejected.** EventKit (iOS only, permission prompt). A Google service account the user shares their calendar with (needs a Google Cloud project and a stored key; some work accounts block outside sharing). OAuth sign-in to Google and Microsoft (app verification, token storage).
- **Known limits.** Apple can publish only iCloud calendars, and a published one is public to anyone with the link. Outlook published links can lag by hours. A Google secret link grants read access to whoever holds it, so links are never logged and KV keys are hashes.

## Signed-out use: device only until sign-in

- **Decision.** The app works without an account. Lists, sites, calendar links, saved items and settings live in SwiftData. Signing in with Apple later uploads them to D1 and turns on sync. v1 routes need no account.
- **Why.** The user wants no sign-in wall, and the Apple Developer account is not approved yet, so Sign in with Apple cannot be built or tested now.
- **Rejected.** A silent anonymous account in D1 from first launch.
- **Consequence.** The Cron morning refresh waits for sync, because the server does not know a signed-out user's sites. The daily AI-search cap is counted on the device.

## Followed sites and the feed

- **Decision.** The user enters a page URL plus a category they name. The Worker uses the page's advertised RSS/Atom feed (`fast-xml-parser`) and falls back to reading article links from the HTML (`HTMLRewriter`). Today shows only the newest headlines that fit and does not scroll. `>>` opens a 7-day history of everything that was in the feed; the asterisk opens Saved. The reading view shows the site's own excerpt and a link to the original.
- **Rejected.** RSS only (some sites would not work). Full-text extraction in the reading view (paywalls, copyright, App Store risk).

## AI search

- **Decision.** Settings holds an LLM API key, comma-separated interests, a max-searches-per-day cap and the pill toggle "Use My List / Let AI Search". v1 supports Anthropic, OpenAI, Google Gemini and Perplexity, one adapter each, using the provider's web search. The key is stored only in the Keychain and sent per request to the Worker, which never stores or logs it. AI-found items are labelled in the feed.
- **Why.** Search logic stays in the API for Android; the label keeps the BUILD.md promise that nothing is chosen by an algorithm the user cannot see.
- **Rejected.** Calling providers straight from the phone (logic would be rewritten for Android). Storing keys in D1 (we would hold users' keys).

## App identity

- **Decision.** `app-identity.xcconfig` at the repository root holds `APP_BUNDLE_ID` and `DEVELOPMENT_TEAM`, with test values (`com.example.seasign`, empty team) until the developer account is approved. `ios/project.yml` loads it; `api/wrangler.jsonc` repeats the bundle ID and a check in `npm test` keeps them equal.
- **Why this file type.** The hooks block `.env*` and `*.toml`, and Xcode reads `.xcconfig` natively.

## Other

- Location is a 5-digit US zip typed in Settings; Open-Meteo's geocoder returns the place and timezone. No location permission.
- Do/Get is one screen with DO on top and GET below.
- New dependencies approved with the plan: `ical.js`, `fast-xml-parser`, and two bundled open-licence fonts (Jost, plus a condensed bold face for the day name).
- Not in v1: voice input, Siri/Shortcuts, widget, notifications, AI summaries.
- `ref-img/` is committed in full, including the 95 MB design-system PDF.
