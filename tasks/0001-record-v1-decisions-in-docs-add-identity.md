---
id: 1
title: Record v1 decisions in docs, add identity file, commit ref-img
status: review
owner: lead
depends_on: []
created: 2026-11-15T22:33:08Z
updated: 2026-11-15T22:35:20Z
---

## Goal

Record the decisions in plans/2026-11-15-v1-build.md (copy of the approved plan at /Users/li/.claude/plans/quizzical-growing-kay.md). Update BUILD.md (calendar links instead of device calendars, followed sites with user categories, AI search settings, >> = 7-day history, asterisk = Saved, v1 exclusions). Update AGENTS.md STACK (calendar .ics links parsed in the Worker with ical.js, feeds with fast-xml-parser + HTMLRewriter, AI search adapters via fetch, bundled fonts; EventKit/Speech/App Intents/WidgetKit/notifications marked later, not v1) and SUBDIRECTORIES (ref-img/). Update memory/architecture.md, the calendar lines in .claude/skills/scaffold-app/SKILL.md and .claude/skills/task-workflow/SKILL.md, and add decision files in memory/decisions/. Add app-identity.xcconfig at the root with placeholder bundle ID and empty team ID. Commit ref-img/ in full.

## Acceptance criteria

- [ ] plans/2026-11-15-v1-build.md exists and matches the approved plan
- [ ] BUILD.md, AGENTS.md, memory/architecture.md and both skills no longer describe EventKit as the v1 calendar source and describe calendar links, sites with categories, AI search, history and Saved
- [ ] memory/decisions/ has dated decision files for calendars, signed-out storage, feed and AI search, and app identity
- [ ] app-identity.xcconfig exists at the root with APP_BUNDLE_ID = com.example.seasign and an empty DEVELOPMENT_TEAM
- [ ] ref-img/ is committed, and git status is clean

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
