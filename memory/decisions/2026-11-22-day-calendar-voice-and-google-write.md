# 2026-11-22 — day calendar screen, adding events by voice and typing, Google write access

Plan: `plans/2026-11-22-day-calendar-and-voice.md`, approved by the user on 2026-11-22 (plan-mode approval). Board tasks #166 to #173. This file records what the user decided and which earlier decisions it changes. Earlier decision files are left as written.

## What the user asked for

2026-11-21: "I want to add some voice controlls to the app. ideally I want to say 'HEY SEASIGN' - then say a phrase like 'add a meeting to my calendar sunday at 3pm with Rahaf' and it would get added to my calendar."

2026-11-22, after discussion: "if the user taps on the calendar events section at the top, a full screen should open to today's calendar showing all events for the day (not just the next 3 events). at the top right add a mic button and below that a + button. if the user taps the mic, they speak to the phone and tell it what calendar event to add. if they tap the + button, they can enter an event by manually typing it. [After the mic] a new popup shows the event details that are about to be added and reads them aloud to the user. [After +] just show it as the text in the popup (don't read aloud). the user must either say 'Confirm' or tap the 'Confirm' button to add that event to the calendar. Allow me to choose the default voice for the app, the user can change to a different system voice if they like. For the default voice i'd like to try cloning my own voice using Pocket-TTS."

## Decisions

| question | the user's decision |
|---|---|
| Where new events are written | Google Calendar with write access; the user reconnects once. Pasted iCal links stay read-only (the format cannot be written to). Apple Calendar is not a target |
| Typed entry | One line, like speaking; the same understanding step and confirm popup as voice |
| Understanding the line | Rules on the phone (Apple's date detector plus simple rules). AI parsing through the user's provider key is left for later |
| The cloned voice | A system voice now, with a picker. A separate listen-only trial of the Pocket-TTS clone on the Mac (#173) before deciding whether and how it ships |
| How listening starts | A mic button on the day screen. The "Hey Seasign" wake phrase is not built now: iOS allows a custom wake phrase only while the app is open, and it is to be revisited once the button flow works |

## Earlier decisions this changes

1. **Voice input was "not v1"** (`BUILD.md`, the AGENTS.md Platform features row, `memory/decisions/2026-11-15-v1-product-decisions.md`, `plans/2026-11-15-v1-build.md`). It is now in: speech recognition for one phrase at a time, and read-aloud of the confirmation.
2. **The app asked for no permission.** It now asks for the microphone and for speech recognition, the first time the mic is tapped. Speech is recognised on the phone (`requiresOnDeviceRecognition`); on a phone that cannot do that, the mic is unavailable and the + button remains. Sending audio to Apple's servers would need a further decision. The app still asks for no location and no access to the phone's calendars (EventKit stays rejected, as the user repeated on 2026-11-21: "syncing with the apple cal means first the apple cal has to be set up that way - that's a dependency i dont want to build in").
3. **Google access was read-only**, and Settings said "Seasign can only read your calendars, never change them." The sign-in now also asks for `https://www.googleapis.com/auth/calendar.events.owned` (see, create, change and delete events on calendars the user owns), the narrowest scope `events.insert` accepts for this use. The app uses it only to create an event the user has confirmed. The two read-only scopes stay, so calendars the user does not own can still be read. A connection made before this change keeps working read-only; write access is asked for when the user first adds an event ("Connect again to add events").

## Lead's choices inside the plan (the user saw them in the plan and approved it)

- A spoken or typed name ("with Rahaf") is title text only: no attendees are added and no invitations are sent.
- Defaults: one hour long; no time given means an all-day event; no date given means today; "3pm" means 3 pm in the zone the events are shown in (`EventZone.resolve`).
- The day screen shows today only. An event added for another day is acknowledged with a short "Added" note.
- The mic is English-only at first.
- The phrase parser runs on the phone, which departs from "business logic lives in the API": it depends on Apple's date detector, needs no network, and keeps the text of what was said on the phone. An Android client would need its own parser, or the AI route if that is built.
- A spoken "Confirm" writes to a real calendar, so listening for it opens only after the read-aloud ends, for a few seconds, and only a whole utterance of "confirm" or "cancel" counts.

## User steps

- Google Cloud Console → Google Auth Platform → Data Access: add the scope `calendar.events.owned`; note whether the console marks it sensitive (it affects verification before the App Store).
- Reconnect Google in the app when the write scope ships (the user does this themselves; the agent never drives the sign-in or creates an event in the user's account).
- For #173: record a voice sample kept outside the repository, and accept the Pocket-TTS model terms if the user chooses to proceed.

## Risk recorded for the cloned voice

If a cloned voice ships inside the app, the voice file can be extracted from the app bundle and used to generate speech in the user's voice. A server keeps the file private but is a new paid service (Cloudflare Workers cannot run the model) and adds a delay. The user decides after hearing the trial.

## Not decided

- Whether Google marks `calendar.events.owned` as sensitive, and the effect on verification.
- Editing or deleting events from the app; attendees; other days in the day screen; the wake phrase; AI parsing.
