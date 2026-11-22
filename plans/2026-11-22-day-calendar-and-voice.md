# Day calendar screen with adding events by voice and by typing

Date: 2026-11-22. Owner: lead session. Status: **approved by the user on 2026-11-22** (plan mode approval, covering the three reversals under "Approvals"). Board tasks: #166 to #173, in the order of the table below.

## Context

The user wants to add events to their calendar from inside Seasign, by speaking or typing. Today the app only reads calendars and shows the next three events.

What the user asked for (2026-11-21/22):

- Tapping the events area at the top of Today opens a full-screen view of **today's calendar with all of the day's events**.
- Top right of that screen: a **mic** button, and below it a **+** button.
- **Mic**: the user speaks the event. A popup shows the event that is about to be added and **reads it aloud**.
- **+**: the user types the event. The same popup shows it as text, not read aloud.
- The event is added only when the user **says "Confirm" or taps Confirm**.
- A **voice setting**: a default voice, changeable to any system voice. The user wants to try a clone of their own voice (Pocket-TTS) as the default.

Decisions the user made in discussion:

| question | decision |
|---|---|
| Where new events go | Google Calendar, with write access (reconnect once). Pasted iCal links stay read-only |
| Typed entry | One line, like speaking ("meeting sunday at 3pm with Rahaf"); same understanding step and popup as voice |
| Understanding the line | Rules on the phone first (no AI key needed); AI parsing can come later |
| Cloned voice | System voice now with a voice picker; a separate listen-only trial of the clone on the Mac before deciding how it ships |
| "Hey Seasign" wake phrase | Not in this plan. iOS allows it only while the app is open; revisit after this works |

## Approvals this plan needs (AGENTS.md ask-first, and recorded decisions it reverses)

1. **Voice input enters the product.** `BUILD.md`, `AGENTS.md` (Platform features row), `memory/decisions/2026-11-15-v1-product-decisions.md` and `plans/2026-11-15-v1-build.md` all list voice as "not v1". A new decision file records the change.
2. **The app's first permission prompts**: microphone and speech recognition, asked the first time the mic is tapped. Speech recognition is asked to stay on the phone; where a phone cannot do that, the mic says so and the + button remains (no audio is sent to Apple's servers without a further decision).
3. **Google write access.** Settings currently promises "Seasign can only read your calendars, never change them." That sentence changes. New scope: `calendar.events.owned` (create and change events on calendars the user owns), the narrowest scope `events.insert` accepts for this use; the two read-only scopes stay for calendars the user does not own.
4. **User steps in Google Cloud Console**: add the new scope under Data Access; note whether the console marks it sensitive (it affects verification before the App Store).
5. **No new package or service** in tasks 1–7. Task 8 (voice clone trial) runs on the Mac only and has its own approval for installing Pocket-TTS there.

## How it works

