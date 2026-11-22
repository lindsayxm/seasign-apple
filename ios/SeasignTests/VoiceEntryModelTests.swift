import Foundation
import SwiftData
import Testing

@testable import Seasign

// Task 172: adding an event by voice, with the recognizer and the speaker
// replaced by fakes (injected transcripts, a speaker the test ends) and
// Google's token endpoint and the API mocked as in `AddEventModelTests`.
// Nothing here uses the microphone, recognises speech or speaks, and no
// event is created anywhere. Every wait is bounded.

/// What the fakes did, in order, to check that listening for the answer
/// opens only after the reading ended.
@MainActor
final class VoiceLog {
    var entries: [String] = []
}

@MainActor
final class FakeListener: SpeechListening {
    let log: VoiceLog
    /// What `availability()` says; `requestPermission()` turns it into `afterPermission`.
    var current: SpeechAvailability = .ready
    var afterPermission: SpeechAvailability = .ready
    var permissionRequests = 0
    var failsToStart = false
    /// `finish()` gives the last partial as the final result; false: no final result comes.
    var givesFinal = true
    /// The final result `finish()` gives instead of the last partial.
    var finalText: String?
    private(set) var starts: [[String]] = []
    private(set) var finishes = 0
    private(set) var stops = 0
    private var continuation: AsyncStream<SpeechEvent>.Continuation?
    private var latest = ""

    init(log: VoiceLog) {
        self.log = log
    }

    var isListening: Bool {
        continuation != nil
    }

    func availability() -> SpeechAvailability { current }

    func requestPermission() async -> SpeechAvailability {
        permissionRequests += 1
        log.entries.append("ask")
        current = afterPermission
        return current
    }

    func start(contextualStrings: [String]) throws -> AsyncStream<SpeechEvent> {
        if failsToStart { throw SpeechFailure.unavailable }
        starts.append(contextualStrings)
        log.entries.append("listen")
        let (stream, continuation) = AsyncStream.makeStream(of: SpeechEvent.self)
        self.continuation = continuation
        latest = ""
        return stream
    }

    /// The recognizer hears `words` so far.
    func hear(_ words: String) {
        latest = words
        continuation?.yield(.partial(words))
    }

    func send(_ event: SpeechEvent) {
        continuation?.yield(event)
    }

    func finish() {
        finishes += 1
        log.entries.append("finish")
        guard givesFinal else { return }
        continuation?.yield(.final(finalText ?? latest))
        continuation?.finish()
        continuation = nil
    }

