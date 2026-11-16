---
id: 7
title: API: POST /v1/sites/resolve and POST /v1/feed
status: review
owner: implementer-1
depends_on: [5]
created: 2026-11-15T22:33:55Z
updated: 2026-11-16T02:51:19Z
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

- Stopping HTMLRewriter by throwing from a handler: it rejects the transform, but workerd also prints an uncaught exception for every stop. Feeding the body in pieces and ending the input instead.
- fast-xml-parser without preserveOrder: text around CDATA and inside nested XHTML lost its order ('pre <![CDATA[x]]> post' came back as 'prepost'). preserveOrder with trimValues:false keeps it.
- fast-xml-parser with processEntities on: its limits can only be lowered to one custom entity, not none. Turned off entirely; our own decodeEntities handles the XML five, numeric and common HTML names.
- Depth counters that rely on end tags (nav, a): an unclosed <nav> hid every later link, and an unclosed <a> was never recorded.
- Indexing an element's children once in the feed parser to speed up 500 items x 1,000 children: no change (255 ms before and after); the time is the parser's. Kept, as it is simpler to bound.

## Log

- 2026-11-15T22:33:55Z [li] created (todo)
- 2026-11-16T02:20:09Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-16T02:35:18Z [implementer-1] Installed fast-xml-parser 5.12.1 with the installed npm 10.9.2 (no crash; npm reports 4 moderate audit advisories, not touched). Probed it in Node and HTMLRewriter in workerd before writing code. Design: lib/text.ts (linear HTML-to-text and entity decoding), lib/feed-parse.ts (fast-xml-parser with processEntities:false, preserveOrder, maxNestedTags 64; own date parsing), lib/page-links.ts (HTMLRewriter scan, feed discovery, article-link choice), lib/site-reader.ts (fetch through safeFetch, KV keys, first-seen record), routes/sites.ts and routes/feed.ts.
- 2026-11-16T02:50:57Z [implementer-1] Decisions: (1) KV site key hashes mode + page URL + feed URL, because the endpoint is open and a key of page URL and mode alone would let anyone fill a known page's entry from their own feed. (2) The 7-day window is applied at fetch and again on every answer. (3) Feed items with no readable date: published null, dateSource 'none' (a third value beside published/first_seen), sorted last, never age out. Dates up to a day ahead count as now; further ahead the item is dropped. (4) Resolve fetches up to two advertised feeds and uses the first that really parses, else links mode (the brief asked only for the safe-URL check). (5) 'Same registrable host' is the same host name ignoring www., since there is no public-suffix list. (6) 'Deeper than the page' has an exception for a last segment that is a headline-like slug, so /story/x counts beside /category/science/. (7) A link shared by two sites is returned under the lower index. (8) Request budget 20 s, 6 sites at a time, 6 s per site, measured with performance.now().
- 2026-11-16T02:50:57Z [implementer-1] Page reader work budget: HTMLRewriter cannot be stopped and each handler call costs 4 to 6 microseconds; 100,000 headings inside one link (1 MB) took 2.2 s and 100,000 links 1.4 s. Now every handler call is counted (limit 40,000) and the page is fed in 16 KB pieces that stop once the count or the 1,500-link limit is reached: the same inputs take about 250 ms and 35 ms. Pinned by a test that fails without the budget.
- 2026-11-16T02:50:57Z [implementer-1] onEndTag: it throws for a self-closing <a/> or <title/> inside inline <svg>, and a throw in a handler ends the whole transform, so a page with such an icon in its header gave ok:true and no items. All registrations go through atEnd() now; test added. An unclosed element gets its end call only when an ancestor closes, or never: an open <a> is finished by the next <a> or at the end of the page, and <main> resets the nav/footer count.
- 2026-11-16T02:50:57Z [implementer-1] Live check, once, local wrangler dev on port 8788 (stopped): three public section pages, one more than the brief allowed. One resolved to mode feed with the site-wide feed (the page advertises no section feed), one to links mode with 9 first-seen headlines, one refused the request (fetch_failed). Nothing from them is in the repo; the local dev KV under api/ holds those items until it expires.
- 2026-11-16T02:50:57Z [implementer-1] Verified: npm test (11 files, all pass), npx tsc --noEmit clean, npm run openapi regenerated openapi/openapi.json with /v1/sites/resolve and /v1/feed. iOS build NOT run, on the lead's instruction. Cloudflare limits checked in cloudflare-docs: /v1/feed needs the Paid plan (Free: 10 ms CPU, 50 outside subrequests).
- 2026-11-16T02:50:57Z [implementer-1] tried: Stopping HTMLRewriter by throwing from a handler: it rejects the transform, but workerd also prints an uncaught exception for every stop. Feeding the body in pieces and ending the input instead.
- 2026-11-16T02:50:58Z [implementer-1] tried: fast-xml-parser without preserveOrder: text around CDATA and inside nested XHTML lost its order ('pre <![CDATA[x]]> post' came back as 'prepost'). preserveOrder with trimValues:false keeps it.
- 2026-11-16T02:50:58Z [implementer-1] tried: fast-xml-parser with processEntities on: its limits can only be lowered to one custom entity, not none. Turned off entirely; our own decodeEntities handles the XML five, numeric and common HTML names.
- 2026-11-16T02:50:58Z [implementer-1] tried: Depth counters that rely on end tags (nav, a): an unclosed <nav> hid every later link, and an unclosed <a> was never recorded.
- 2026-11-16T02:50:58Z [implementer-1] tried: Indexing an element's children once in the feed parser to speed up 500 items x 1,000 children: no change (255 ms before and after); the time is the parser's. Kept, as it is simpler to bound.
- 2026-11-16T02:51:19Z [implementer-1] status: in-progress → review
