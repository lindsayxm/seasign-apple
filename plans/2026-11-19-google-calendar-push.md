# Google Calendar with push: events appear as soon as they are added

Date: 2026-11-19. Owner: lead session. Status: **approved by the user on 2026-11-19** ("Ok i approve all of the above": deploy, signing changes, the two new services). Each deploy, remote-resource and secret step is still announced before it is run. Task A is #153.

## Why

The user, 2026-11-19: "we need to switch to using the google calendar api. i want the user to see the calendar event automatically inside the app as soon as it is added on the google side - they shouldnt have to refresh anything." Asked how events should arrive before push is possible: "create the api needed - i got approved for my apple developer account yesterday". Pasted links stay for Apple and Outlook calendars ("Keep both"). The user will create the Google Cloud project and OAuth client.

A pasted iCal link cannot do this: it is a file the Worker fetches, Google never says when it changes, and Google's own feed lags.

## How it works

1. **Sign in with Google on the phone.** Settings gets "Connect Google Calendar". OAuth 2.0 for installed apps with PKCE through `ASWebAuthenticationSession` (AuthenticationServices, already in STACK; no Google SDK). Scope: `https://www.googleapis.com/auth/calendar.events.readonly` plus `calendar.calendarlist.readonly` to list the user's calendars. The refresh token is kept in the Keychain only.
2. **Reading events.** The app sends the short-lived access token to the Worker in a header (`X-Google-Token`), as the LLM key is sent; the Worker calls Google's `events.list` and returns events in the existing `/v1/calendar/events` shape. The token is never stored or logged. Business logic stays in the API (Android can reuse it).
3. **The sensor.** For each chosen calendar the Worker calls Google's `events.watch` with the app's token, naming a webhook on the deployed Worker and a random channel id and token. Google then POSTs to the webhook on every change (the POST carries no event data).
4. **Reaching the phone.** At registration the app also gives the Worker its APNs device token. The Worker stores one small row per channel: channel id → hash of the channel token, APNs device token, expiry. No Google token, no calendar id, no event data is stored. On a webhook POST the Worker checks the channel token and sends a background push (`content-available`) to that device through APNs.
5. **The app refreshes.** On the push (or at once, if the app is open) the app fetches the calendar through step 2 and Today updates. No spinner.
6. **Upkeep.** Channels last at most 7 days and cannot be renewed, only replaced: the app re-registers when it opens and a channel has under 2 days left. Sign-out or "Disconnect" stops the channels (`channels.stop`) and deletes the rows.

This needs no Seasign account: the row is keyed by the channel, not by a user. It is independent of tasks 13 and 14.

## What "as soon as" will mean (limits to tell the user)

- **App open:** a new event shows within a few seconds.
- **App in the background or closed:** iOS decides when to deliver a background push and may delay or drop it (Apple: low priority, not guaranteed, throttled to a few an hour). The app therefore also fetches when it comes to the front, so Today is right by the time it is seen.
- **Google test mode:** until Google verifies the app, at most 100 people can connect, they see an "unverified app" warning, and the sign-in expires every 7 days. Verification is needed before the App Store.
- The pull on the calendar area stays as the fallback.

## Needs the user's approval (AGENTS.md ask-first)

1. **Deploying the API** to Cloudflare (`wrangler deploy`) and creating its remote KV namespace and D1 database. Google can only call a public HTTPS address; nothing is deployed today. The deployed address also replaces `http://localhost:8787` in the app for device builds.
2. **Signing changes:** the real bundle ID and team ID in `app-identity.xcconfig` (now `com.example.seasign`, no team); the Push Notifications capability and the `aps-environment` entitlement; Background Modes → Remote notifications.
3. **Secrets, set by the user, never shown to the agent:** the APNs auth key (`.p8`), its key ID and the team ID, as Worker secrets (`wrangler secret put`, typed by the user). The agent never reads the `.p8`.
4. **New services:** Google Calendar API and Apple Push Notification service. No new packages (plain `fetch`; the APNs token is signed with WebCrypto).
5. **A new D1 table** `calendar_channels` (migration through drizzle-kit).

