---
id: 179
title: iOS: voice says 'Nothing was heard' when the recognizer itself failed
status: review
owner: implementer-1
depends_on: []
created: 2026-11-23T01:58:23Z
updated: 2026-11-23T02:36:09Z
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
- 2026-11-23T02:07:29Z [implementer-1] Error codes, from the SDK header (iPhoneOS27.2.sdk Speech.framework/Headers/SFSpeechRecognitionTask.h, the table under the 'error' property, lines 91-102) and the same table on sosumi /documentation/speech/sfspeechrecognitiontask/error: kAFAssistantErrorDomain 1110 = 'Failed to recognize any speech' (silence); 1101 = 'Connection to speech process was invalidated'; 1107 = 'Connection to speech process was interrupted'; 203 = 'Failure occurred during speech recognition'; 1100 earlier instance still active; 1700 not authorized; kLSRErrorDomain 102 = 'Assets are not installed', 201 Siri/Dictation disabled, 300 failed to initialize, 301 canceled. Not confirmed by any doc: that 1101 means a missing on-device model; that link comes only from the Simulator log seen on 2026-11-22 (SFSpeechAssetManager messages beside 1101). The documented asset error is kLSRErrorDomain 102. Only the iOS 27.2 SDK is installed, so the iOS 18 header was not read. Decision: classify by the one documented silence code (kAFAssistantErrorDomain 1110 -> SpeechFailure.noSpeech) and treat every other recognizer error as a failure (.unavailable), rather than keying on 1101.
- 2026-11-23T02:34:15Z [implementer-1] Commit 7704810. SpeechFailure gains .noSpeech; SpeechFailure(recognizerError:) (SystemSpeech.swift) maps only kAFAssistantErrorDomain 1110 to .noSpeech and every other recognizer error to .unavailable, comparing domain and code only, logging nothing; the result handler yields that kind, never the error. VoiceNotice gains .cannotRecognize: 'Speech can't be recognised on this iPhone right now. Use + to type the event, or try the mic again later.' (no Settings link). VoiceEntryModel.listen: an interruption stays an interruption; in the answer window any other error is no answer (.cancelled); for the event, words heard before any error (before or after the audio ended) make the popup; with no words, .noSpeech is 'Nothing was heard' and any other error is .cannotRecognize. A start that throws still says .busy. Decision to note: before this, an error with words heard before the audio ended gave the busy notice; it now makes the popup with the words (the criterion's literal reading, widening 07cbb77). DEBUG: -debugVoiceFail noSpeech|unavailable makes the scripted listener answer the end of listening with that error (sample Google only). Tests (VoiceEntryModelTests): wordsHeardBeforeAnErrorStillMakeThePopup(.noSpeech/.unavailable, after and before the audio ended), silenceReportedByTheRecognizerSaysNothingWasHeard, aRecognizerThatFailsWithNothingHeardSaysSoAndPointsToThePlus, anErrorInTheAnswerWindowIsNoAnswer(.noSpeech/.unavailable), onlyTheNoSpeechErrorCountsAsSilence (NSErrors 1110, 1101, 1107, 203, LSR 102, 1110 in another domain); the fake's failsOnFinish is now a SpeechFailure?. Red run with the old listen() logic (only the new enum case added to the old busy branch so it compiled), iPhone 16 / 18.3.1, voice suite only: '✘ Test run with 43 tests in 1 suite failed after 182.847 seconds with 5 issues.' '** TEST FAILED **' (wordsHeardBefore... x2, silenceReported... x1, aRecognizerThatFails... x2).
- 2026-11-23T02:34:21Z [implementer-1] Full suite at 7704810, own DerivedData, one runtime after the other: iPhone 16 / iOS 18.3.1: '✔ Test run with 742 tests in 88 suites passed after 162.286 seconds.' '** TEST SUCCEEDED **'. iPhone 17 / iOS 27.2: '✔ Test run with 742 tests in 88 suites passed after 126.811 seconds.' '** TEST SUCCEEDED **'. Screenshot, iPhone 17 / iOS 27.2, -debugGoogle YES -debugVoiceFail unavailable -debugVoiceStart YES, events box touched to open the day screen: /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6b67084e-3b16-4a0b-9976-164876a415f4/scratchpad/shots/179-cannot-recognize-iphone17.jpg (the new notice under the date, mic and + on the right; the sample's own 'Google Calendar couldn't be read just now' line also shows). Not verified: the real SystemSpeechListener was not driven (speech recognition is denied for the app on the iPhone 17 Simulator; the iPhone 16 Pro Max was not touched), so which code a real phone or the Simulator gives for silence and for a missing model is unchecked here. The iPhone 16 Simulator was used only for tests. Follow-up for the lead: memory/architecture.md's Voice note does not yet mention the no-speech / recognizer-failure split (not edited: outside ios/).
- 2026-11-23T02:36:09Z [implementer-1] Open risk for the lead: the old code gave 'busy' for an error before the audio ended, so the 'Nothing was heard' seen on the iPhone 16 Pro Max means 1101 came after the audio ended. If it came within finalWait (2 s) it now gives the new notice; if it came later than 2 s (or never), the finalWait timeout still returns no words and still says 'Nothing was heard' (that path is unchanged). Check on the Pro Max: tap the mic and stay silent; the new notice means fixed, 'Nothing was heard' means the error lands after finalWait and needs a follow-up task for the timeout path. Also: if a real phone reports silence with a code other than 1110, silence will now show the new notice (user check: tap the mic, say nothing, expect 'Nothing was heard'). The mapping is unit-tested; its call from the real result handler is not exercised by any test.
- 2026-11-23T02:36:09Z [implementer-1] status: in-progress → review