    func stop() {
        stops += 1
        if continuation != nil { log.entries.append("stop") }
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
final class FakeSpeaker: SpeechSpeaking {
    let log: VoiceLog
    /// Returns at once with this; nil: waits for `end`.
    var answersAt: SpeakOutcome?
    private(set) var spoken: [(text: String, voice: String?)] = []
    private(set) var stops = 0
    private var waiting: CheckedContinuation<SpeakOutcome, Never>?

    init(log: VoiceLog) {
        self.log = log
    }

    var isSpeaking: Bool {
        waiting != nil
    }

    func speak(_ text: String, voiceIdentifier: String?) async -> SpeakOutcome {
        spoken.append((text, voiceIdentifier))
        log.entries.append("speak")
        let outcome: SpeakOutcome
        if let answersAt {
            outcome = answersAt
        } else {
            outcome = await withCheckedContinuation { waiting = $0 }
        }
        log.entries.append("spoke:\(outcome)")
        return outcome
    }

    func end(_ outcome: SpeakOutcome = .finished) {
        let continuation = waiting
        waiting = nil
        continuation?.resume(returning: outcome)
    }

    func stop() {
        stops += 1
        end(.stopped)
    }
}

@Suite @MainActor struct VoiceEntryModelTests {
    private let endpoint = FakeGoogleEndpoint()
    private let stub = GoogleAPIStub()
    /// Noon on Thursday 19 November 2026 in Chicago.
    private let clock = TestClock(instant("2026-11-19T18:00:00Z"))
    private let zone = TimeZone(identifier: "America/Chicago")!
    private let log = VoiceLog()
    /// The user's example, as speech gives it.
    private let said = "add a meeting to my calendar Sunday at 3 PM with Rahaf"

    private static let timing = VoiceEntryModel.Timing(
        pause: .milliseconds(150), firstWords: .milliseconds(400), phraseLimit: .seconds(2),
        finalWait: .milliseconds(200), answerWindow: .milliseconds(600), tick: .milliseconds(10)
    )

    // MARK: Set-up

    private func googleModel(_ context: ModelContext) -> GoogleCalendarModel {
        let clock = clock
        let zone = zone
        return GoogleCalendarModel(
            api: SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: stub),
            context: context,
            config: FakeGoogle.config,
            tokens: InMemoryGoogleTokenStore(),
            http: endpoint.http,
            timeZone: { zone },
            now: { clock.now }
        )
    }

    private func connected(_ context: ModelContext) async -> GoogleCalendarModel {
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(scope: FakeGoogle.allScopes))
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil, scope: FakeGoogle.allScopes))
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars(roles: [("me@example.test", "Me", true, "owner")]))
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events([], statuses: [nil]))
        stub.answer(GoogleAPIStub.postCreate, GoogleAPIStub.created(id: String(format: "%032x", 1)))
        let model = googleModel(context)
        await model.connect { url, scheme in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "\(scheme):/oauth2redirect?state=\(state)&code=\(FakeGoogle.code)")!
        }
        #expect(model.connection == .connected)
        return model
    }

    private func adder(_ google: GoogleCalendarModel) -> AddEventModel {
        let clock = clock
        let zone = zone
        return AddEventModel(
            google: google,
            parser: EventPhraseParser(detector: FakeDateDetector()),
            timeZone: { zone },
            now: { clock.now },
            clock: { .twelveHour },
            makeID: { String(format: "%032x", 1) }
        )
    }

    private struct Rig {
        var adder: AddEventModel
        var voice: VoiceEntryModel
        var listener: FakeListener
        var speaker: FakeSpeaker
    }

    private func rig(connected isConnected: Bool = true, titles: [String] = [], voiceID: String? = "com.example.voice") async throws -> Rig {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = isConnected ? await connected(context) : googleModel(context)
        let adder = adder(google)
        let listener = FakeListener(log: log)
        let speaker = FakeSpeaker(log: log)
        let clock = clock
        let voice = VoiceEntryModel(
            adder: adder, listener: listener, speaker: speaker,
            voiceIdentifier: { voiceID }, names: { titles },
            now: { clock.now }, clock: { .twelveHour }, timing: Self.timing
        )
        return Rig(adder: adder, voice: voice, listener: listener, speaker: speaker)
    }

    private var meeting: EventDraft {
        EventDraft(
            title: "Meeting with Rahaf",
            timing: .timed(start: instant("2026-11-22T21:00:00Z"), end: instant("2026-11-22T22:00:00Z")),
            timeZone: zone
        )
    }

    private func creates() -> Int {
        stub.seen.filter { $0.operationID == GoogleAPIStub.postCreate }.count
    }

    /// Waits up to five seconds for `condition`.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Waits for the voice's run to end, at most five seconds.
    private func settle(_ voice: VoiceEntryModel) async {
        guard let work = voice.work else { return }
        _ = await PushDeadline.race(work, deadline: .seconds(5), fallback: ())
    }

    /// Mic, the user's example heard, a pause: the popup shows the draft and
    /// the reading has started (and is held by the fake speaker).
    private func sayTheExample(_ rig: Rig) async {
        rig.voice.micTapped()
        #expect(await eventually { rig.listener.isListening })
        rig.listener.hear("add a meeting")
        rig.listener.hear(said)
        #expect(await eventually { rig.speaker.isSpeaking })
    }

    /// The reading ends; the answer window opens.
    private func readingEnds(_ rig: Rig) async {
        rig.speaker.end()
        #expect(await eventually { rig.voice.phase == .awaitingAnswer && rig.listener.isListening })
    }

    // MARK: Permissions and availability

    @Test func permissionsAreAskedOnlyWhenTheMicIsFirstTapped() async throws {
        let rig = try await rig()
        rig.listener.current = .needsPermission
        rig.listener.afterPermission = .ready
        #expect(rig.listener.permissionRequests == 0)
        rig.voice.micTapped()
        #expect(await eventually { rig.listener.isListening })
        #expect(rig.listener.permissionRequests == 1)
        #expect(log.entries.prefix(2) == ["ask", "listen"])
        rig.voice.interrupt()

        // Once given, they are not asked again.
        rig.voice.micTapped()
        #expect(await eventually { rig.listener.isListening })
        #expect(rig.listener.permissionRequests == 1)
        rig.voice.interrupt()
    }

    @Test(arguments: [
        (SpeechAvailability.unsupported, VoiceNotice.unsupported),
        (.micDenied, .micDenied), (.speechDenied, .speechDenied), (.restricted, .restricted), (.busy, .busy),
    ])
    func aMicThatCannotListenSaysSoAndLeavesThePlus(_ availability: SpeechAvailability, _ notice: VoiceNotice) async throws {
        let rig = try await rig()
        rig.listener.current = availability
        rig.voice.micTapped()
        await settle(rig.voice)
        #expect(rig.voice.phase == .notice(notice))
        #expect(rig.voice.notice?.message.contains("+") == true)
        #expect(rig.listener.permissionRequests == 0)
        #expect(rig.listener.starts.isEmpty)
        #expect(!rig.adder.isOpen)
        // The + still opens the field, and the notice goes.
        rig.voice.typingStarted()
        rig.adder.open()
        #expect(rig.adder.stage == .entering)
        #expect(rig.voice.phase == .idle)
    }

    /// On a phone without on-device recognition nothing is asked and
    /// nothing listens: no audio could go to a server.
    @Test func withoutOnDeviceRecognitionNothingIsAskedOrHeard() async throws {
        let rig = try await rig()
        rig.listener.current = .unsupported
        rig.voice.micTapped()
        await settle(rig.voice)
        #expect(rig.voice.notice == .unsupported)
        #expect(rig.listener.permissionRequests == 0)
        #expect(rig.listener.starts.isEmpty)
        #expect(VoiceNotice.unsupported.message.contains("nothing you say is sent anywhere"))
    }

    @Test func aPermissionRefusedAtThePromptSaysSo() async throws {
        let rig = try await rig()
        rig.listener.current = .needsPermission
        rig.listener.afterPermission = .micDenied
        rig.voice.micTapped()
        await settle(rig.voice)
        #expect(rig.voice.notice == .micDenied)
        #expect(rig.voice.notice?.opensSystemSettings == true)
        #expect(rig.listener.starts.isEmpty)
    }

    @Test func listeningThatCannotStartSaysSo() async throws {
        let rig = try await rig()
        rig.listener.failsToStart = true
        rig.voice.micTapped()
        await settle(rig.voice)
        #expect(rig.voice.notice == .busy)
    }

    // MARK: Listening for the event

    @Test func theWordsShowAsTheyComeAndAPauseEndsListening() async throws {
        let rig = try await rig(titles: ["Lunch with Rahaf", "Dentist", "Call Rahaf about the Okafor visit"])
        rig.voice.micTapped()
        #expect(await eventually { rig.listener.isListening })
        #expect(rig.voice.phase == .listening(""))
        #expect(rig.voice.isListening)
        // Names from the day's titles help the recognizer.
        #expect(rig.listener.starts.first == ["Rahaf", "Dentist", "Okafor"])
        rig.listener.hear("add a meeting")
        #expect(await eventually { rig.voice.heard == "add a meeting" })
        #expect(rig.listener.finishes == 0)
        rig.listener.hear(said)
        // The pause: the audio ends, the final result is read, the
        // microphone is released, and the popup shows the draft.
        #expect(await eventually { rig.adder.stage == .reviewing(meeting) })
        #expect(rig.listener.finishes == 1)
        #expect(rig.listener.stops >= 1)
        #expect(rig.adder.line == said)
        rig.voice.interrupt()
    }

    @Test func aSecondTapOnTheMicEndsListening() async throws {
        let rig = try await rig()
        var timing = Self.timing
        timing.pause = .seconds(30)
        let voice = VoiceEntryModel(
            adder: rig.adder, listener: rig.listener, speaker: rig.speaker,
            voiceIdentifier: { nil }, timing: timing
        )
        voice.micTapped()
        #expect(await eventually { rig.listener.isListening })
        rig.listener.hear("lunch with Ann tomorrow at noon")
        #expect(await eventually { voice.heard == "lunch with Ann tomorrow at noon" })
        voice.micTapped()
        #expect(await eventually { rig.listener.finishes == 1 })
        #expect(await eventually { rig.adder.isOpen })
        voice.interrupt()
    }

    @Test func listeningHasAHardLimit() async throws {
        let rig = try await rig()
        var timing = Self.timing
        timing.pause = .seconds(30)
        timing.phraseLimit = .milliseconds(500)
        let voice = VoiceEntryModel(
            adder: rig.adder, listener: rig.listener, speaker: rig.speaker,
            voiceIdentifier: { nil }, timing: timing
        )
        let started = ContinuousClock.now
        voice.micTapped()
        #expect(await eventually { rig.listener.isListening })
        rig.listener.hear("lunch with Ann tomorrow at noon and")
        #expect(await eventually { rig.listener.finishes == 1 })
        #expect(ContinuousClock.now - started < .seconds(3))
        voice.interrupt()
    }

    /// A run that was stopped must not release the microphone a newer run
    /// is using (it did once: the old run's clean-up stopped the new one).
    @Test func aStoppedRunLeavesTheNextRunsMicrophoneAlone() async throws {
        let rig = try await rig()
        var timing = Self.timing
        timing.pause = .seconds(30)
        timing.firstWords = .seconds(30)
        let voice = VoiceEntryModel(
            adder: rig.adder, listener: rig.listener, speaker: rig.speaker,
            voiceIdentifier: { nil }, timing: timing
        )
        voice.micTapped()
        #expect(await eventually { rig.listener.isListening })
        rig.listener.hear("lunch")
        voice.interrupt()
        voice.micTapped()
        #expect(await eventually { rig.listener.starts.count == 2 && rig.listener.isListening })
        // Well past the old run's next check.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.listener.isListening)
        #expect(voice.isListening)
        voice.interrupt()
    }

    @Test func nothingHeardSaysSoAndOpensNoPopup() async throws {
        let rig = try await rig()
        rig.voice.micTapped()
        await settle(rig.voice)
        #expect(rig.voice.notice == .notHeard)
        #expect(rig.listener.finishes == 1)
        #expect(!rig.adder.isOpen)
        #expect(rig.speaker.spoken.isEmpty)
    }

    @Test func anInterruptionWhileListeningSaysSoAndAddsNothing() async throws {
        let rig = try await rig()
        rig.voice.micTapped()
        #expect(await eventually { rig.listener.isListening })
        rig.listener.hear("lunch with Ann tomorrow")
        rig.listener.send(.failed(.interrupted))
        await settle(rig.voice)
        #expect(rig.voice.notice == .interrupted)
        #expect(!rig.adder.isOpen)
    }

    @Test func leavingTheForegroundStopsListeningButNotThePermissionPrompt() async throws {
        let rig = try await rig()
        rig.listener.current = .needsPermission
        // The prompt makes the app inactive: that does not stop the mic.
        rig.voice.micTapped()
        #expect(rig.voice.phase == .asking)
        rig.voice.sceneChanged(active: false)
        #expect(rig.voice.phase == .asking)
        #expect(await eventually { rig.listener.isListening })
        rig.listener.hear("lunch with Ann")
        rig.voice.sceneChanged(active: false)
        #expect(rig.voice.phase == .idle)
        #expect(!rig.listener.isListening)
        await settle(rig.voice)
        #expect(!rig.adder.isOpen)
    }

    // MARK: Reading aloud

    @Test func thePopupIsReadAloudInTheChosenVoiceAndListeningWaitsForTheEnd() async throws {
        let rig = try await rig()
        await sayTheExample(rig)
        #expect(rig.adder.stage == .reviewing(meeting))
        #expect(rig.voice.phase == .speaking)
        let sentence = DraftSummary(meeting, now: clock.now, clock: .twelveHour).spoken
        #expect(rig.speaker.spoken.map(\.text) == ["\(sentence) Say confirm or cancel."])
        #expect(rig.speaker.spoken.first?.text == "Meeting with Rahaf, Sunday at 3 PM, one hour. Say confirm or cancel.")
        #expect(rig.speaker.spoken.first?.voice == "com.example.voice")

        // While it speaks, nothing listens, however long it takes.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.listener.starts.count == 1)
        #expect(!rig.listener.isListening)

        await readingEnds(rig)
        #expect(rig.listener.starts.last == ["confirm", "cancel"])
        // The microphone was released before the reading, and the answer
        // window opened only after the reading ended.
        let tail = Array(log.entries.suffix(4))
        #expect(tail == ["stop", "speak", "spoke:finished", "listen"] || tail == ["finish", "speak", "spoke:finished", "listen"])
        #expect(log.entries.firstIndex(of: "spoke:finished")! < log.entries.lastIndex(of: "listen")!)
        rig.voice.interrupt()
    }

    @Test func aSpokenConfirmAddsTheEventOnce() async throws {
        let rig = try await rig()
        await sayTheExample(rig)
        await readingEnds(rig)
        rig.listener.hear("Confirm")
        rig.listener.finalText = "Confirm."
        #expect(await eventually { rig.adder.addedNote != nil })
        #expect(creates() == 1)
        #expect(rig.voice.phase == .idle)
        #expect(!rig.listener.isListening)
    }

    @Test func aSpokenCancelClosesThePopupAndAddsNothing() async throws {
        let rig = try await rig()
        await sayTheExample(rig)
        await readingEnds(rig)
        rig.listener.hear("cancel")
        #expect(await eventually { rig.adder.stage == .closed })
        await settle(rig.voice)
        #expect(creates() == 0)
    }

    @Test(arguments: ["confirm that later", "yes", "okay confirm", "confirmed", "cancel it", "Confirm, confirm", "no"])
    func anythingButAWholeConfirmOrCancelDoesNothing(_ heard: String) async throws {
        let rig = try await rig()
        await sayTheExample(rig)
        await readingEnds(rig)
        // "confirm" arrives first as a partial result, as it would.
        rig.listener.hear(String(heard.prefix(7)))
        rig.listener.hear(heard)
        await settle(rig.voice)
        #expect(rig.adder.stage == .reviewing(meeting), "\(heard)")
        #expect(creates() == 0, "\(heard)")
        #expect(rig.voice.phase == .idle)
        // The buttons still work.
        rig.adder.confirm()
        #expect(await eventually { rig.adder.addedNote != nil })
        #expect(creates() == 1)
    }

    /// Only the final result counts: a partial "confirm" with no final
    /// result does nothing.
    @Test func aPartialConfirmWithoutAFinalResultDoesNothing() async throws {
        let rig = try await rig()
        await sayTheExample(rig)
        await readingEnds(rig)
        rig.listener.givesFinal = false
        rig.listener.hear("confirm")
        await settle(rig.voice)
        #expect(rig.adder.stage == .reviewing(meeting))
        #expect(creates() == 0)
    }

    @Test func theAnswerWindowClosesAfterAFewSeconds() async throws {
        let rig = try await rig()
        await sayTheExample(rig)
        await readingEnds(rig)
        let opened = ContinuousClock.now
        await settle(rig.voice)
        #expect(ContinuousClock.now - opened < .seconds(3))
        #expect(rig.voice.phase == .idle)
        #expect(!rig.listener.isListening)
        #expect(rig.adder.stage == .reviewing(meeting))
        // Words after the window do nothing.
        rig.listener.send(.final("confirm"))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(creates() == 0)
    }

    @Test func aTapWhileReadingStopsItAndNoAnswerIsListenedFor() async throws {
        let rig = try await rig()
        await sayTheExample(rig)
        rig.voice.popupTouched()
        #expect(rig.speaker.stops >= 1)
        await settle(rig.voice)
        #expect(rig.voice.phase == .idle)
        #expect(rig.listener.starts.count == 1)
        #expect(rig.adder.stage == .reviewing(meeting))
    }

    @Test func aTapDuringTheAnswerWindowClosesIt() async throws {
        let rig = try await rig()
        await sayTheExample(rig)
        await readingEnds(rig)
        rig.voice.popupTouched()
        #expect(rig.voice.phase == .idle)
        #expect(!rig.listener.isListening)
        rig.listener.send(.final("confirm"))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(creates() == 0)
        #expect(rig.adder.stage == .reviewing(meeting))
    }

    /// The tap and the voice cannot both add it: Confirm tapped while the
    /// window is open (the sheet also reports the tap) and a spoken
    /// "confirm" in the same moment send one create.
    @Test func aTapAndASpokenConfirmTogetherAddItOnce() async throws {
        let rig = try await rig()
        await sayTheExample(rig)
        await readingEnds(rig)
        rig.listener.hear("confirm")
        rig.adder.confirm()
        rig.voice.popupTouched()
        #expect(await eventually { rig.adder.addedNote != nil })
        await settle(rig.voice)
        #expect(creates() == 1)

        // Without the sheet's report, the model's own check holds too.
        let again = try await self.rig()
        await sayTheExample(again)
        await readingEnds(again)
        again.adder.confirm()
        again.listener.hear("confirm")
        await settle(again.voice)
        #expect(await eventually { again.adder.addedNote != nil })
        #expect(stub.seen.filter { $0.operationID == GoogleAPIStub.postCreate }.count == 2)
    }

    /// A spoken "confirm" answers only the draft that was read: after
    /// Change and a different line, or once the popup shows anything else,
    /// it does nothing.
    @Test func aSpokenConfirmAfterTheDraftChangedDoesNothing() async throws {
        let rig = try await rig()
        await sayTheExample(rig)
        await readingEnds(rig)
        rig.adder.tryAgain()
        rig.adder.line = "dentist friday at 9am"
        rig.adder.submit()
        guard case .reviewing(let other) = rig.adder.stage else {
            Issue.record("expected another draft")
            return
        }
        #expect(other != meeting)
        rig.listener.hear("confirm")
        await settle(rig.voice)
        #expect(creates() == 0)
        #expect(rig.adder.stage == .reviewing(other))
    }

    @Test func leavingTheForegroundClosesTheAnswerWindow() async throws {
        let rig = try await rig()
        await sayTheExample(rig)
        await readingEnds(rig)
        rig.voice.sceneChanged(active: false)
        #expect(rig.voice.phase == .idle)
        #expect(!rig.listener.isListening)
        await settle(rig.voice)
        #expect(creates() == 0)
    }

    @Test func anInterruptionClosesTheAnswerWindow() async throws {
        let rig = try await rig()
        await sayTheExample(rig)
        await readingEnds(rig)
        rig.listener.send(.failed(.interrupted))
        await settle(rig.voice)
        #expect(rig.voice.phase == .idle)
        #expect(rig.adder.stage == .reviewing(meeting))
        #expect(creates() == 0)
    }

    @Test func aReadingThatFailsOpensNoAnswerWindow() async throws {
        let rig = try await rig()
        rig.speaker.answersAt = .failed
        rig.voice.micTapped()
        #expect(await eventually { rig.listener.isListening })
        rig.listener.hear(said)
        #expect(await eventually { rig.adder.stage == .reviewing(meeting) })
        await settle(rig.voice)
        #expect(rig.speaker.spoken.count == 1)
        #expect(rig.listener.starts.count == 1)
        #expect(rig.voice.phase == .idle)
        // The popup still works by tap.
        rig.adder.confirm()
        #expect(await eventually { rig.adder.addedNote != nil })
    }

    @Test func thePopupClosingStopsTheReading() async throws {
        let rig = try await rig()
        await sayTheExample(rig)
        rig.adder.cancel()
        rig.voice.popupClosed()
        await settle(rig.voice)
        #expect(rig.speaker.stops >= 1)
        #expect(rig.listener.starts.count == 1)
        #expect(!rig.voice.popupFromVoice)
    }

    // MARK: Problems, blocks and typing

    @Test func aProblemAfterTheMicIsReadAloudAndNothingListens() async throws {
        let rig = try await rig()
        rig.speaker.answersAt = .finished
        rig.voice.micTapped()
        #expect(await eventually { rig.listener.isListening })
        rig.listener.hear("meeting at twenty five")
        #expect(await eventually { rig.adder.stage == .problem(.unclearTime) })
        await settle(rig.voice)
        #expect(rig.speaker.spoken.map(\.text) == [VoiceWords.spoken(.unclearTime)])
        #expect(rig.listener.starts.count == 1)
        #expect(rig.voice.popupFromVoice)

        // Speak again: the popup closes and the mic listens again.
        rig.voice.speakAgain()
        #expect(!rig.adder.isOpen)
        #expect(await eventually { rig.listener.isListening })
        #expect(rig.listener.starts.count == 2)
        rig.voice.interrupt()
    }

    @Test func aBlockAfterTheMicIsReadAloudAndNothingListens() async throws {
        let rig = try await rig(connected: false)
        rig.speaker.answersAt = .finished
        rig.voice.micTapped()
        #expect(await eventually { rig.listener.isListening })
        rig.listener.hear(said)
        #expect(await eventually { rig.adder.stage == .blocked(meeting, .connect) })
        await settle(rig.voice)
        #expect(rig.speaker.spoken.map(\.text) == [VoiceWords.spoken(AddEventModel.Block.connect)])
        #expect(rig.listener.starts.count == 1)
    }

    @Test func typedEntryNeverSpeaksOrListens() async throws {
        let rig = try await rig()
        rig.voice.typingStarted()
        rig.adder.open(line: "add a meeting to my calendar sunday at 3pm with Rahaf")
        rig.adder.submit()
        #expect(rig.adder.stage == .reviewing(meeting))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.speaker.spoken.isEmpty)
        #expect(rig.listener.starts.isEmpty)
        #expect(!rig.voice.popupFromVoice)
        // With the popup open, the mic does nothing.
        rig.voice.micTapped()
        #expect(rig.voice.phase == .idle)
        #expect(rig.listener.starts.isEmpty)
    }

    // MARK: Pieces

    @Test(arguments: [
        ("confirm", SpokenAnswer?.some(.confirm)), ("Confirm", .confirm), ("  CONFIRM.  ", .confirm), ("confirm!", .confirm),
        ("Cancel", .cancel), ("cancel?", .cancel),
        ("confirm that later", nil), ("yes", nil), ("confirmed", nil), ("", nil), ("con firm", nil), (".confirm", nil),
    ])
    func onlyAWholeConfirmOrCancelIsAnAnswer(_ heard: String, _ answer: SpokenAnswer?) {
        #expect(SpokenAnswer(heard) == answer, "\(heard)")
    }

    @Test func namesComeFromTitlesMostFrequentFirstAndAtMostAHundred() {
        #expect(ContextualNames.from(titles: [
            "Lunch with Rahaf", "Rahaf's birthday", "Call Rahaf", "Dentist", "1:1 with Sam", "Meeting with Sam", "the gym",
        ]) == ["Rahaf", "Sam", "Rahaf's", "Dentist"])
        let many = (0..<150).map { "Name\(String(UnicodeScalar(65 + $0 % 26)!))\(String(UnicodeScalar(97 + $0 / 26)!))" }
        #expect(ContextualNames.from(titles: many).count == 100)
    }

    @Test func theVoiceListIsEnglishGroupedAndCharacterVoicesComeLast() {
        let voices = [
            VoiceInfo(identifier: "zarvox", name: "Zarvox", language: "en-US", quality: .standard, isNovelty: true),
            VoiceInfo(identifier: "bells", name: "Bells", language: "en-US", quality: .standard, isNovelty: true),
            VoiceInfo(identifier: "samantha", name: "Samantha", language: "en-US", quality: .standard),
            VoiceInfo(identifier: "ava", name: "Ava", language: "en-US", quality: .premium),
            VoiceInfo(identifier: "zoe", name: "Zoe", language: "en-US", quality: .enhanced),
            VoiceInfo(identifier: "daniel", name: "Daniel", language: "en-GB", quality: .standard),
            VoiceInfo(identifier: "karen", name: "Karen", language: "en-AU", quality: .standard),
            VoiceInfo(identifier: "moira", name: "Moira", language: "en-IE", quality: .standard),
            VoiceInfo(identifier: "rishi", name: "Rishi", language: "en-IN", quality: .standard),
            VoiceInfo(identifier: "fiona", name: "Fiona", language: "en-scotland", quality: .standard),
            VoiceInfo(identifier: "mine", name: "My Voice", language: "en-US", quality: .premium, isPersonal: true),
            VoiceInfo(identifier: "thomas", name: "Thomas", language: "fr-FR", quality: .standard),
        ]
        let groups = VoiceCatalog.groups(voices, phoneRegion: "US")
        #expect(groups.map(\.title) == [
            "English (United States)", "English (United Kingdom)", "English (Australia)", "English (Ireland)",
            "English (India)", groups[5].title, "Character voices",
        ])
        #expect(groups[0].voices.map(\.identifier) == ["ava", "zoe", "samantha"])
        #expect(groups.last?.voices.map(\.identifier) == ["bells", "zarvox"])
        let all = groups.flatMap(\.voices).map(\.identifier)
        #expect(!all.contains("mine"))
        #expect(!all.contains("thomas"))
        #expect(all.contains("fiona"))

        // Today's voices before Eloquence and the old MacinTalk ones (which
        // the system does not mark as character voices).
        let families = VoiceCatalog.groups([
            VoiceInfo(identifier: "com.apple.speech.synthesis.voice.Fred", name: "Fred", language: "en-US", quality: .standard),
            VoiceInfo(identifier: "com.apple.eloquence.en-US.Eddy", name: "Eddy", language: "en-US", quality: .standard),
            VoiceInfo(identifier: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", quality: .standard),
            VoiceInfo(identifier: "com.apple.voice.enhanced.en-US.Ava", name: "Ava", language: "en-US", quality: .enhanced),
        ], phoneRegion: "US")
        #expect(families.first?.voices.map(\.name) == ["Ava", "Samantha", "Eddy", "Fred"])

        // A phone in the UK lists British voices first; the character voices stay last.
        let british = VoiceCatalog.groups(voices, phoneRegion: "GB")
        #expect(british.first?.title == "English (United Kingdom)")
        #expect(british.last?.title == "Character voices")
    }

    @Test func aStoredVoiceThatIsNoLongerInstalledFallsBackToTheDefault() {
        let installed = [VoiceInfo(identifier: "samantha", name: "Samantha", language: "en-US", quality: .standard)]
        #expect(VoiceChoice.resolve("samantha", installed: installed) == "samantha")
        #expect(VoiceChoice.resolve("gone", installed: installed) == nil)
        #expect(VoiceChoice.resolve(nil, installed: installed) == nil)
    }

    @Test func theVoiceSettingIsStoredInTheUserSettings() throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let store = SkyStore(context: context)
        #expect(store.voiceIdentifier == nil)
        store.setVoiceIdentifier("com.apple.voice.compact.en-US.Samantha")
        #expect(SkyStore(context: context).voiceIdentifier == "com.apple.voice.compact.en-US.Samantha")
        store.setVoiceIdentifier(nil)
        #expect(store.voiceIdentifier == nil)
    }

    // MARK: DEBUG launch arguments

    /// The `-debugVoice…` arguments swap in the scripted listener only for
    /// the Google sample; with a real model they do nothing, so no
    /// argument can reach a create in a real calendar.
    @Test func theDebugArgumentsDoNothingWithoutTheSample() async throws {
        let defaults = UserDefaults.standard
        defaults.set("lunch tomorrow at noon", forKey: "debugVoiceSay")
        defaults.set("confirm", forKey: "debugVoiceAnswer")
        defer {
            defaults.removeObject(forKey: "debugVoiceSay")
            defaults.removeObject(forKey: "debugVoiceAnswer")
        }
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let real = adder(await connected(context))
        #expect(VoiceDebug.fakes(adder: real) == nil)

        let sample = AddEventModel(google: try GoogleCalendarModel.sample(), timeZone: { .current })
        #expect(sample.usesSample)
        #expect(VoiceDebug.fakes(adder: sample) != nil)
    }
}
