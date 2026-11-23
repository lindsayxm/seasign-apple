import Foundation
import Observation

/// Adding an event by voice (task 172), on top of `AddEventModel`:
///
/// 1. The mic is tapped. Permissions are asked here the first time, never at
///    launch; a phone that cannot recognise speech on the phone, or a
///    denied permission, shows a notice and leaves the + button.
/// 2. Listening, on the phone, with the words shown as they come; it stops
///    on a pause, a second tap of the mic, or a hard time limit, and the
///    audio session is released.
/// 3. The words go to the same one-line field and parser as typing
///    (`AddEventModel.open(line:)`, `submit()`), and the popup opens.
/// 4. The popup is read aloud in the chosen voice: the draft's sentence and
///    "Say confirm or cancel."; a problem or a block is read too, with no
///    answer listened for.
/// 5. Only after the reading has ended, listening opens for a few seconds
///    for one whole utterance: exactly "confirm" or "cancel"
///    (`SpokenAnswer`) answers the popup through the same `confirm()` and
///    `cancel()` as the buttons, and only while the popup still shows the
///    draft that was read. Anything else does nothing and leaves the buttons.
///
/// Any tap on the popup, the popup closing, the app leaving the
/// foreground and an audio interruption all stop the reading and close the
/// window. Typed entry never speaks and never listens: this model acts only
/// on what it submitted itself.
@MainActor
@Observable
final class VoiceEntryModel {
    enum Phase: Equatable {
        case idle
        /// The permission prompts (or the check) before listening.
        case asking
        /// Listening for the event; the words so far.
        case listening(String)
        /// Why the mic did not listen, or heard nothing.
        case notice(VoiceNotice)
        /// The popup is being read aloud.
        case speaking
        /// Listening for "confirm" or "cancel".
        case awaitingAnswer
    }

    /// The limits, in real time.
    struct Timing: Sendable {
        /// Listening for the event ends this long after the words last changed.
        var pause: Duration = .milliseconds(1500)
        /// With nothing heard by then, listening ends.
        var firstWords: Duration = .seconds(6)
        /// The hard limit for the event (Apple's is a minute).
        var phraseLimit: Duration = .seconds(15)
        /// How long the final result is waited for after the audio ends.
        var finalWait: Duration = .seconds(2)
        /// How long the answer is listened for after the reading ends.
        var answerWindow: Duration = .seconds(5)
        /// How often the limits are checked.
        var tick: Duration = .milliseconds(50)
    }

    private(set) var phase: Phase = .idle
    /// The popup on screen came from the mic (and still shows what it was
    /// given): it offers Speak again on a problem.
    private(set) var popupFromVoice = false

    @ObservationIgnored private let adder: AddEventModel
    @ObservationIgnored private let makeListener: @MainActor () -> any SpeechListening
    @ObservationIgnored private let makeSpeaker: @MainActor () -> any SpeechSpeaking
    @ObservationIgnored private var madeListener: (any SpeechListening)?
    @ObservationIgnored private var madeSpeaker: (any SpeechSpeaking)?
    @ObservationIgnored private let voiceIdentifier: @MainActor () -> String?
    @ObservationIgnored private let names: @MainActor () -> [String]
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let clock: @MainActor () -> ClockStyle
    @ObservationIgnored private let timing: Timing
    /// Bumped by every start and every interruption; work from an older
    /// run checks it after each wait and stops.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var finishRequested = false
    @ObservationIgnored private(set) var work: Task<Void, Never>?

    init(
        adder: AddEventModel,
        listener: @autoclosure @escaping @MainActor () -> any SpeechListening,
        speaker: @autoclosure @escaping @MainActor () -> any SpeechSpeaking,
        voiceIdentifier: @escaping @MainActor () -> String?,
        names: @escaping @MainActor () -> [String] = { [] },
        now: @escaping @Sendable () -> Date = { Date() },
        clock: @escaping @MainActor () -> ClockStyle = { .system },
        timing: Timing = Timing()
    ) {
        self.adder = adder
        // Made when first needed (`listener`, `speaker`): the day screen
        // builds this model again on every redraw and keeps only the first.
        makeListener = listener
        makeSpeaker = speaker
        self.voiceIdentifier = voiceIdentifier
        self.names = names
        self.now = now
        self.clock = clock
        self.timing = timing
    }

    /// The microphone is on (not while the permission prompts are up:
    /// nothing is heard then, so the screen does not say "Listening").
    var isListening: Bool {
        if case .listening = phase { return true }
        return false
    }

    var notice: VoiceNotice? {
        if case .notice(let notice) = phase { return notice }
        return nil
    }

    /// The words heard so far while listening for the event.
    var heard: String? {
        if case .listening(let words) = phase { return words }
        return nil
    }

    // MARK: Taps

