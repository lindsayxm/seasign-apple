---
id: 180
title: Voice checks on the user's iPhone (waits until more features are built)
status: backlog
owner: 
depends_on: []
created: 2026-11-23T02:02:56Z
updated: 2026-11-23T02:02:56Z
---

## Goal

The user decided on 2026-11-22 to do the on-device voice checks later, after more features. The Simulator cannot recognise speech (kAFAssistantErrorDomain 1101, no on-device model), so these need a real iPhone. Needs first: the user's go-ahead for a device install (signing), and the API reachable from the phone (the Debug build points at localhost:8787; either the deploy, #157, or a base URL for the Mac's network address).

## Acceptance criteria

- [ ] The user's list from #172's log is run on the phone: prompts only on the first mic tap and both texts read; a spoken event gives the right draft; the reading uses the chosen voice and does not close the popup by hearing itself; 'confirm' adds, 'cancel' and 'not yet ... confirm' do not; silence says Nothing was heard; spoken times ('three thirty pm', 'half past four', 'ten past three'); Speak again while a problem is read still hears; a tap on the popup text stops the reading; a call or Siri stops listening
- [ ] Whether the recognizer ends its own result before the 1.5 s pause (then a spoken confirm never counts) is known and, if so, fixed
- [ ] Findings logged as tasks

## Relevant files


## What's been tried


## Log

- 2026-11-23T02:02:56Z [li] created (backlog)
