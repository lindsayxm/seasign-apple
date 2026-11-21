---
id: 158
title: iOS: push for Google Calendar: Push Notifications capability, device-token registration, background push handling, channel upkeep
status: in-progress
owner: implementer-1
depends_on: [156]
created: 2026-11-20T22:28:10Z
updated: 2026-11-21T13:53:09Z
---

## Goal

Plan plans/2026-11-19-google-calendar-push.md, task E. The app registers for remote notifications, gives the Worker its APNs device token with the chosen Google calendars (POST /v1/google/watch), reloads Google events when a background push arrives, and keeps the channels alive. Signing changes here (Push Notifications capability, aps-environment entitlement, Background Modes: remote notifications) were approved by the user in the plan on 2026-11-19. Look the Apple APIs up in sosumi first.

## Acceptance criteria

- [ ] project.yml: Push Notifications entitlement (aps-environment) and UIBackgroundModes remote-notification, through XcodeGen only; xcodegen generate; the app builds for the Simulator on both runtimes. No user-visible notification permission is asked for (background pushes need none)
- [ ] Registration: the app calls registerForRemoteNotifications at launch when Google is connected; on a device token it calls postGoogleWatch with the calendars that are on, the hex token and the environment (sandbox for Debug, production for Release); it re-registers when the chosen calendars change, when the device token changes, and when the app opens with a channel under 2 days from expiry; per-calendar errors and our 429 show a short status in Settings and never block polling
- [ ] Disconnect and sign-in expiry call postGoogleUnwatch (best effort) before the token is dropped; the device token is kept only in memory or the user store, never logged
- [ ] A background push with type calendar-changed triggers one Google events refresh and calls the completion handler with newData / noData / failed within the system's time limit; pushes arriving close together are coalesced into one fetch; the app still fetches on return to the foreground
- [ ] Polling stays as the fallback: the 5-second poll continues while no channel is registered (Simulator without the deployed API, registration failed); when a channel is live the poll slows to once a minute (constant in one place)
- [ ] Tests (Swift Testing, mocked transport): registration body, re-registration triggers, expiry rule, unwatch on disconnect, push handling and coalescing, poll rate with and without a channel. Suite passes on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2. Do not drive, screenshot or log the Pro Max simulator's Google account data

## Relevant files

- ios/project.yml
- ios/Seasign

## What's been tried


## Log

- 2026-11-20T22:28:10Z [li] created (backlog)
- 2026-11-20T22:42:44Z [li] Lead: from the #156 fixes: the app must run at most one watch or unwatch at a time per device (single-flight, the latest wanted state wins), because the API keeps the channels of whichever request commits last, not the one sent last. Treat this as an added acceptance criterion and test it.
- 2026-11-21T13:53:09Z [li] Lead: also fix in this task, from the second #154 review (each with a test): (b) loadCalendars() skips under any hold (GoogleCalendarModel.swift about 297), so when the first list load inside connect() fails, Settings shows 'Connected. Loading your calendars…' with nothing loading and reopening Settings during the hold does nothing: retry the list load when the hold ends while Settings is open (or let a load with an empty list ignore back-off holds but still honour our 429), and show a note when a hold is why the list was not reloaded; (d) after a Disconnect during the code exchange the button reads 'Connecting' until the exchange returns: show the not-connected state at once. Known and accepted: (a) a cancelled poll waits for a shared token renewal; (c) pull and zone-change refreshes run in unstructured tasks.
- 2026-11-21T13:53:09Z [li] status: backlog → todo
- 2026-11-21T13:53:09Z [implementer-1] status: todo → in-progress — claimed by implementer-1
