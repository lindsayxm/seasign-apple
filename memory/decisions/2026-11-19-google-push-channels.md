# 2026-11-19: Google Calendar push channels and APNs from the Worker (task 156)

Plan: `plans/2026-11-19-google-calendar-push.md`, task C. Code: `api/src/routes/google-push.ts`, `api/src/lib/apns.ts`, table `calendar_channels` in `api/src/db/schema.ts` (migration `api/migrations/0000_calendar_channels.sql`).

## What the server keeps

One row per Google channel: our random channel id (a UUID; Google allows up to 64 characters), the SHA-256 of the 256-bit channel token, Google's `resourceId` (`channels.stop` needs it), the APNs device token, the APNs environment, the expiry and the creation time. It holds no Google token, no calendar id, no user id and no event data. The webhook works from the row alone, because Google's notification carries only `X-Goog-*` headers and no body (push guide). Nothing at notify time needs a Google token, so the design holds.

## Behaviour chosen

- **Watch replaces.** New channels are made first. Then every other channel of the same device token is forgotten and stopped at Google, as best effort, with the new token. When the token is refused (401), the channels just made are stopped and nothing else changes. When no channel could be made, the old ones are kept. The last concurrent watch wins. Expired rows are removed on every watch.
- **The watch filter matches the read filter.** Both use `eventTypes=default&eventTypes=fromGmail`, so working-location, focus-time and birthday changes do not wake the phone.
- **Notify** answers a bare 200 to everything (sync, unknown channel, wrong token, wrong resource id, expired, push sent or failed), so a caller learns nothing. The one exception is a D1 failure, which answers 503 because Google may retry 5xx. A channel id that is not a lowercase UUID is answered without a D1 read. Tokens are compared as SHA-256 hex with `crypto.subtle.timingSafeEqual`. An APNs 410, `BadDeviceToken`, `DeviceTokenNotForTopic` or `ExpiredToken` deletes every row of that device. The Google channel then lives on until it expires (7 days at most), and its calls are ignored.
- **APNs.** The provider token is ES256, signed with WebCrypto from a PKCS#8 PEM. It is cached per isolate for 40 minutes, inside Apple's 20 to 60 minute window, and remade early only after `ExpiredProviderToken`. The push uses `apns-push-type: background`, `apns-priority: 5`, `apns-expiration` one hour ahead, and the payload `{"aps":{"content-available":1},"type":"calendar-changed"}`. The host is `api.sandbox.push.apple.com` or `api.push.apple.com`, from the row. Without the secrets the sender returns `not_configured` and logs once.
- **Secret types** are declared optional in `api/src/env.d.ts`, not with `secrets.required` in `wrangler.jsonc`. That setting also filters what `wrangler dev` loads from the local secrets file, and it makes `wrangler deploy` fail while a secret is missing. Whether to adopt it is a task D choice.

## Trust boundary

No account is involved: the APNs device token is the only thing that ties channels together. Anyone who knows a device token and holds any working Google token can replace that device's channels with watch, or remove them with unwatch. Unwatch forgets the rows even when Google refuses the stop. They could also make that phone receive background pushes on their own calendar's changes, which Apple throttles and which only cause a reload. Device tokens are not public, and the routes are rate limited. This follows the approved plan, but it departs from the AGENTS.md rule that queries on user data are scoped by the session's user. Revisit when sign-in exists (task 13).

## Open, to check at deploy (task D)

- **Can a deployed Worker reach APNs?** APNs speaks only HTTP/2. Neither the Workers `fetch` page nor the other Cloudflare docs we found say which protocol an outbound `fetch` uses. Cloudflare's "HTTP/2 to Origin" page says it uses HTTP/2 when the server offers it through ALPN, but that page is about zones' origins. The Workers protocols page (https://developers.cloudflare.com/workers/reference/protocols/) says only "Make HTTP subrequests using the fetch() API", with no HTTP version. Measured on 2026-11-19:
  - The local runtime fails with "Network connection lost". This was measured in the vitest workerd only; `wrangler dev` uses the same runtime, so it is expected to fail too.
  - `curl --http1.1` gets no answer.
  - `curl --http2` gets 403 `MissingProviderToken`.

  So local runs cannot send a real push. A third-party package (`@fivesheepco/cloudflare-apns2`) says it sends APNs from Workers, which suggests production works, but this is unverified. Check: post-deploy check 3 in `2026-11-16-rate-limits-and-deploy-limits.md`. If it fails, a small relay outside Workers would be needed (a new service: ask the user).
- **Webhook domain verification.** The push guide asks only for HTTPS with a valid certificate. Google's support page (https://support.google.com/googleapi/answer/7072069) says "Domain verification in the API Console is no longer required to make push notifications work with your domains." If `events.watch` answers with a `push.*` reason such as `push.webhookUrlUnauthorized`, the route reports `webhook_refused`, and the fallback is verifying `seasign.app` in Search Console.
- **The APNs key's environment.** Apple now issues team keys limited to sandbox or production. A sandbox-only key gets 403 for production devices (`auth_failed` in the log), and the other way round.
- **Push volume.** Apple asks for no more than two or three background pushes an hour. The webhook sends one per change. Coalescing per device (for example a KV marker) is a follow-up if devices get throttled.
