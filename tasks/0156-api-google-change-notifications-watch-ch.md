---
id: 156
title: API: Google change notifications: watch channels, webhook and APNs background push
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-19T21:15:18Z
updated: 2026-11-19T21:15:18Z
---

## Goal

Plan plans/2026-11-19-google-calendar-push.md, task C. When a chosen Google calendar changes, Google calls our webhook and the Worker sends a background push to the phone, which then reloads events. Built and tested locally with mocked Google and APNs; nothing is deployed and no secret is set in this task.

## Acceptance criteria

- [ ] Look up first, and cite in the log: Google Calendar push guide and events.watch / channels.stop references (request body, the X-Goog-Channel-ID, X-Goog-Channel-Token, X-Goog-Resource-ID, X-Goog-Resource-State and X-Goog-Channel-Expiration headers, the initial sync message, expiry limits, whether the webhook domain must be verified); Apple's 'Sending notification requests to APNs' and 'Establishing a token-based connection to APNs' (ES256 JWT with kid and iss, 20-60 minute token reuse, apns-topic, apns-push-type background, apns-priority 5, content-available payload, sandbox vs production hosts, the 410 Unregistered answer); cloudflare-docs for WebCrypto ES256 import of a PKCS#8 key and for whether a Worker fetch to api.push.apple.com (HTTP/2) works
- [ ] D1 table calendar_channels through the Drizzle schema and a drizzle-kit migration: channel id (random, primary key), SHA-256 of the channel token, Google resource id, APNs device token, APNs environment (sandbox or production), expiry, created time. It holds no Google token, no calendar id, no user id and no event data. Local migration applies
- [ ] POST /v1/google/watch (headers X-Google-Token; body: calendar ids (max 10), APNs device token (hex, validated), environment): replaces the device's earlier channels (stops them at Google best effort, deletes rows), calls events.watch per calendar with address = the configured public webhook URL (a var in wrangler.jsonc, set to https://api.seasign.app/v1/google/notify), a random channel id and a random token, stores rows, returns each calendar's ok/error and the soonest expiry. POST /v1/google/unwatch (X-Google-Token; body: device token): stops and deletes that device's channels. Both under the google rate-limit group, no-store, token never stored or logged
- [ ] POST /v1/google/notify (called by Google, no auth header): looks the channel up by X-Goog-Channel-ID, compares the SHA-256 of X-Goog-Channel-Token in constant time, ignores the initial sync state, and otherwise sends one background push to that row's device; unknown or mismatched channels get 200 with no action and no information (so Google does not retry and probing learns nothing); expired rows are deleted; an APNs 410 or BadDeviceToken deletes the device's rows. It answers fast and never calls Google. It has its own rate-limit consideration (Google's callers share addresses): explain the choice
- [ ] APNs sender in api/src/lib: ES256 provider token signed with WebCrypto from secrets APNS_KEY (PKCS#8 PEM text), APNS_KEY_ID, APNS_TEAM_ID and the existing APPLE_APP_BUNDLE_ID as topic; token cached in memory under an hour; payload {aps:{content-available:1}} plus a small non-identifying type field; when the secrets are absent the sender reports 'not configured' without throwing and the route still answers 200. No secret value is ever logged; tests use a throwaway key generated in the test
- [ ] Secrets are declared for types only (no values anywhere in the repo); the user sets them at deploy. Tests with mocked Google and APNs cover: register, replace, unwatch, notify happy path, sync message, wrong token, unknown channel, expired channel, APNs 410 cleanup, sender not configured, JWT shape verified against the public key. npm test and tsc pass; npm run openapi and the Swift client regenerate; the iOS app still builds

## Relevant files

- api/src
- api/test
- api/migrations
- api/wrangler.jsonc
- openapi/

## What's been tried


## Log

- 2026-11-19T21:15:18Z [lead] created (todo)
- 2026-11-19T21:15:18Z [implementer-1] status: todo → in-progress — claimed by implementer-1
