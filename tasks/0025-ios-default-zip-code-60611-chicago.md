---
id: 25
title: iOS: default zip code 60611 (Chicago)
status: done
owner: lead
depends_on: []
created: 2026-11-16T16:47:22Z
updated: 2026-11-16T16:51:31Z
---

## Goal

The user asked for the default zip to be Chicago 60611. On a fresh install (no Settings row yet) the app starts with zip 60611, so Today shows Chicago's weather, sun and moon without any setup. The user can still change or remove it in Settings; a removed zip stays removed (neutral scene and the set-your-zip prompt). Existing stores keep whatever they have.

## Acceptance criteria

- [x] A new store starts with zip 60611; an existing Settings row is not changed; removing the zip leaves it nil (unit tests)
- [x] Tests pass on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2)

## Relevant files

- ios/Seasign/Store/SkyStore.swift
- ios/SeasignTests/

## What's been tried


## Log

- 2026-11-16T16:47:22Z [li] created (todo)
- 2026-11-16T16:47:22Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-16T16:51:30Z [lead] Default written only when the settings row is first created (SkyStore.defaultZip = 60611 in ios/Seasign/Store/SkyStore.swift), so existing stores and a removed zip are untouched. Tests: aFreshInstallStartsInChicagoWithNoSkyYet, aRemovedZipStaysRemoved, anExistingZipIsNotReplacedByTheDefault. 380 tests passed on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2). BUILD.md gained a DEFAULT ZIP line. Not seen on screen: the simulators already hold a saved zip, so a fresh-install launch was not screenshotted.
- 2026-11-16T16:51:30Z [lead] status: in-progress → review
- 2026-11-16T16:51:30Z [lead] criterion 1 met: A new store starts with zip 60611; an existing Settings row is not changed; removing the zip leaves it nil (unit tests)
- 2026-11-16T16:51:31Z [lead] criterion 2 met: Tests pass on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2)
- 2026-11-16T16:51:31Z [lead] status: review → done
