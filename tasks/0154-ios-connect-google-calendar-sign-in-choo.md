---
id: 154
title: iOS: connect Google Calendar (sign-in, choose calendars, events on Today, fast polling); real bundle ID and team
status: in-progress
owner: implementer-2
depends_on: []
created: 2026-11-19T19:50:32Z
updated: 2026-11-19T19:51:02Z
---

## Goal

Plan plans/2026-11-19-google-calendar-push.md, task B. The user connects their Google account in Settings; Today shows events from the chosen Google calendars beside pasted-link calendars, and new Google events appear within seconds while the app is open (polling, as a stand-in until push exists). Also switches the project to the user's real identity (approved signing change).

## Acceptance criteria

- [ ] Identity: app-identity.xcconfig has APP_BUNDLE_ID technology.artisan.seasign and DEVELOPMENT_TEAM Q79NR2FCR9; api/wrangler.jsonc APPLE_APP_BUNDLE_ID matches (npm test identity check passes); every place that hard-codes com.example.seasign in code, tests or scripts is found and fixed or reads the setting; xcodegen generate; Simulator build works
- [ ] Sign-in: OAuth 2.0 for installed apps with PKCE (S256) and a state check through ASWebAuthenticationSession; client ID and redirect scheme from the plan (kept in one config place, registered as a URL scheme in project.yml); scopes calendar.events.readonly and calendar.calendarlist.readonly; code exchanged and tokens refreshed directly with Google's token endpoint over https (look up Google's current 'OAuth 2.0 for iOS & Desktop Apps' page first); no Google SDK, no new package
- [ ] Tokens: refresh token only in the Keychain (this-device-only, after-first-unlock, like the existing Keychain items); access token in memory, refreshed before expiry and on a 401 google_auth; an invalid_grant (revoked, or Google's 7-day test-mode expiry) puts Settings into a clear 'Connect again' state and Today drops Google events; Disconnect revokes at Google (best effort), deletes the Keychain item, chosen calendars and cached Google events. Tokens and codes never logged, never in SwiftData, never in a URL after the redirect is consumed
- [ ] API calls: getGoogleCalendars and postGoogleEvents through the generated client with a raw-header middleware for x-google-token (like RawKeyHeader for x-llm-key) so the token is not percent-encoded; our 429 and per-calendar rate_limited back off; errors show a short status in Settings and leave Today's existing events on screen
- [ ] Settings: a Google Calendar section in the present style: Connect / connected state, the list of the account's calendars with toggles (primary on by default, at most 10 on), Disconnect. Pasted links keep working unchanged below it
- [ ] Today: Google events and pasted-link events are merged in one soonest-first list of at most three, same labels and time-zone rules; Google events are cached locally like the others for cache-first launch. While the app is active and Today is on screen, Google events are polled every 5 seconds (one request for all chosen calendars; no polling in the background, on other screens, or when not connected); the calendar pull and return to the foreground also fetch at once. No spinner for polling
- [ ] Tests (Swift Testing, mocked transport and a mocked token endpoint; no real Google account): PKCE and state, redirect parsing incl. error and mismatched state, token refresh and invalid_grant, raw header, merge order, polling gate, disconnect clears everything. Suite passes on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2. Screenshots of the Settings section in its not-connected state on the iPhone 16 Pro Max. The real sign-in is tried only by the user: do not drive, screenshot or log the Google sign-in sheet or any account data

## Relevant files

- app-identity.xcconfig
- api/wrangler.jsonc
- ios/

## What's been tried


## Log

- 2026-11-19T19:50:32Z [lead] created (todo)
- 2026-11-19T19:51:02Z [implementer-2] status: todo → in-progress — claimed by implementer-2
