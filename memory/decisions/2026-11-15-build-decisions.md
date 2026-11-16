# 2026-11-15 — decisions made while building tasks 2–17

Product decisions from the planning session are in `2026-11-15-v1-product-decisions.md`. These came out of implementation and review. Details and measured figures are in `memory/architecture.md`.

## API tests run on `@cloudflare/vitest-plugin` (task 16)

- **Decision.** Replaced `@cloudflare/vitest-pool-workers` (renamed upstream, frozen at 0.23.0) with `@cloudflare/vitest-plugin`. The user approved the swap.
- **Why.** The old package pinned an old workerd and held `compatibility_date` at 2026-08-22.
- **Rejected for now.** `@msw/cloudflare` + `msw` for outbound mocking (two unapproved packages). Tests mock with `vi.spyOn(globalThis, "fetch")`.

## Calendar files: ical.js parses, our code expands (task 5)

- **Decision.** `ical.js` is used only to parse text and decode single values. Repeat rules (`expandRule`) and VTIMEZONE offsets (`readZone`, `zoneOffset`) are computed in `api/src/lib/calendar.ts`. Each VEVENT is rebuilt from an allowlist of nine properties. A test file rigs ical.js's iterator and zone-expansion functions to throw and asserts none is reached.
- **Why.** Three review rounds each found a file that made an ical.js recurrence iterator spin for 15–60 s (a rule past the whitelist, then a folded property name). A filter in front of the iterator kept failing; removing the iterator from the path does not.
- **Consequences.** Unsupported rules are skipped and the calendar is reported `partial`: yearly rules with BYDAY/BYMONTHDAY but no BYMONTH, EXRULE, sub-daily, BYWEEKNO, BYYEARDAY. A TZID nobody can interpret is read in the request's zone and sets `partial`. Windows zone names are mapped with a built-in CLDR table.
- **Accepted limits.** An event starting inside a repeated or skipped DST hour can be an hour off. A truncated file is refused whole. Titles of `CLASS:PRIVATE` events are shown (the link is the owner's own).

## User-supplied URLs go through `safeFetch` only (task 5)

- **Decision.** `api/src/lib/safe-fetch.ts` is the only way the Worker fetches a URL a user supplied: https on 443, no credentials, no private or local hosts, manual redirects re-checked per hop, one deadline, size cap enforced on the stream.
- **Known limit.** A public hostname that resolves to a private address cannot be caught in a Worker.

## Two local stores on the phone (task 17)

- **Decision.** The user store (`default.store`: Settings, ListItem, CalendarLink) is never deleted or moved by the app and is always opened with the full schema. The cache store (`SkyCache.store`: CachedSky, CachedEvents) can be deleted and rebuilt. If the user store cannot open, the app shows an error screen and deletes nothing.
- **Why.** A `fatalError` on container failure would crash at launch; deleting the store to recover would destroy the user's lists.
- **Rule that goes with it.** A cached sky reading older than 3 hours still places the sun and moon but shows no temperature or weather.

## Feed rules (task 7, second review still pending)

- **Decision.** Feeds are capped at 1 MB and pass a linear shape check before `fast-xml-parser` sees them. Items without a readable date, and links read from a page, get a first-seen time from a KV record and age out after 7 days. A site's first fetch stamps its links a day old so a newly followed site does not flood Today. Resolve prefers reading links from the page when a non-root page advertises only a feed that shares no path with it. Request bodies over 64 KB are refused on every `/v1/*` route.
- **Why.** The parser is time-bounded but needed 160–260 MB on a hostile 2 MB feed, above a Worker's 128 MB.

## Deployment constraints found so far (nothing is deployed)

- `/v1/feed` needs the Workers Paid plan (CPU time and subrequest count).
- Per-IP rate limiting is not built (task 19) and must be done before any deploy.
- The calendar path can need up to 112 MB on a hostile 2 MB file (task 18).

## Visual polish is light while the design changes

The user is iterating on the design. UI tasks are built roughly to the mockups with one or two screenshots; logic, data safety and API security keep full review.
