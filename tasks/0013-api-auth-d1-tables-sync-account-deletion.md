---
id: 13
title: API subscription B1: Better Auth with Sign in with Apple (native ID token), bearer sessions, D1 auth tables
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-15T22:33:55Z
updated: 2026-11-25T02:32:09Z
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
