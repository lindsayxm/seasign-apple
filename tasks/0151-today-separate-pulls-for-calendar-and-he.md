---
id: 151
title: Today: separate pulls for calendar and headlines, each with its own spinner
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-19T16:59:34Z
updated: 2026-11-19T16:59:34Z
---

## Goal

User, 2026-11-19: keep calendar and headline refresh separate. Pulling down on the calendar area refreshes events and the sky (temperature, conditions), not headlines; pulling down on the sea/headline area refreshes headlines only. Temperature and conditions refresh silently in the background every 10 minutes.

## Acceptance criteria

- [ ] A pull that starts above the horizon (header, events box, sky) runs events.refresh(force: true) and the sky refresh, and sends no feed request. A pull that starts at or below the horizon (the sea and the article titles) runs the feed refresh only, and sends no calendar or sky request. Neither ever calls anything on the AI model. Rule kept as a pure, tested function
- [ ] The sky pull really fetches: add a forced sky refresh if the sky model has a freshness rule that would otherwise skip it; it must still honour any rate-limit delay
- [ ] Calendar spinner: at the upper right corner of the events box (inside its padding), shown only while that pull runs. Headline spinner: at the upper right of the headline area, level with the first title row, with the same x centre as the calendar spinner. The old spinner by the wind line is gone. Nothing else moves; both are hidden at rest
- [ ] The sky (temperature, conditions) refreshes in the background every 10 minutes while the app is open, with no spinner or other visible sign; confirm the interval in code and by a test or the server log. The minute-by-minute events refresh and the refresh on return to the foreground stay as they are
- [ ] Verified on the iPhone 16 Pro Max simulator against the wrangler dev already on port 8787: a calendar-area pull adds a calendar POST and a sky GET and no feed POST; a headline-area pull adds a feed POST only. Screenshots of each spinner. Taps on titles, the three buttons and the all-publications mark still work
- [ ] Suite passes on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2

## Relevant files

- ios/Seasign/Today
- ios/Seasign/Feed
- ios/Seasign/Calendar
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-19T16:59:34Z [lead] created (todo)
- 2026-11-19T16:59:34Z [implementer-1] status: todo → in-progress — claimed by implementer-1
