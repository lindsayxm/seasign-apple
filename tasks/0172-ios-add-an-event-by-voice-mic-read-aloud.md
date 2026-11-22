---
id: 172
title: iOS: add an event by voice: mic, read-aloud, spoken Confirm or Cancel, Voice setting
status: in-progress
owner: implementer-2
depends_on: []
created: 2026-11-22T17:50:02Z
updated: 2026-11-22T21:24:13Z
---

## Goal

Plan plans/2026-11-22-day-calendar-and-voice.md, task 7. The mic records one phrase, recognised on the phone; the confirm popup reads the event aloud and accepts a spoken Confirm or Cancel. Settings gets a Voice section. Look the Speech and AVFoundation APIs up in sosumi first.

## Acceptance criteria

- [ ] NSMicrophoneUsageDescription and NSSpeechRecognitionUsageDescription through ios/project.yml, truthful (speech is recognised on the phone); permissions asked only when the mic is first tapped; denied or unavailable states say so and leave the + button; on a phone without on-device recognition the mic is unavailable (no audio is sent to a server)
- [ ] Listening: SFSpeechRecognizer with requiresOnDeviceRecognition, English, partial results shown, stops on a pause or a second tap, a hard time limit; names from existing event titles as contextualStrings; the audio session is released afterwards; recognizer behind a protocol so tests inject transcripts
- [ ] Read-aloud: after mic entry only, the popup speaks the event in the chosen voice; listening for the answer opens only after speech ends, for a bounded window; only a whole utterance of confirm or cancel counts ('confirm that later' does nothing); voice and tap cannot both fire; typed entry stays silent
- [ ] Settings Voice section: System default plus installed English system voices with a Preview; Settings.voiceIdentifier optional with the old-schema store test; falls back when the stored voice is gone
- [ ] Tests with injected transcripts and a fake speaker cover the above. Suite passes on both runtimes; screenshots on the iPhone 17. Live microphone, recognition and the voice by ear are the user's checks; say so in the log

## Relevant files

- ios/Seasign/Calendar
- ios/Seasign/Settings
- ios/Seasign/Store
- ios/project.yml
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-22T17:50:02Z [li] created (todo)
- 2026-11-22T21:14:49Z [li] Lead: dependency on #171 lifted so this can start while #171's fix commit ddcdd40 is in its second review. What #171 left for this task: AddEventModel has confirm() and cancel() as the single entry points and DraftSummary gives the popup lines and a spoken sentence (with the year when it is not this year, and 'at midnight' wording); DayView shows the mic only when its closure is set (-debugDayButtons shows a do-nothing mic today); the pending draft and its id live in AddEventPending for the app run. The parser does not read spelled-out numbers ('three pm', 'two hours', 'half past three', 'three thirty'): speech transcripts need them, so add them to the parser with table rows, keeping its rule that an unreadable time is a problem, never a guess. Never let any debug argument reach a create against a non-sample Google model (the rule #171's review enforced).
- 2026-11-22T21:14:49Z [li] depends on: #171 → none
- 2026-11-22T21:14:49Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-22T21:24:13Z [implementer-2] Lead: carried over from the second #171 review, because this task is in the same files; each needs a test that fails without it. (a) PushDeadline.race (GoogleCalendarModel.swift about 1047-1055) can return the fallback although the task answered first (the value task cancels the timer before resuming; the cancelled timer then resumes the fallback): resume the value before cancelling the timer, or have the timer skip its resume when cancelled; stress test it. (b) Midnight, lead's ruling until the user says otherwise: '12am' or '12:xx am' written with an explicit day or date means the START of that day ('flight friday at 12:30am' is Friday 00:30, the same as '00:30 friday'); the word 'midnight' and '12 tonight/at night' mean the END of the named day; whenever a start between 00:00 and 00:59 is placed on the day after the one named, the popup and the spoken sentence say so. (c) The spoken sentence must name the date, not only the weekday, for a day more than six days away ('Dentist, Thursday, December 17 at 4 PM, one hour'). (d) The plain-hour-after-a-day-word problem must not fire when the line has a clear time elsewhere ('lunch tuesday 4 guests at 1pm', 'book club friday 7 at 7pm' read as before), and 'check in an hour early tomorrow at 9am' is not a time from now. (e) When a late success arrives for a draft whose uncertain popup is still on screen, switch it to Added. Accepted as they are: a night word in the title turning 'at 12' into midnight; one pending entry; glued a/p outside the bare-number rule staying in the title.
