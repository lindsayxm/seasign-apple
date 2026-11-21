---
id: 159
title: API: make unwatch's read-and-delete atomic (one db.batch), as watch now is
status: in-progress
owner: implementer-2
depends_on: [156]
created: 2026-11-20T22:42:44Z
updated: 2026-11-21T13:53:09Z
---

## Goal

Found while fixing #156. POST /v1/google/unwatch reads the device's rows and then deletes them as two D1 statements. An unwatch that overlaps a watch for the same device can delete the watch's new rows without stopping those channels at Google; they then live up to 7 days and their calls are ignored (harmless but wasteful, and the device has no channel).

## Acceptance criteria

- [ ] Unwatch reads and deletes the device's rows in one db.batch, and stops at Google exactly the channels whose rows it deleted
- [ ] A test with an unwatch overlapping a watch for the same device: no channel is left at Google without a row unless it was stopped
- [ ] npm test and npx tsc --noEmit pass; openapi/openapi.json unchanged

## Relevant files

- api/src/routes/google-push.ts
- api/test/google-push.test.ts

## What's been tried


## Log

- 2026-11-20T22:42:44Z [li] created (todo)
- 2026-11-20T22:47:20Z [li] Lead: also in scope, from the second #156 review (treat as added criteria, each with a test where behaviour changes): (a) api/src/lib/apns.ts about 218: clear the cached provider token only if it is still the one Apple refused, so several notifies hitting ExpiredProviderToken in one isolate do not each mint a token (Apple 429 TooManyProviderTokenUpdates); (b) google-push.ts about 341-345: if the watch batch throws, the catch stops the new channels at Google; if the batch had in fact committed, rows are left for stopped channels: delete those rows best effort in the catch (or explain in the log why not); (c) memory/decisions/2026-11-19-google-push-channels.md says expired rows are removed on every watch; not true on the 401 and early 400/503 paths: correct the wording.
- 2026-11-21T13:53:09Z [implementer-2] status: todo → in-progress — claimed by implementer-2