    /// The mic on the day screen: starts listening, or (a second tap while
    /// listening) ends it as a pause would.
    func micTapped() {
        switch phase {
        case .listening:
            finishRequested = true
        case .asking, .speaking, .awaitingAnswer:
            return
        case .idle, .notice:
            guard !adder.isOpen else { return }
            start()
        }
    }

    /// Speak again, from a problem shown after a mic entry: the popup
    /// closes and listening starts over.
    func speakAgain() {
        stopAudio()
        adder.cancel()
        guard !adder.isOpen else { return }
        start()
    }

    /// Any tap on the popup: the reading stops and no answer is listened
    /// for. Listening for the event itself is not touched.
    func popupTouched() {
        guard phase == .speaking || phase == .awaitingAnswer else { return }
        interrupt()
    }

    /// The popup closed (by any route).
    func popupClosed() {
        popupFromVoice = false
        popupTouched()
    }

    /// The + was tapped: the mic stops and its notice goes.
    func typingStarted() {
        interrupt()
        phase = .idle
    }

    /// Stops everything: listening, the reading, the answer window. The
    /// app left the foreground, the day screen closed, or a tap.
    func interrupt() {
        generation += 1
        work?.cancel()
        work = nil
        stopAudio()
        if case .notice = phase { return }
        phase = .idle
    }

    /// Whether the app leaving the foreground should stop the voice: not
    /// while the permission prompts are up (they make the app inactive).
    func sceneChanged(active: Bool) {
        guard !active, phase != .asking else { return }
        interrupt()
    }

    private func stopAudio() {
        madeListener?.stop()
        madeSpeaker?.stop()
    }

    /// The recognizer and the speaker, made when first needed.
    private var listener: any SpeechListening {
        if let madeListener { return madeListener }
        let made = makeListener()
        madeListener = made
        return made
    }

    private var speaker: any SpeechSpeaking {
        if let madeSpeaker { return madeSpeaker }
        let made = makeSpeaker()
        madeSpeaker = made
        return made
    }

    // MARK: The run

    private func start() {
        generation += 1
        let run = generation
        finishRequested = false
        popupFromVoice = false
        phase = .asking
        work = Task { [weak self] in
            await self?.listenForEvent(run)
        }
    }

    private func listenForEvent(_ run: Int) async {
        var availability = listener.availability()
        if availability == .needsPermission {
            availability = await listener.requestPermission()
            guard run == generation else { return }
        }
        if let notice = Self.notice(for: availability) {
            phase = .notice(notice)
            return
        }
        let stream: AsyncStream<SpeechEvent>
        do {
            stream = try listener.start(contextualStrings: ContextualNames.from(titles: names()))
        } catch {
            listener.stop()
            phase = .notice(.busy)
            return
        }
        phase = .listening("")
        let result = await listen(stream, run: run, limit: timing.phraseLimit, firstWords: timing.firstWords, needsFinal: false) { [weak self] words in
            self?.phase = .listening(words)
        }
        // A run that was stopped leaves the microphone alone: `interrupt()`
        // released it, and a newer run may be using it now.
        guard run == generation else { return }
        listener.stop()
        let words: String
        switch result {
        case .final(let text):
            words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .failed(.interrupted):
            phase = .notice(.interrupted)
            return
        case .failed(.unavailable):
            // The recognizer failed with nothing heard: not silence.
            phase = .notice(.cannotRecognize)
            return
        case .failed(.noSpeech):
            // `listen` gives silence as no words; kept for completeness.
            phase = .notice(.notHeard)
            return
        case .cancelled:
            phase = .notice(.busy)
            return
        }
        guard !words.isEmpty else {
            phase = .notice(.notHeard)
            return
        }
        phase = .idle
        guard !adder.isOpen else { return }
        adder.open(line: words)
        adder.submit()
        popupFromVoice = true
        switch adder.stage {
        case .reviewing(let draft):
            await readAloud(draft, run: run)
        case .problem(let problem):
            await read(VoiceWords.spoken(problem), run: run)
        case .blocked(_, let block):
            await read(VoiceWords.spoken(block), run: run)
        default:
            break
        }
    }

    private static func notice(for availability: SpeechAvailability) -> VoiceNotice? {
        switch availability {
        case .ready: nil
        case .needsPermission, .busy: .busy
        case .unsupported: .unsupported
        case .micDenied: .micDenied
        case .speechDenied: .speechDenied
        case .restricted: .restricted
        }
    }

    /// Reads a problem or a block; nothing is listened for afterwards.
    private func read(_ text: String, run: Int) async {
        phase = .speaking
        _ = await speaker.speak(text, voiceIdentifier: voiceIdentifier())
        guard run == generation else { return }
        phase = .idle
    }

