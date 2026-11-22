---
id: 176
title: API: create-event route follow-ups: year bound, title characters, permanent Google 400
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-22T19:05:10Z
updated: 2026-11-22T19:05:10Z
---

## Goal

Low findings from the #168 review. (1) date 9999-12-31 passes validation and sends Google a malformed end date; Google's permanent 400 comes back as 502 fetch_failed whose message says to retry. (2) The title pattern lets through U+2028/U+2029, a title that is only zero-width characters, and lone surrogates, though the spec says no control characters. (3) The spec text for created:false says the event is in the calendar, which may be untrue for the id of an event the user deleted.

## Acceptance criteria

- [ ] Dates and times are bounded to a sane range (from one year before now to five years after now) with the fixed 400 before any outbound call; tests incl. 9999-12-31
- [ ] Titles: line and paragraph separators, other format/control characters that hide content, and lone surrogates are rejected; a title with no visible character is rejected; ordinary non-Latin titles and emoji pass; tests
- [ ] A Google 400 gets its own non-retryable code (for example rejected, HTTP 502) with wording that does not say try again; created:false wording says Google reports the id as already used; tests for a calendar id containing / ? #, a __proto__ key, and a non -5h offset on a DST day are added
- [ ] npm test and tsc pass; npm run openapi regenerated; the iOS app still builds (coordinate with running builds)

## Relevant files

- api/src/routes/google-create.ts
- api/src/lib/google.ts
- api/test/google-create.test.ts
- openapi/

## What's been tried


## Log

- 2026-11-22T19:05:10Z [li] created (todo)
- 2026-11-22T19:05:10Z [implementer-1] status: todo → in-progress — claimed by implementer-1
