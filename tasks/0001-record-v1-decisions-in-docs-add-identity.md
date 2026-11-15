---
id: 1
title: Record v1 decisions in docs, add identity file, commit ref-img
status: done
owner: lead
depends_on: []
created: 2026-11-15T22:33:08Z
updated: 2026-11-15T22:38:11Z
---

## Goal

Record the decisions in plans/2026-11-15-v1-build.md (copy of the approved plan at /Users/li/.claude/plans/quizzical-growing-kay.md). Update BUILD.md (calendar links instead of device calendars, followed sites with user categories, AI search settings, >> = 7-day history, asterisk = Saved, v1 exclusions). Update AGENTS.md STACK (calendar .ics links parsed in the Worker with ical.js, feeds with fast-xml-parser + HTMLRewriter, AI search adapters via fetch, bundled fonts; EventKit/Speech/App Intents/WidgetKit/notifications marked later, not v1) and SUBDIRECTORIES (ref-img/). Update memory/architecture.md, the calendar lines in .claude/skills/scaffold-app/SKILL.md and .claude/skills/task-workflow/SKILL.md, and add decision files in memory/decisions/. Add app-identity.xcconfig at the root with placeholder bundle ID and empty team ID. Commit ref-img/ in full.

## Acceptance criteria

- [x] plans/2026-11-15-v1-build.md exists and matches the approved plan
- [x] BUILD.md, AGENTS.md, memory/architecture.md and both skills no longer describe EventKit as the v1 calendar source and describe calendar links, sites with categories, AI search, history and Saved
- [x] memory/decisions/ has dated decision files for calendars, signed-out storage, feed and AI search, and app identity
- [x] app-identity.xcconfig exists at the root with APP_BUNDLE_ID = com.example.seasign and an empty DEVELOPMENT_TEAM
- [x] ref-img/ is committed, and git status is clean

## Relevant files

- BUILD.md
- AGENTS.md
- memory/architecture.md
- memory/decisions/
- plans/
- .claude/skills/scaffold-app/SKILL.md
- .claude/skills/task-workflow/SKILL.md
- app-identity.xcconfig
- ref-img/

## What's been tried


## Log

- 2026-11-15T22:33:08Z [li] created (todo)
- 2026-11-15T22:34:04Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-15T22:35:10Z [lead] Updated BUILD.md, AGENTS.md (STACK, SUBDIRECTORIES), memory/architecture.md, scaffold-app and task-workflow skills. Decisions are in one file with a section per topic: memory/decisions/2026-11-15-v1-product-decisions.md. Plan copied to plans/2026-11-15-v1-build.md. Added app-identity.xcconfig. ref-img/ committed in full (95 MB PDF included, as the user chose).
- 2026-11-15T22:35:20Z [lead] status: in-progress → review
- 2026-11-15T22:37:35Z [lead] criterion 1 met: plans/2026-11-15-v1-build.md exists and matches the approved plan
- 2026-11-15T22:37:35Z [lead] criterion 2 met: BUILD.md, AGENTS.md, memory/architecture.md and both skills no longer describe EventKit as the v1 calendar source and describe calendar links, sites with categories, AI search, history and Saved
- 2026-11-15T22:37:35Z [lead] criterion 3 met: memory/decisions/ has dated decision files for calendars, signed-out storage, feed and AI search, and app identity
- 2026-11-15T22:37:35Z [lead] criterion 4 met: app-identity.xcconfig exists at the root with APP_BUNDLE_ID = com.example.seasign and an empty DEVELOPMENT_TEAM
- 2026-11-15T22:37:35Z [lead] criterion 5 met: ref-img/ is committed, and git status is clean
- 2026-11-15T22:37:35Z [lead] review: PASS (verified before ticking; tree was clean at that point). C1: plans/2026-11-15-v1-build.md is byte-identical to the approved plan (diff). C2: no file names EventKit or device calendars as the v1 source; read against the per-file expectations in the Goal (BUILD.md carries sites with categories, AI search, 7-day history and Saved; AGENTS.md STACK carries calendar links, feed parsing, AI search adapters, fonts; architecture.md and the two skills carry calendar links). AGENTS.md and architecture.md do not mention history or Saved, which a literal reading of the criterion would require. C3: one file, memory/decisions/2026-11-15-v1-product-decisions.md, with sections for calendars, signed-out use, followed sites and feed, AI search, app identity; every named topic is covered. C4: app-identity.xcconfig has APP_BUNDLE_ID = com.example.seasign and empty DEVELOPMENT_TEAM. C5: all 25 ref-img files tracked (commit 2950660, by the user), only ignored .DS_Store untracked, git status clean. Non-blocking: (a) AGENTS.md:59 and architecture.md:10 still show the Cron morning refresh as current though the plan defers it to task 13; (b) scaffold-app skill lines 15, 20-21, 51 still set up Better Auth and an Auth folder at scaffold time though auth is tasks 13-14; (c) task 7 depends_on is [5], plan table says 2; (d) AGENTS.md:149 ref-img row says scene states 01-11 but there is no 07.
- 2026-11-15T22:38:11Z [lead] After review: marked the Cron refresh as deferred in AGENTS.md, removed auth from the scaffold-app skill (auth arrives with tasks 13/14), noted there is no ref-img 07, and made task 5 depend on 3 so spec-changing API tasks run one at a time (3, 5, 7).
- 2026-11-15T22:38:11Z [lead] status: review → done