    /// Reads the draft, then listens for the answer, but only if the reading
    /// ended on its own and the popup still shows this draft.
    private func readAloud(_ draft: EventDraft, run: Int) async {
        phase = .speaking
        let sentence = DraftSummary(draft, now: now(), clock: clock()).spoken + " " + VoiceWords.answerPrompt
        let outcome = await speaker.speak(sentence, voiceIdentifier: voiceIdentifier())
        guard run == generation else { return }
        guard outcome == .finished, adder.stage == .reviewing(draft) else {
            phase = .idle
            return
        }
        let stream: AsyncStream<SpeechEvent>
        do {
            stream = try listener.start(contextualStrings: ["confirm", "cancel"])
        } catch {
            listener.stop()
            phase = .idle
            return
        }
        phase = .awaitingAnswer
        finishRequested = false
        let result = await listen(stream, run: run, limit: timing.answerWindow, firstWords: timing.answerWindow, needsFinal: true) { _ in }
        guard run == generation else { return }
        listener.stop()
        phase = .idle
        // The final result of the whole window only, never a partial one.
        guard case .final(let text) = result, let answer = SpokenAnswer(text) else { return }
        guard adder.stage == .reviewing(draft) else { return }
        popupFromVoice = false
        switch answer {
        case .confirm: adder.confirm()
        case .cancel: adder.cancel()
        }
    }

    private enum ListenResult: Equatable {
        case final(String)
        case failed(SpeechFailure)
        case cancelled
    }

    /// Why the audio was ended.
    private enum AudioEnd {
        case pause, silence, tap, limit
    }

    /// Reads `stream` until its final result. The audio is ended (and the
    /// final result asked for) on a pause after some words, on a second tap,
    /// with no words by `firstWords`, or at `limit`. A final result that
    /// does not come within `finalWait` after that counts as the last words
    /// heard, unless `needsFinal` (the answer), which takes only a real
    /// final result, and only one that follows a pause: a final result that
    /// came before the audio was ended (the recognizer decided by itself),
    /// or one the limit cut off, may be the start of something longer
    /// ("confirm, wait, it's at four") and counts as none.
    private func listen(
        _ stream: AsyncStream<SpeechEvent>, run: Int, limit: Duration, firstWords: Duration, needsFinal: Bool,
        partial: @escaping (String) -> Void
    ) async -> ListenResult {
        let box = HeardBox()
        let reader = Task { @MainActor in
            for await event in stream {
                switch event {
                case .partial(let words):
                    if words != box.latest {
                        box.latest = words
                        box.changedAt = .now
                        partial(words)
                    }
                case .final(let words):
                    box.final = words
                case .failed(let failure):
                    box.failure = failure
                }
            }
            box.ended = true
        }
        defer { reader.cancel() }
        let started = ContinuousClock.now
        var endedAudioAt: ContinuousClock.Instant?
        var endedBy: AudioEnd?
        while true {
            guard run == generation, !Task.isCancelled else { return .cancelled }
            if let final = box.final {
                if needsFinal, endedBy != .pause { return .cancelled }
                return .final(final)
            }
            if let failure = box.failure {
                // An interruption always ends the run as one. Any other
                // error, before or after the audio was ended, counts as no
                // final result: the answer counts as none, and the event
                // keeps the words heard. With no words, the recognizer's
                // no-speech error is silence ("Nothing was heard"); any
                // other error is a recognizer that could not listen (task
                // 179), which must not send the user to the microphone.
                if failure == .interrupted { return .failed(.interrupted) }
                if needsFinal { return .cancelled }
                if !box.latest.isEmpty || failure == .noSpeech { return .final(box.latest) }
                return .failed(failure)
            }
            let now = ContinuousClock.now
            if let endedAudioAt {
                if box.ended || now - endedAudioAt >= timing.finalWait {
                    // No final result: the event takes the last words; the
                    // answer counts as none.
                    return needsFinal ? .cancelled : .final(box.latest)
                }
            } else if box.ended {
                return needsFinal ? .cancelled : .final(box.latest)
            } else {
                // A pause comes first: when a late check finds the pause and
                // the limit both passed, the words did end before the limit.
                let end: AudioEnd? =
                    if !box.latest.isEmpty && now - box.changedAt >= timing.pause { .pause }
                    else if box.latest.isEmpty && now - started >= firstWords { .silence }
                    else if finishRequested { .tap }
                    else if now - started >= limit { .limit }
                    else { nil }
                if let end {
                    finishRequested = false
                    listener.finish()
                    endedAudioAt = now
                    endedBy = end
                }
            }
            try? await Task.sleep(for: timing.tick)
        }
    }

    @MainActor
    private final class HeardBox {
        var latest = ""
        var changedAt = ContinuousClock.now
        var final: String?
        var failure: SpeechFailure?
        var ended = false
    }
}
