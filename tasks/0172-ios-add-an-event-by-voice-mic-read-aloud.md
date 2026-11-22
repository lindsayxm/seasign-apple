---
id: 172
title: iOS: add an event by voice: mic, read-aloud, spoken Confirm or Cancel, Voice setting
status: todo
owner: 
depends_on: [171]
created: 2026-11-22T17:50:02Z
updated: 2026-11-22T17:50:02Z
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
