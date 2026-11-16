---
id: 21
title: iOS: AI search hardening from the task 12 review
status: done
owner: implementer-2
depends_on: []
created: 2026-11-16T13:56:09Z
updated: 2026-11-16T14:25:15Z
---

## Goal

From the task 12 review. (1) Medium, before any deploy: SeasignAPI uses a plain URLSessionTransport (ios/Seasign/API/SeasignAPI.swift:22-27), which follows redirects and re-sends the X-LLM-Key header to the redirect target (reproduced by the reviewer with a test key: a 307 from one local server to another delivered the header). Send discover through a URLSession whose task delegate refuses redirects (treat any redirect as a failure), and consider refusing redirects for every API call since none is expected; add a test with a local or stubbed redirect proving the second host never receives the key. (2) Guard in discover: outside DEBUG, refuse to attach the key unless the base URL scheme is https. (3) Interest length: iOS (AISearch/AIRules.swift:81) cuts each interest to 80 Swift Characters, the API allows 80 code points and 400 UTF-16 units, so emoji-heavy interests get a 400 forever; measure the way the API does (80 Unicode scalars and 400 UTF-16 units) and add tests. Send a time zone only if it is one the API will accept (IANA names; drop the field rather than send a doubtful one). (4) If the Keychain cannot be read at launch (before first unlock), hasKey stays false until relaunch (AISearch/AISearchModel.swift:104-110): re-check when the app becomes active and when Settings opens, and distinguish 'no key' from 'could not read'. (5) In DEBUG, if FeedModel.sample throws under -debugAI, SeasignApp falls back to the real AI model and real Keychain: fall back to the in-memory key store instead. No new dependencies; nothing under api/ changes.

## Acceptance criteria

- [x] A test proves a redirect on discover fails and the key is not sent to the redirect target
- [x] Outside DEBUG a non-https base URL never receives the key (test)
- [x] Interest and time zone rules match the API's, with tests; tests pass on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2)

## Relevant files

- ios/Seasign/API/SeasignAPI.swift
- ios/Seasign/AISearch/
- ios/Seasign/SeasignApp.swift
- ios/SeasignTests/

## What's been tried

- LocalHTTPServer with NWParameters.acceptLocalOnly = true: in the Simulator every loopback connection was reset before newConnectionHandler ran (client saw -1005, server recorded nothing). Leave it off; requiredInterfaceType = .loopback is enough.
- Time zone rule 'TimeZone.knownTimeZoneIdentifiers only': drops Asia/Kolkata (Foundation lists only Asia/Calcutta; TimeZone(identifier: "Asia/Kolkata") works). Widened to Area/Place names TimeZone(identifier:) accepts unchanged. Node 22 (ICU 76, tz 2024b) Intl accepts Asia/Kolkata, Asia/Calcutta, CST, EST, US/Eastern, +05:00; refuses GMT-0500 and Mars/Olympus_Mons. workerd not checked.

## Log

- 2026-11-16T13:56:09Z [li] created (todo)
- 2026-11-16T13:56:09Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-16T14:05:23Z [implementer-2] Item 1: wrote RedirectTests with two real loopback listeners (LocalHTTPServer, Network.framework NWListener; acceptLocalOnly must stay off, it resets every connection in the Simulator). Run against the unfixed code on iPhone 16 (18.3.1) and iPhone 17 (27.2): for 301, 302, 303, 307 and 308 the redirect target received the request with X-LLM-Key (15 issues + 1 on the other-routes test, on each runtime). swift-openapi-urlsession 1.4.0 platformDefault is streaming, which sets a per-task delegate (BidirectionalStreamingURLSessionDelegate, no redirect method).
- 2026-11-16T14:16:26Z [implementer-2] Item 1 fix: SeasignAPI.session (one shared ephemeral URLSession: no cookie store, no URL cache, no credential store, delegate RefuseRedirects passes nil to willPerformHTTPRedirection) and SeasignAPI.defaultTransport (URLSessionTransport over it, httpBodyProcessingMode .buffered so no per-task delegate is installed). Every SeasignAPI() uses it. A refused redirect completes with the 3xx response, which every wrapper already maps to its payload-free unavailable. After the fix RedirectTests pass on both runtimes (5 runs each). Experiment, reverted: with .platformDefault (streaming) the same tests also pass on both runtimes, i.e. the streaming task delegate does not take over redirects; buffered kept anyway so the session delegate is the only one.
- 2026-11-16T14:19:39Z [implementer-2] Items 2-5: (2) SeasignAPI(keyNeedsHTTPS:) defaults to keyNeedsHTTPSByDefault (true outside DEBUG); discover throws unavailable before any request when the base URL scheme is not https; tested both ways with the stub transport (stub.count == 0). (3) InterestList counts Unicode scalars (<=80) and UTF-16 (<=400) like the API's cleanInterest, cuts on Character boundaries, drops an interest whose first character alone is over 80 scalars with a 'too long' message; tests with flags, families, tag flags, e+U+0301 at both sides of the boundary. Time zone: SearchDay.ianaName(identifier:) also applied inside discover; Asia/Kolkata is not in Foundation's known list, so Area/Place names Foundation recognises are accepted too; CST/GMT-0500/unknown left out. (4) KeyStatus saved/missing/unknown; unknown never sends, never asks for the key, re-read on run(), scene active, Settings appear. (5) -debugAI falls back to AISearchModel.debugFallback (InMemoryKeyStore with the fake key, frozen). Full suite passes on iPhone 16 (18.3.1) and iPhone 17 (27.2); Release builds for both; Release binary has no test-key/debugAI/InMemoryKeyStore strings.
- 2026-11-16T14:23:14Z [implementer-2] tried: LocalHTTPServer with NWParameters.acceptLocalOnly = true: in the Simulator every loopback connection was reset before newConnectionHandler ran (client saw -1005, server recorded nothing). Leave it off; requiredInterfaceType = .loopback is enough.
- 2026-11-16T14:23:14Z [implementer-2] tried: Time zone rule 'TimeZone.knownTimeZoneIdentifiers only': drops Asia/Kolkata (Foundation lists only Asia/Calcutta; TimeZone(identifier: "Asia/Kolkata") works). Widened to Area/Place names TimeZone(identifier:) accepts unchanged. Node 22 (ICU 76, tz 2024b) Intl accepts Asia/Kolkata, Asia/Calcutta, CST, EST, US/Eastern, +05:00; refuses GMT-0500 and Mars/Olympus_Mons. workerd not checked.
- 2026-11-16T14:23:33Z [implementer-2] status: in-progress → review
- 2026-11-16T14:25:15Z [implementer-2] criterion 1 met: A test proves a redirect on discover fails and the key is not sent to the redirect target
- 2026-11-16T14:25:15Z [implementer-2] criterion 2 met: Outside DEBUG a non-https base URL never receives the key (test)
- 2026-11-16T14:25:15Z [implementer-2] criterion 3 met: Interest and time zone rules match the API's, with tests; tests pass on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2)
- 2026-11-16T14:25:15Z [implementer-2] review (lead): ran the suite on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2) at 2539d49: 341 tests passed on each, including RedirectTests (two loopback servers; the implementer showed it failing on the old code). Read the redirect delegate: completionHandler(nil) on one shared ephemeral session used by every API call. Accepted as left open: the wider Area/Place time zone rule, the unknown-key Settings state not seen on screen, the https refusal counting against the cap.
- 2026-11-16T14:25:15Z [implementer-2] status: review → done