## The user's setup steps

Apple (developer.apple.com → Certificates, Identifiers & Profiles):
1. Identifiers → `+` → App IDs → App. Choose the bundle ID (for example `com.<yourname>.seasign`), tick **Push Notifications**, register.
2. Keys → `+` → name it, tick **Apple Push Notifications service (APNs)**, register, download the `.p8` once. Note the **Key ID** and your **Team ID** (Membership page).
3. Tell the lead the bundle ID and Team ID (neither is a secret). Keep the `.p8` out of the project folder.

Google (console.cloud.google.com):
1. Create a project. APIs & Services → Library → enable **Google Calendar API**.
2. OAuth consent screen (Google Auth Platform): External, app name, your email; Audience → add yourself as a test user; Data Access → add the scopes `calendar.events.readonly` and `calendar.calendarlist.readonly`.
3. Clients → Create client → **iOS** → the same bundle ID. Copy the **client ID** (not a secret) and give it to the lead.

Cloudflare: nothing to do by hand; the lead asks before each `wrangler` command that creates a resource or deploys, and the user types the three `wrangler secret put` commands.

## Values from the user (2026-11-19; none is a secret)

| value | |
|---|---|
| Bundle ID | `technology.artisan.seasign` |
| Apple Team ID | `Q79NR2FCR9` |
| APNs key ID | `Z9TZFF5FAF` (the key file itself stays with the user, outside the project; it reaches Cloudflare only by the user typing `wrangler secret put`) |
| Google iOS OAuth client ID | `347928684020-vs0cht1ik72su6d4fl4skogak6odtl82.apps.googleusercontent.com` (redirect scheme: `com.googleusercontent.apps.347928684020-vs0cht1ik72su6d4fl4skogak6odtl82`) |
| Cloudflare | the user has an account and is logged in with wrangler on this Mac |
| Deployed address | `workers.dev` to start (the user did not name a domain); revisit if Google requires a verified domain |

The bundle ID and team go into `app-identity.xcconfig` and `api/wrangler.jsonc` in task B (not while task #153 is editing `api/`). A new bundle ID installs as a new app: Settings entered under `com.example.seasign` on any Simulator do not carry over.

## Tasks (to create after approval), in order

| # | task | notes |
|---|---|---|
| A | API: `X-Google-Token` reading of Google calendars in `/v1/calendar/events` (or a sibling route), calendar list route | changes the OpenAPI spec; regenerate the client; local only |
| B | iOS: Google sign-in (PKCE), Keychain, choose calendars in Settings, events from Google on Today beside pasted links | testable in the Simulator against local `wrangler dev`, with fast polling as a stand-in until C–E exist |
| C | API: `calendar_channels` table, register / unregister routes, the webhook, APNs sender | local tests with mocked Google and APNs |
| D | Deploy: remote D1 and KV, secrets, `wrangler deploy`, app base URL per build configuration | every step asks first |
| E | iOS: real identity, push capability, device-token registration, background push handling, channel upkeep | signing change; Simulator on Apple silicon receives sandbox pushes, also check on a real phone if the user wants |
| F | End-to-end check: add an event in Google Calendar, watch Today update with no touch | the user signs in themselves; the agent does not see the sign-in |

A and B deliver "new events within seconds while the app is open" before anything is deployed; C–F make it true push.

## Open points to confirm while building

- Whether Google still requires the webhook's domain to be verified in Search Console (the current push guide lists only a valid HTTPS certificate). If it does, the Worker needs a custom domain the user owns, not `workers.dev`.
- Google Calendar API quota for watch and list calls (well under the default at this scale; check the quota page).
- Calendar links to the Keychain and hiding private event titles: older open questions, unchanged by this plan.

## Sources

- Google Calendar push guide: https://developers.google.com/workspace/calendar/api/guides/push
- `events.watch`: https://developers.google.com/workspace/calendar/api/v3/reference/events/watch
- OAuth app states and test-mode limits: https://developers.google.com/identity/protocols/oauth2/production-readiness/overview , https://support.google.com/cloud/answer/15549945
- Apple, pushing background updates: https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app
