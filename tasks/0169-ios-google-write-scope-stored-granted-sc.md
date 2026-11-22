---
id: 169
title: iOS: Google write scope, stored granted scopes, 'Connect again to add events', default calendar for new events
status: todo
owner: 
depends_on: [167]
created: 2026-11-22T17:50:02Z
updated: 2026-11-22T17:50:02Z
---

## Goal

Plan plans/2026-11-22-day-calendar-and-voice.md, task 4. The sign-in asks for calendar.events.owned as well as the two read-only scopes; a connection made before this change keeps reading; write access is needed only by the add path.

## Acceptance criteria

- [ ] GoogleOAuthConfig asks for the three scopes; connecting still requires the two read scopes; the write scope is recorded if granted and its absence does not fail the connection (a user may untick it on Google's consent screen)
- [ ] GoogleAccount gets an optional field for the granted scopes (nil for connections made before this task, meaning read-only); kept current when a token answer carries scope; canAddEvents is one computed place; old-schema store test added as memory/architecture.md requires
- [ ] GoogleCalendarChoice stores the access role from the calendar list (optional; nil means unknown and not offered); Settings, Google Calendar section: 'New events go to' lists writable calendars (owner or writer), default the primary; stored as an optional field; falls back to the primary when the stored one is gone
- [ ] Settings sentence changed: Seasign reads the calendars you choose and adds only the events you confirm; a 'Connect again to add events' state when canAddEvents is false, which runs the same sign-in; Disconnect, expiry and polling behave as before
- [ ] Tests (mocked transport and token endpoint): scopes requested, partial grant, upgrade from a read-only connection keeps choices, stored scopes survive relaunch, default calendar fallback. Suite passes on both runtimes; a screenshot of the Settings section on the iPhone 17 with -debugGoogle. Never touch the iPhone 16 Pro Max

## Relevant files

- ios/Seasign/Google
- ios/Seasign/Store
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-22T17:50:02Z [li] created (todo)
