---
id: 13
title: API subscription B1: Better Auth with Sign in with Apple (native ID token), bearer sessions, D1 auth tables
status: review
owner: implementer-1
depends_on: []
created: 2026-11-15T22:33:55Z
updated: 2026-11-25T02:51:34Z
---

## Goal

Read plans/2026-11-24-account-and-subscription.md (phase B), memory/decisions/2026-11-24-subscription-gate-and-ai-lapse-rule.md and memory/notes/2026-11-24-storekit-research.md first. Phase B was split on 2026-11-24 into this task and the B2 to B6 tasks. Here: Better Auth on D1 through the Drizzle adapter, mounted at /api/auth/*, the auth instance created per request from the bindings; the Apple provider with appBundleIdentifier from vars, signing in with the native Apple ID token (no web redirect flow); the bearer plugin for the phone's session token; the email from the identity token stored at first sign-in; the auth tables in api/src/db/schema.ts with a generated migration applied locally; one session helper the later routes use to get the authenticated user ID (401 without a session). Look the current Better Auth API up in the better-auth MCP docs before writing. No secret is read or written by the agent: the tests give the Worker a test-only auth secret through the Vitest config, and the task ends with a list of the secrets and vars the user must set (names only). No entitlement, sync or discover change here.

## Acceptance criteria

Tests: a sign-in with an Apple ID token signed by a test key (Apple's key fetch stubbed) creates the user with its email and returns a session; a token with the wrong audience, issuer, signature or expiry is refused; the bearer token reaches the session helper and a missing or bad one gets 401
The existing open /v1 routes behave as before
npm test and npx tsc --noEmit pass; migration generated and applied locally; spec and Swift client regenerated if a documented route changed, and the iOS app still builds

## Relevant files

- api/src/auth.ts
- api/src/db/schema.ts
- api/src/routes/

## What's been tried


## Log

- 2026-11-15T22:33:55Z [li] created (backlog)
- 2026-11-24T15:55:23Z [li] Lead 2026-11-24: design replaced by plans/2026-11-24-account-and-subscription.md once the user approves it (accounts exist only with a subscription; sync and discover need an entitlement). Do not start from the old goal.
- 2026-11-24T19:05:41Z [li] edited section: Goal
- 2026-11-25T02:31:50Z [li] title: "API: auth, D1 tables, sync, account deletion, Cron refresh" → "API subscription B1: Better Auth with Sign in with Apple (native ID token), bearer sessions, D1 auth tables"
- 2026-11-25T02:31:50Z [li] depends on: #12 → none
- 2026-11-25T02:31:50Z [li] edited section: Goal
- 2026-11-25T02:31:50Z [li] edited section: Acceptance criteria
- 2026-11-25T02:32:09Z [li] status: backlog → todo
- 2026-11-25T02:32:09Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-25T02:39:23Z [implementer-1] Tests first: test/auth.test.ts written (Apple ID token signed by an RSA key made in the test, Apple's key list stubbed through fetch; refusals for audience, issuer, signature, expiry, token age, HS256; second sign-in without email; nonce; no web flow; 503 without secret; no email/token in console; requireSession 401 for missing, garbage, forged, expired, deleted, signed-out, cookie-only). Before the code: vitest fails with 'Cannot find module ../src/lib/session.ts' (Test Files 1 failed).
- 2026-11-25T02:46:46Z [implementer-1] Built (commit 4b71f6e): better-auth 1.7.28 installed with npx -y npm@11 install (lockfile also re-hoisted workerd under wrangler/; tests, wrangler dev and local migrations all work). src/auth.ts createAuth(env) per request: better-auth/minimal + better-auth/adapters/drizzle on D1 + bearer plugin; Apple provider clientId and appBundleIdentifier = vars.APPLE_APP_BUNDLE_ID, empty clientSecret (no web flow); mapProfileToUser gives <sub>@apple.placeholder.invalid only when a token has no email; updateAccountOnSignIn false and databaseHooks.account strip idToken/accessToken/refreshToken; disableIpTracking; Better Auth rate limiter off (in-memory, lasts one request); telemetry off; logger prints the message only. Returns null (503 auth_unavailable) without BETTER_AUTH_SECRET >= 32 chars, since Better Auth falls back to a public default secret outside production. src/lib/session.ts requireSession: only the Authorization header goes to auth.api.getSession; 401 {error:unauthorized} otherwise; c.get('userId'). New var BETTER_AUTH_URL in wrangler.jsonc (cf-typegen rerun). Test-only BETTER_AUTH_SECRET in vitest.config.ts miniflare.bindings.
- 2026-11-25T02:46:46Z [implementer-1] Verification: all ID-token checks are Better Auth's (jose jwtVerify via @better-auth/core verify-id-token.mjs): RS256 signature by kid from appleid.apple.com/auth/keys, iss, aud = bundle ID, exp, iat max 1h, 30 s skew, required claims, nonce if sent. Nothing added. Mutation runs: verifyIdToken forced to true -> 9 tests fail; cookie passed to getSession -> cookie test fails; token columns kept -> fails; IP tracking on -> fails. Result: npm test 'Test Files 23 passed (23)', 'Tests 2020 passed (2020)'; npx tsc --noEmit exit 0. Migration 0001_better_auth generated by drizzle-kit and applied with wrangler d1 migrations apply seasign --local. npm run openapi: spec unchanged (git diff empty), so no Swift regeneration or iOS build needed. wrangler dev smoke: /v1/health 200; /api/auth/* 503 auth_unavailable without a local secret.
- 2026-11-25T02:46:46Z [implementer-1] Schema: generated with npx auth@1.7.28 generate --adapter drizzle --dialect sqlite from a CLI-only config in the scratchpad (the auth CLI loads environment files from its working directory, so it was not run in api/); pasted into src/db/schema.ts without the relations (joins off). Follow-ups for the lead: Workers rate limit and body cap on /api/auth/*; Apple key list fetched uncached on every sign-in; consider allow-listing Better Auth paths (update-user, list-sessions, link-social etc. are reachable with a session); session length is Better Auth's default 7 days, refreshed daily.
- 2026-11-25T02:51:34Z [implementer-1] Second commit 4b30240 after the advisor's checks: bearer({ requireSignature: true }) so only the signed set-auth-token value authenticates (the bare body token, as stored in D1, gets 401; test added); nonce test fixed to send the nonce inside idToken (same nonce and its SHA-256 hex pass, other or missing claim 401); sign-in plus requireSession pass on http://localhost:8787. npm ci from the committed lockfile, then npm test: 'Test Files 23 passed (23)', 'Tests 2023 passed (2023)'; tsc exit 0. Lockfile: only new packages added; the removed top-level workerd 1.20260815.1 was an unused leftover (wrangler and vitest-plugin keep their own 1.20261113.1). Apple TN3194 (sosumi): recommends the authorization-code exchange and keeping Apple's refresh token so account deletion can call /auth/revoke; this build keeps no Apple token, so B4 must either add the exchange (needs a Sign in with Apple key, Key ID, Team ID) or use Apple's manual-revocation fallback.
- 2026-11-25T02:51:34Z [implementer-1] status: in-progress → review
