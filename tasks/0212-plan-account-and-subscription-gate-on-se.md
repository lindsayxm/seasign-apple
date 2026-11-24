---
id: 212
title: Plan: account and subscription gate on Settings (replaces the design of tasks 13 and 14)
status: done
owner: lead
depends_on: []
created: 2026-11-24T15:54:17Z
updated: 2026-11-24T19:05:41Z
---

## Goal

User, 2026-11-24: Settings is behind an account plus a paid subscription taken together; zip code stays free; no AI features on a lapsed subscription, ever. Research Sign in with Apple's email and the App Review risk, then write plans/2026-11-24-account-and-subscription.md and the decision record. No code.

## Acceptance criteria

- [x] Plan saved in plans/ with the research findings, phases, the user's actions and open decisions
- [x] Hard rule (no AI on a lapsed subscription) recorded in memory/decisions
- [x] The user has approved the plan or asked for changes

## Relevant files


## What's been tried


## Log

- 2026-11-24T15:54:17Z [li] created (todo)
- 2026-11-24T15:54:17Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-24T15:55:22Z [lead] criterion 1 met: Plan saved in plans/ with the research findings, phases, the user's actions and open decisions
- 2026-11-24T15:55:23Z [lead] criterion 2 met: Hard rule (no AI on a lapsed subscription) recorded in memory/decisions
- 2026-11-24T15:55:23Z [lead] Lead: plan drafted (plans/2026-11-24-account-and-subscription.md) and decision recorded. Research: Apple's Sign in with Apple docs read in full through sosumi; the App Review Guidelines (dated 2026-10-16) read through a summarising fetch for 3.1 onward, so quotes need a check on the live page. Waiting for the user's approval and the six open decisions.
- 2026-11-24T16:14:53Z [lead] Lead: second draft with the user's answers (sites, purchase-first order, zip row on the popup, 2.99 a month with no trial, sync and push pause on lapse, AI key work on hold, no email collection). Still open: paid-but-not-signed-in behaviour, subscriber's starting sites, terms and privacy pages. The user said not to start implementing.
- 2026-11-24T16:22:03Z [lead] Lead: third draft: purchase-first confirmed, subscriber keeps the three sites (removable), starting list items Go outside / Concert tickets, terms page artisan.technology/seasign-terms. One point left to confirm: list items on every fresh install or only after subscribing.
- 2026-11-24T16:46:57Z [lead] User: the two starting list items appear on every fresh install, no subscription needed. Plan updated; nothing left to confirm except the AI key (on hold) and a later free trial. Waiting for the user's word to start.
- 2026-11-24T19:05:41Z [lead] User, 2026-11-24: 'after these issues finish begin the plan we wrote for subscription'. Plan marked approved; BUILD.md and AGENTS.md STACK updated to match. Starter sites checked through the local API (all three return headlines; Wired to be seeded with its science feed address for dates).
- 2026-11-24T19:05:41Z [lead] criterion 3 met: The user has approved the plan or asked for changes
- 2026-11-24T19:05:41Z [lead] status: in-progress → review
- 2026-11-24T19:05:41Z [lead] status: review → done
