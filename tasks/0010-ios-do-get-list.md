---
id: 10
title: iOS: Do/Get list
status: in-progress
owner: implementer-2
depends_on: [4]
created: 2026-11-15T22:33:55Z
updated: 2026-11-16T00:17:40Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. The do/get button opens one screen with two sections, DO on top and GET below, each with its own items, circle checkbox, text field and ADD button (ref-img/00-do-get-list.png; the mockup shows GET on top, the user asked for DO on top). SwiftData ListItem (kind, title, done, created). Stored on the device only for now.

## Acceptance criteria

- [ ] Items can be added to and checked off in each section and survive relaunch
- [ ] Simulator screenshot recorded in the task log; layout resembles the mockup with DO on top
- [ ] Tests pass on both simulators

## Relevant files

- ios/Seasign/Lists/

## What's been tried


## Log

- 2026-11-15T22:33:55Z [li] created (todo)
- 2026-11-16T00:17:40Z [implementer-2] status: todo → in-progress — claimed by implementer-2
