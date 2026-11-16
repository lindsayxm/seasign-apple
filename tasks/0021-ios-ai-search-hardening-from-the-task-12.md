---
id: 21
title: iOS: AI search hardening from the task 12 review
status: in-progress
owner: implementer-2
depends_on: []
created: 2026-11-16T13:56:09Z
updated: 2026-11-16T13:56:09Z
---

## Goal

From the task 12 review. (1) Medium, before any deploy: SeasignAPI uses a plain URLSessionTransport (ios/Seasign/API/SeasignAPI.swift:22-27), which follows redirects and re-sends the X-LLM-Key header to the redirect target (reproduced by the reviewer with a test key: a 307 from one local server to another delivered the header). Send discover through a URLSession whose task delegate refuses redirects (treat any redirect as a failure), and consider refusing redirects for every API call since none is expected; add a test with a local or stubbed redirect proving the second host never receives the key. (2) Guard in discover: outside DEBUG, refuse to attach the key unless the base URL scheme is https. (3) Interest length: iOS (AISearch/AIRules.swift:81) cuts each interest to 80 Swift Characters, the API allows 80 code points and 400 UTF-16 units, so emoji-heavy interests get a 400 forever; measure the way the API does (80 Unicode scalars and 400 UTF-16 units) and add tests. Send a time zone only if it is one the API will accept (IANA names; drop the field rather than send a doubtful one). (4) If the Keychain cannot be read at launch (before first unlock), hasKey stays false until relaunch (AISearch/AISearchModel.swift:104-110): re-check when the app becomes active and when Settings opens, and distinguish 'no key' from 'could not read'. (5) In DEBUG, if FeedModel.sample throws under -debugAI, SeasignApp falls back to the real AI model and real Keychain: fall back to the in-memory key store instead. No new dependencies; nothing under api/ changes.

## Acceptance criteria

- [ ] A test proves a redirect on discover fails and the key is not sent to the redirect target
- [ ] Outside DEBUG a non-https base URL never receives the key (test)
- [ ] Interest and time zone rules match the API's, with tests; tests pass on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2)

## Relevant files

- ios/Seasign/API/SeasignAPI.swift
- ios/Seasign/AISearch/
- ios/Seasign/SeasignApp.swift
- ios/SeasignTests/

## What's been tried


## Log

- 2026-11-16T13:56:09Z [li] created (todo)
- 2026-11-16T13:56:09Z [implementer-2] status: todo → in-progress — claimed by implementer-2
