---
id: 216
title: iOS subscription A2: the AI rule: no AI unless Subscribed
status: backlog
owner: 
depends_on: [215]
created: 2026-11-24T19:09:50Z
updated: 2026-11-24T19:09:50Z
---

## Goal

Read plans/2026-11-24-account-and-subscription.md (phase A), memory/decisions/2026-11-24-subscription-gate-and-ai-lapse-rule.md and memory/notes/2026-11-24-storekit-research.md first. HARD RULE: no AI features on a lapsed subscription, ever. One pure function answers whether AI may run from the subscription state (and signed-in, which does not block yet: phase C turns that on); it says no for free, lapsed and unknown. Every AI path goes through it: SearchGate (automatic and manual search), the Use My List / Let AI Search toggle and its precondition message, FeedModel's display of AI-found items already cached (Today, History; Saved follows the user's answer in the decision file), and the launch-time check that moves the mode back to Use My List. On a change to not-Subscribed the mode is set to Use My List. Do not change the AI key section in Settings otherwise (on hold by the user). Until task A3 lands, production still treats everyone as Subscribed through one named default so nothing visible changes; a test pins that the default is in exactly one place.

## Acceptance criteria

- [ ] Tests: for each of free, lapsed, unknown no search is sent (automatic or manual), the toggle cannot move to AI, cached AI-found items are not shown on Today or History, and a lapse sets the mode to Use My List; subscribed behaves as today
- [ ] A reviewer has traced every call site that sends POST /v1/discover or shows an AI-found item and confirmed it goes through the rule
- [ ] Suite passes on both runtimes

## Relevant files

- ios/Seasign/AISearch
- ios/Seasign/Feed
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-24T19:09:50Z [li] created (backlog)
