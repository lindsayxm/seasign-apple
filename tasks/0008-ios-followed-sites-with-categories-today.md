---
id: 8
title: iOS: followed sites with categories, Today headlines, reading view
status: done
owner: implementer-2
depends_on: [4]
created: 2026-11-15T22:33:55Z
updated: 2026-11-16T04:43:50Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. Settings gets a Sites section: enter a page URL and a user-defined category, resolved through /v1/sites/resolve (SwiftData Site). On open, the app calls /v1/feed, stores items as FeedItem and prunes those older than 7 days. Today shows only the newest headlines published since yesterday that fit in the water area, without scrolling. Tapping a headline opens the reading view (ref-img/00-reading.png): source, title, date, the site's excerpt, a save button, and Read on original site.

## Acceptance criteria

- [x] Adding a site with a category shows its recent headlines on Today
- [x] Today never scrolls and shows only headlines that fit
- [x] The reading view shows the excerpt and opens the original article
- [x] Simulator screenshots of Today with headlines and of the reading view recorded in the task log; tests pass on both simulators

## Relevant files

- ios/Seasign/Settings/
- ios/Seasign/Today/
- ios/Seasign/Feed/
- ios/Seasign/Reading/

## What's been tried


## Log

- 2026-11-15T22:33:55Z [li] created (todo)
- 2026-11-16T03:45:09Z [li] From task 7: /v1/feed items have published (never null) and dateSource published|first_seen; excerpt is null in links mode; /v1/sites/resolve returns ok, title, url, mode feed|links, feedUrl (feed mode only) and linkCount (warn in Settings when a links-mode page has 0); per-site errors invalid_url, blocked_host, fetch_failed, timeout, too_large, not_feed, not_html. Request bodies over 64 KB are refused. Do not start until task 7 has passed its second review.
- 2026-11-16T04:13:53Z [li] depends on: #4, #7 → #4
- 2026-11-16T04:13:53Z [li] lead: dependency on #7 removed so this can start now. #7's routes and spec passed two reviews; its last round changes no schema (text-run cap, text cleaning, date parsing, body cap), so the generated client will not change.
- 2026-11-16T04:13:53Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-16T04:28:32Z [implementer-2] Built in b7e0b09: Site (user store), FeedItem + CachedFeedState (cache store), SeasignAPI.resolveSite/feed with payload-free SitesFailure, FeedModel (resolve-and-add, refresh at launch/foreground at most every 15 min, upsert by link keeping firstFetchedAt, 7-day prune, per-site status), Sites section in Settings, HeadlinesColumn (since start of yesterday in zip zone else phone zone; count from CapsWrapper line counts via HeadlineFit, max 5, no ViewThatFits/scroll), ReadingView (openURL, https only via ArticleLink), -debugFeed YES sample. 207 tests pass on iOS 27.2 (iPhone 17).
- 2026-11-16T04:36:17Z [implementer-2] Screenshots (iOS 27.2, iPhone 17): Today with -debugFeed sample /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task8/today-headlines.png; reading view /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task8/reading-view.png; Settings Sites section (sample, one site failing with timeout) /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task8/settings-sites.png; Today live against wrangler dev /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task8/today-live.png. Tests: 207 pass on iPhone 17 (27.2) and iPhone 16 (18.3.1). Live check: api tsc passed, wrangler dev on 8787; added www.nasa.gov/news/ (links mode, 17 articles) and feeds.arstechnica.com/arstechnica/science (feed mode, 14 articles) in the Simulator; Today showed 5 real two-line headlines newest first; reading view showed the Ars excerpt; Read on original site opened Safari. Server stopped. Choices: openURL (default browser, user's cookies/subscriptions) over SFSafariViewController; no-sites prompt line on Today, empty water when nothing since yesterday; max 5 headlines; removing a site deletes its cached items; save control drawn dimmed and inert (task 9).
- 2026-11-16T04:42:07Z [implementer-2] Remove-with-confirmation checked live on iPhone 17: relaunched with the server stopped (cached headlines stayed, statuses unchanged), removed NASA then Ars through the dialog; each site's headlines left Today at once and the 'Follow sites in Settings' line returned. The dialog now holds the site's id and title as values and deletes in a Task after it closes. Tests 207/207 on both runtimes again; Release build clean (sample compiled out).
- 2026-11-16T04:42:07Z [implementer-2] status: in-progress → review
- 2026-11-16T04:43:50Z [implementer-2] criterion 1 met: Adding a site with a category shows its recent headlines on Today
- 2026-11-16T04:43:50Z [implementer-2] criterion 2 met: Today never scrolls and shows only headlines that fit
- 2026-11-16T04:43:50Z [implementer-2] criterion 3 met: The reading view shows the excerpt and opens the original article
- 2026-11-16T04:43:50Z [implementer-2] criterion 4 met: Simulator screenshots of Today with headlines and of the reading view recorded in the task log; tests pass on both simulators
- 2026-11-16T04:43:50Z [implementer-2] review (lead): ran the suite on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2): 207 tests passed on each. Viewed today-live.png (five real headlines from the implementer's live check against wrangler dev, no scrolling) and reading-view.png (publication, category, date, title, excerpt, Read on original site). Light visual review at the user's request. Accepted choices: at most 5 headlines on Today; removing a site deletes its cached items (so they leave History too); Read on original site opens the system browser.
- 2026-11-16T04:43:50Z [implementer-2] status: review → done
