---
id: 226
title: API accounts: follow-ups from the #13 security reviews
status: backlog
owner: 
depends_on: []
created: 2026-11-25T03:32:34Z
updated: 2026-11-25T03:32:34Z
---

## Goal

Left from task 13's reviews; none is an open hole. (1) A server-issued single-use nonce for Sign in with Apple: today an identity token can be replayed for new sessions until it expires (at most 1 hour); the phone should at least send a SHA-256 nonce (phase C). (2) Session length: Better Auth's default of 7 days sliding; the user's choice (lead suggests 90 days sliding). (3) Apple's consent-revoked server notices and token revocation on account deletion: with task 223, needs the user's decision on a Sign in with Apple key. (4) Cache Apple's key list (fetched on every sign-in attempt). (5) The 20-a-minute budget is shared by sign-in, get-session, sign-out and 404s per address: recheck once the phone's call pattern is known. (6) apple_email stores whatever the signed claim holds; non-ASCII subs that case-fold alike would lock the second one out (Apple's subs are ASCII). (7) The phone retries a sign-in once on 401/500 (a race or D1 error can fail one request). (8) Never create a binding named BETTER_AUTH_SECRETS. (9) Invariant for tasks 221-223: never leave a user row without its account row; it is deleted at that Apple ID's next sign-in. (10) accountLinking off has no test of its own. (11) CPU time per authenticated request on the Workers plan in use.

## Acceptance criteria

- [ ] Each item fixed, or closed with a recorded decision
- [ ] npm test and npx tsc --noEmit pass

## Relevant files

- api/src/auth.ts
- api/src/routes/auth.ts
- api/test/auth.test.ts

## What's been tried


## Log

- 2026-11-25T03:32:34Z [li] created (backlog)
