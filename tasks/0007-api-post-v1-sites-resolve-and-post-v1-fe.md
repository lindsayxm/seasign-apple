---
id: 7
title: API: POST /v1/sites/resolve and POST /v1/feed
status: in-progress
owner: implementer-1
depends_on: [5]
created: 2026-11-15T22:33:55Z
updated: 2026-11-16T02:35:18Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. /v1/sites/resolve takes a page URL and returns the site title and how to follow it: the RSS/Atom feed the page advertises (link rel=alternate), or page-links mode. /v1/feed takes up to 50 sites (url, mode, feed URL) and returns items from the last 7 days: title, link, source, published date, excerpt, site URL. Parse feeds with fast-xml-parser; in page-links mode use HTMLRewriter to collect article links and headlines, using first-seen time when no date is available. Reuse the safe fetch helper (https only, no private hosts, size and time caps). Cache per site in KV for 30 minutes. Regenerate spec and client.

## Acceptance criteria

- [ ] Tests with RSS, Atom and HTML fixtures cover feed discovery, both modes and a failing site
- [ ] Items older than 7 days are not returned
- [ ] npm test and npx tsc --noEmit pass
- [ ] openapi/openapi.json regenerated and the iOS app still builds

## Relevant files

- api/src/routes/sites.ts
- api/src/routes/feed.ts
- api/src/lib/safe-fetch.ts
- api/test/
- openapi/openapi.json

## What's been tried


## Log

- 2026-11-15T22:33:55Z [li] created (todo)
- 2026-11-16T02:20:09Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-16T02:35:18Z [implementer-1] Installed fast-xml-parser 5.12.1 with the installed npm 10.9.2 (no crash; npm reports 4 moderate audit advisories, not touched). Probed it in Node and HTMLRewriter in workerd before writing code. Design: lib/text.ts (linear HTML-to-text and entity decoding), lib/feed-parse.ts (fast-xml-parser with processEntities:false, preserveOrder, maxNestedTags 64; own date parsing), lib/page-links.ts (HTMLRewriter scan, feed discovery, article-link choice), lib/site-reader.ts (fetch through safeFetch, KV keys, first-seen record), routes/sites.ts and routes/feed.ts.
