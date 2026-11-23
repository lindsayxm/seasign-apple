---
id: 179
title: iOS: voice says 'Nothing was heard' when the recognizer itself failed
status: in-progress
owner: implementer-1
depends_on: []
created: 2026-11-23T01:58:23Z
updated: 2026-11-23T01:58:33Z
---

## Goal

Seen 2026-11-22 on the iPhone 16 Pro Max simulator (iOS 18.3): the mic listens, input is live (1 ch 48 kHz), but every attempt ends in kAFAssistantErrorDomain Code=1101 with SFSpeechAssetManager asset messages: the on-device recognition model is not there although supportsOnDeviceRecognition is true. The app shows 'Nothing was heard', which sends the user looking at the microphone. The same can happen on a real phone whose on-device model is missing. Tell a recognizer failure apart from silence.

## Acceptance criteria

- [ ] Look up in sosumi / the SDK headers what SFSpeechRecognizer reports for silence (reported: kAFAssistantErrorDomain 1110 'No speech detected') and for a missing on-device model (1101); cite in the log
- [ ] A recognizer error with no words heard, other than the no-speech one, shows a notice that speech can't be recognised on this iPhone right now and points to the + button; true silence still says Nothing was heard; words heard before an error still make the popup; in the answer window an error still counts as no answer
- [ ] The listener protocol carries the distinction so tests inject it; tests fail without the change. Error codes are not logged with any transcript. Suite passes on both runtimes; never touch the iPhone 16 Pro Max

## Relevant files

- ios/Seasign/Voice
- ios/SeasignTests

## What's been tried


## Log

- 2026-11-23T01:58:23Z [li] created (todo)
- 2026-11-23T01:58:33Z [implementer-1] status: todo → in-progress — claimed by implementer-1