**Day screen.** A new full-screen cover from Today (`Destination.day` in `ios/Seasign/Today/TodayView.swift`, same pattern as History and Saved). It lists every event of today, ended ones included, from Google and pasted links, in start order with the existing labels (`EventLabel`). The whole events box on Today becomes a button; with no events and no zip prompt, the box area is still tappable. The screen refreshes on its own while open (Today's Google poll stops under any cover).

**Day data.** Both event routes return only events that have not ended, and the app prunes ended ones. A new optional `day` parameter (a `YYYY-MM-DD` date with the existing `timezone`) on `POST /v1/calendar/events` and `POST /v1/google/events` returns that day's events, ended ones included. The day screen keeps its own snapshot; Today's next-three logic is untouched.

**Entering an event.** Mic and + both produce one line of text.

- **+** opens a one-line field.
- **Mic** records, shows the words as they are recognised, and stops on a pause or a second tap. Recognition uses `SFSpeechRecognizer` on the phone (`requiresOnDeviceRecognition`), with names from the user's existing event titles passed as `contextualStrings` to help with names like "Rahaf".

**Understanding the line** (on the phone, pure and tested): `NSDataDetector` finds the date and time; the rest, minus lead-ins like "add a meeting to my calendar", becomes the title ("Meeting with Rahaf"). Rules to fix in the task: no time → all-day; no date → today; a time already past today → still today (the popup shows it); default length 1 hour; "3pm" means 3 pm in the events' time zone (`EventZone.resolve`, the same zone Today uses). "with Rahaf" is title text only: **no attendees, no invitations**. If no title or no date can be found, the popup says what is missing and offers to try again.

**Confirm popup.** Shows title, day, time, length and the calendar it will go to, with Confirm and Cancel.

- After **mic** entry it is read aloud ("Meeting with Rahaf, Sunday at 3 PM, one hour. Say confirm or cancel."). Listening for the answer starts only after the speech ends, lasts a few seconds, and accepts only a whole utterance of "confirm" or "cancel"; anything else leaves the buttons.
- After **+** entry it is silent.
- Confirm is single-flight: voice and tap cannot both fire.

**Creating the event.** New route `POST /v1/google/events/create` (header `X-Google-Token`, never stored or logged): calendar id, title, start, end or all-day date, time zone, and a client-made event id so a retry after a timeout cannot create a second event (verify Google's rules for client-supplied ids). The Worker calls Google's `events.insert` through the existing `postGoogleJson` and returns the created event in the usual shape. Errors: `google_auth` (401), a new `insufficient_scope` (the token lacks write access), `forbidden` (calendar not writable), `rate_limited`, `fetch_failed`.

**After Confirm.** The popup closes and the day screen shows "Added · Sun 3:00 PM · Meeting with Rahaf" for a few seconds; if the event is today it appears in the list at once, and Today's next-three picks it up on return.

**Write access and existing connections.** A connection made before this change keeps reading as now. Write access is needed only by the add path: without it, Confirm leads to "Connect again to add events" (the same sign-in, asking for the extra scope). Granted scopes are stored on `GoogleAccount` (new optional field) at Connect, so the app knows without trying.

**Default calendar.** Settings → Google Calendar gets "New events go to", listing calendars the user can write to (the calendar list route adds Google's `accessRole`); default: the primary calendar.

**Voice.** Settings gets a Voice section: "System default" plus the English system voices installed on the phone (`AVSpeechSynthesisVoice.speechVoices()`), with a Preview button. Stored as an optional `Settings` field; if the stored voice is no longer installed, the system default is used. The clone, if adopted later, becomes another entry in this list.

## Tasks, in order

| # | task | notes |
|---|---|---|
| 1 | Decision record and docs | `memory/decisions/2026-11-22-day-calendar-voice-and-google-write.md`; update `BUILD.md`, the AGENTS.md Platform features and Calendars rows, `memory/architecture.md`; save this plan in `plans/` |
| 2 | API: `day` parameter on both event routes; `accessRole` on the calendar list | Spec change. First check what the pasted-link KV entry holds (`CachedCalendar` in `api/src/routes/calendar.ts`, `parseCalendar` window in `api/src/lib/calendar.ts`): if it does not cover earlier today, widen what is cached, not just the filter. Google side: `timeMin` at the start of the day (`api/src/routes/google.ts`) |
| 3 | API: `POST /v1/google/events/create` | Spec change; route and test pattern from `api/src/routes/google-push.ts` and `api/test/google-push.test.ts` (which records request bodies). Look up Google's exact 403 reasons so `insufficient_scope` and `forbidden` are told apart. `fields` limited so nothing private is echoed. Under the existing `google` rate-limit group |
| 4 | iOS: write scope, granted scopes stored, "Connect again to add events", default calendar in Settings, new Settings sentence | `GoogleOAuth.swift` (scopes), `GoogleCalendarStore.swift` (`GoogleAccount` optional field; `GoogleCalendarChoice` access role), `GoogleCalendarModel.swift`, `GoogleSettingsSection.swift`. Old-schema store test as `memory/architecture.md` requires. The user reconnects on the Pro Max themselves |
| 5 | iOS: day screen | New `ios/Seasign/Calendar/DayView.swift` and a small `DayModel` (own snapshot, own refresh loop, both sources merged with `EventPicker`-style ordering); events box on Today becomes a button; mic and + buttons present but + only after task 6. Reuses `SheetScaffold`/`CloseMark`, `EventLabel`, `TodayType`, `Palette`; mic and plus as SF Symbols or new `LineIcon` cases to match the other icons |
| 6 | iOS: + entry, the parser, the confirm popup, create | `EventPhraseParser` (pure; the date detector behind a protocol with an injected "now", since `NSDataDetector` takes no reference date), `EventDraft`, `SeasignAPI.googleCreateEvent` modelled on `googleEvents`, single-flight confirm, the "Added" note |
| 7 | iOS: mic, read-aloud, spoken Confirm/Cancel, Voice section in Settings | `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` through `ios/project.yml`; recognizer and speaker behind protocols (`SpeechListening`, `SpeechSpeaking`) so tests inject transcripts; `Settings.voiceIdentifier: String?` with the old-schema test |
| 8 | Voice clone trial on the Mac (listen only) | Separate approval. Read the Pocket-TTS licence file and model terms first (code reported MIT, weights reported CC BY 4.0; accepting the model terms is the user's action). The user records a sample kept **outside the repo**; a few confirmation sentences are rendered to audio files for the user to hear. Outcome: a decision on on-device (app size, new dependency, the voice file can be extracted from the app) versus a server (new paid service), or neither |

Tasks 2 and 3 can run one after the other in `api/` while task 4 runs in `ios/`; 5–7 follow in order because each changes the spec's client or builds on the last. Each task gets a reviewer; full review for the create route, token handling and the spoken Confirm; light review for look.

## Not in this plan

- The "Hey Seasign" wake phrase and Siri shortcuts.
- Editing or deleting events, attendees and invitations, locations, repeating events.
- AI parsing through the user's provider key.
- Other days in the day screen (today only, as asked); a later step could add day-to-day navigation, which the `day` parameter already allows.
- The cloned voice inside the app (decided after task 8).

## Verification

- **API**: `npm test` and `npx tsc --noEmit` in `api/`; mocked Google for the create route (body sent, id reuse on retry, each error code, nothing private in logs); `npm run openapi` and the spec diff reviewed.
- **iOS logic**: Swift Testing with mocked transport on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2, one `xcodebuild` at a time. Parser tests with a fixed "now" and zone (today, tomorrow, weekday names, "next", no time, no date, past time, 24-hour phrasing). Confirm flow tests with injected transcripts ("confirm", "cancel", "confirm that later" must not confirm) and a fake speaker (listening opens only after speech ends).
- **Screens**: Simulator screenshots on the iPhone 17 with `-debugGoogle YES` sample events: day screen, + entry, confirm popup, the "Added" note, Settings sections. Never on the iPhone 16 Pro Max (real Google connection).
- **Cannot be verified by the agent; the user's checks**: live microphone and speech recognition (the Simulator cannot exercise them reliably); the read-aloud voice by ear; reconnecting Google with the new scope; creating a real event (the agent never creates one in the user's account) and seeing it in Google Calendar and on Today.
- **Clone trial**: the user listens to the rendered files.

## Open points to settle while building

- Whether Google's refresh answer always carries `scope` (for keeping the stored scopes current).
- Whether the console marks `calendar.events.owned` as sensitive, and what that means for verification.
- On-device speech recognition availability per device and language; the mic is English-only at first.
