---
id: 159
title: API: make unwatch's read-and-delete atomic (one db.batch), as watch now is
status: done
owner: implementer-2
depends_on: [156]
created: 2026-11-20T22:42:44Z
updated: 2026-11-21T14:07:02Z
---

## Goal

Found while fixing #156. POST /v1/google/unwatch reads the device's rows and then deletes them as two D1 statements. An unwatch that overlaps a watch for the same device can delete the watch's new rows without stopping those channels at Google; they then live up to 7 days and their calls are ignored (harmless but wasteful, and the device has no channel).

## Acceptance criteria

- [x] Unwatch reads and deletes the device's rows in one db.batch, and stops at Google exactly the channels whose rows it deleted
- [x] A test with an unwatch overlapping a watch for the same device: no channel is left at Google without a row unless it was stopped
- [x] npm test and npx tsc --noEmit pass; openapi/openapi.json unchanged

## Relevant files

- api/src/routes/google-push.ts
- api/test/google-push.test.ts

## What's been tried


## Log

- 2026-11-20T22:42:44Z [li] created (todo)
- 2026-11-20T22:47:20Z [li] Lead: also in scope, from the second #156 review (treat as added criteria, each with a test where behaviour changes): (a) api/src/lib/apns.ts about 218: clear the cached provider token only if it is still the one Apple refused, so several notifies hitting ExpiredProviderToken in one isolate do not each mint a token (Apple 429 TooManyProviderTokenUpdates); (b) google-push.ts about 341-345: if the watch batch throws, the catch stops the new channels at Google; if the batch had in fact committed, rows are left for stopped channels: delete those rows best effort in the catch (or explain in the log why not); (c) memory/decisions/2026-11-19-google-push-channels.md says expired rows are removed on every watch; not true on the 401 and early 400/503 paths: correct the wording.
- 2026-11-21T13:53:09Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-21T13:57:18Z [implementer-2] Baseline npm test: 1766 pass. Wrote 3 tests in api/test/google-push.test.ts before touching src/; against the old code all 3 fail for the intended reason: (1) unwatch overlapped by a watch (gatedDb test helper runs a full watch after unwatch's first D1 call): 'channel <new id>: expected false to be true' - the watch's new channel has no row and was not stopped; (2) watch batch commits then throws: 'expected [...] to not include <made id>' - rows left for channels the catch stopped; (3) two notifies refused with the same expired APNs provider token: 'expected sign to be called 1 times, but got 2 times'.
- 2026-11-21T13:59:13Z [implementer-2] Unwatch: select + delete on the same device-token filter now run as one db.batch; the selected rows are stopped and counted as removed (the old 'skip delete when 0 rows' shortcut is gone; the batch always runs). Test helper gatedDb wraps env.DB (thin statement wrappers unwrapped for batch) and runs a whole watch after the first D1 call of the unwatch; the test asserts the gate fired once and both requests answered 200, so it cannot pass or fail through a broken wrapper.
- 2026-11-21T13:59:13Z [implementer-2] (a) apns.ts: the provider-token cache now holds the token as a promise, stored before any await (currentToken), and evicted if signing fails. After ExpiredProviderToken a push clears the cache only if it still holds the entry it sent with (checked and cleared with no await between). Going slightly past the lead's wording on purpose: clearing only-if-still-refused alone would still let a second refused push mint while the first is mid-signature (cache empty), so the in-flight promise is shared. providerToken(config, now): Promise<string> keeps its signature. Test spies on crypto.subtle.sign: 1 call, 4 pushes, one fresh token.
- 2026-11-21T13:59:13Z [implementer-2] (b) watch catch: when the batch throws, rows for the new channels are deleted by their ids (never by device token, which would hit a concurrent watch's rows), guarded by made.length > 0, in its own silent try/catch (the 500 test still expects exactly one log line), then the channels are stopped as before. Residual not fixable here: if the batch committed and then threw, the device's earlier rows were deleted and their ids never returned, so those channels are not stopped (they lapse in <=7 days, calls ignored), and the 500 description 'nothing was changed' is then not strictly true; left unchanged because the spec must not change. Possible follow-up. (c) decision record: sweep wording corrected (no sweep on 400, 503, 401 or a DB failure; the no-channel-made path does sweep), plus lines for the atomic unwatch, the catch cleanup and the shared token refresh. npm run openapi: git diff openapi/ empty. npm test 1769 pass (1766 + 3), tsc clean, google-push file run 5x green.
- 2026-11-21T14:01:23Z [implementer-2] Committed 03fa4f5 (only the 4 files; tasks/ left to the lead). Cross-request check for the shared token promise: api/wrangler.jsonc compatibility_date 2026-11-13, past the 2024-10-14 default date of handle_cross_request_promise_resolution (Cloudflare compatibility-flags page), so a request awaiting a token promise started by another runs its continuation in its own context; the value shared is a string, not an I/O object. Not exercised in a deployed isolate.
- 2026-11-21T14:01:23Z [implementer-2] status: in-progress → review
- 2026-11-21T14:06:35Z [implementer-2] criterion 1 met: Unwatch reads and deletes the device's rows in one db.batch, and stops at Google exactly the channels whose rows it deleted
- 2026-11-21T14:06:36Z [implementer-2] criterion 2 met: A test with an unwatch overlapping a watch for the same device: no channel is left at Google without a row unless it was stopped
- 2026-11-21T14:06:36Z [implementer-2] criterion 3 met: npm test and npx tsc --noEmit pass; openapi/openapi.json unchanged
- 2026-11-21T14:06:36Z [implementer-2] review: PASS. Criteria 1-3 verified and ticked. (1) unwatch select+delete share one filter in one db.batch; rows stopped = rows deleted; removed = rows.length, 0 with no Google call for an empty device (existing test). Walked watch/unwatch interleavings (unwatch batch before or after watch batch, watch 401, watch commit-then-throw): none leaves a live channel with no row and no stop. (2) New tests run against the pre-fix src (scratch copy, 03fa4f5 tests + 03fa4f5^ src): all 3 fail for the stated reasons, 64 others pass. The overlap test cannot prove batch atomicity (that is D1's guarantee) but does catch any two-call read/delete, which is the bug; good enough. (3) npm test 1769 pass; tsc clean; spec generated to stdout equals committed openapi/openapi.json and is unchanged by the commit. (a) apns: rejected token promise evicted by .catch only if still cached; cache key and 40-min TTL unchanged; no logging; conditional clear has no await between check and clear. handle_cross_request_promise_resolution confirmed in bundled workerd binary with default date 2024-10-14 (< compat date 2026-11-13); docs MCP not available to the reviewer. (b) catch deletes by inArray(made ids) only (fresh UUIDs of this request), in a silent try/catch, before stopping; answer stays 500 with one log line. (c) decision record matches the code. Low notes: a never-settling token promise would block pushes for up to 40 min since await used.token is outside the APNs deadline (no path found: signToken does no I/O); 500 text 'nothing was changed' still untrue after commit-then-throw (pre-existing, documented; follow-up).
- 2026-11-21T14:07:02Z [implementer-2] status: review → done
