import AVFoundation
import Foundation
import Speech

// The real recognizer and speaker for `VoiceEntryModel` (task 172). Kept
// thin: everything that decides anything is in the model and tested there.
// The Simulator cannot exercise either reliably; they are checked by the
// user on a phone.
//
// Swift 6: the authorization handler, the recognition result handler and
// the audio tap run off the main actor. Their closures are made in
// `nonisolated` static functions, so they carry no main-actor isolation
// (which would trap at run time), and they only touch Sendable things: the
// stream's continuation and the request, whose `append` Apple's own sample
// calls from the tap.

/// English (US) speech recognised on the phone only.
@MainActor
final class SystemSpeechListener: SpeechListening {
    private let locale = Locale(identifier: "en-US")
    /// Kept while a task runs, as Apple's samples keep theirs.
    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<SpeechEvent>.Continuation?
    private var observers: [NSObjectProtocol] = []
    private var sessionActive = false

    init() {}

    func availability() -> SpeechAvailability {
        // On-device recognition first, before any prompt: `requiresOnDeviceRecognition`
        // is honoured only when the recognizer supports it, so without it
        // the mic stays off and nothing is asked.
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            return .unsupported
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: return .needsPermission
        case .denied: return .speechDenied
        case .restricted: return .restricted
        case .authorized: break
        @unknown default: return .restricted
        }
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: return .needsPermission
        case .denied: return .micDenied
        case .granted: break
        @unknown default: return .micDenied
        }
        return recognizer.isAvailable ? .ready : .busy
    }

    func requestPermission() async -> SpeechAvailability {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await Self.requestSpeechAuthorization()
        }
        if SFSpeechRecognizer.authorizationStatus() == .authorized,
           AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
        return availability()
    }

    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func start(contextualStrings: [String]) throws -> AsyncStream<SpeechEvent> {
        stop()
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition,
              recognizer.isAvailable
        else { throw SpeechFailure.unavailable }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            sessionActive = true
        } catch {
            releaseSession()
            throw SpeechFailure.unavailable
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A zero format (no input route) would raise an exception in installTap.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            releaseSession()
            throw SpeechFailure.unavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        request.taskHint = .dictation
        request.contextualStrings = Array(contextualStrings.prefix(ContextualNames.limit))

        let (stream, continuation) = AsyncStream.makeStream(of: SpeechEvent.self)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(request))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            releaseSession()
            throw SpeechFailure.unavailable
        }
        self.engine = engine
        self.request = request
        self.continuation = continuation
        self.recognizer = recognizer
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results(continuation))
        observeInterruptions(continuation)
        return stream
    }

    func finish() {
        stopCapture()
        request?.endAudio()
    }

    func stop() {
        stopCapture()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        continuation?.finish()
        continuation = nil
        releaseSession()
    }

    private func stopCapture() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func releaseSession() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard sessionActive else { return }
        sessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observeInterruptions(_ continuation: AsyncStream<SpeechEvent>.Continuation) {
        let session = AVAudioSession.sharedInstance()
        let name: NSNotification.Name
        if #available(iOS 27.0, *) {
            name = AVAudioSession.didBecomeInactiveNotification
        } else {
            name = AVAudioSession.interruptionNotification
        }
        observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil, using: Self.interrupted(continuation)))
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil,
            using: Self.interrupted(continuation)
        ))
    }

    private nonisolated static func interrupted(_ continuation: AsyncStream<SpeechEvent>.Continuation) -> @Sendable (Notification) -> Void {
        { _ in
            continuation.yield(.failed(.interrupted))
            continuation.finish()
        }
    }

    private nonisolated static func tap(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func results(
        _ continuation: AsyncStream<SpeechEvent>.Continuation
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            if let result {
                let words = result.bestTranscription.formattedString
                if result.isFinal {
                    continuation.yield(.final(words))
                    continuation.finish()
                } else {
                    continuation.yield(.partial(words))
                }
            } else if error != nil {
                continuation.yield(.failed(.unavailable))
                continuation.finish()
            }
        }
    }
}

/// Reads aloud with `AVSpeechSynthesizer`, in the playback category so
/// the record session from listening never silences it, and gives the
/// audio back when it ends.
@MainActor
final class SystemSpeechSpeaker: SpeechSpeaking {
    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = SpeakerDelegate()
    private var sessionActive = false

    init() {
        synthesizer.delegate = delegate
    }

    func speak(_ text: String, voiceIdentifier: String?) async -> SpeakOutcome {
        stop()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            sessionActive = true
        } catch {
            release()
            return .failed
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = VoiceChoice.voice(for: voiceIdentifier)
        // Bounded: if neither callback comes (no output route, say), the
        // reading counts as failed and no answer is listened for.
        let limit = Duration.seconds(4) + .milliseconds(120 * text.count)
        let wait = delegate.expect(utterance)
        synthesizer.speak(utterance)
        let outcome = await PushDeadline.race(wait, deadline: limit, fallback: .failed)
        if outcome == .failed { synthesizer.stopSpeaking(at: .immediate) }
        release()
        return outcome
    }

    func stop() {
        delegate.cancelWaiting()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    private func release() {
        guard sessionActive else { return }
        sessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The synthesizer's callbacks, which may come on any thread.
    private final class SpeakerDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var utterance: ObjectIdentifier?
        private var continuation: CheckedContinuation<SpeakOutcome, Never>?
        private var early: SpeakOutcome?

        /// A task that ends when `utterance` finishes or is cancelled.
        func expect(_ utterance: AVSpeechUtterance) -> Task<SpeakOutcome, Never> {
            let abandoned = lock.withLock { () -> CheckedContinuation<SpeakOutcome, Never>? in
                defer {
                    self.utterance = ObjectIdentifier(utterance)
                    early = nil
                    continuation = nil
                }
                return continuation
            }
            // A wait from an earlier reading that never heard back.
            abandoned?.resume(returning: .stopped)
            return Task {
                await withCheckedContinuation { continuation in
                    let ready = lock.withLock { () -> SpeakOutcome? in
                        if let early { return early }
                        self.continuation = continuation
                        return nil
                    }
                    if let ready { continuation.resume(returning: ready) }
                }
            }
        }

        func cancelWaiting() {
            resolve(nil, .stopped)
        }

        private func resolve(_ utterance: AVSpeechUtterance?, _ outcome: SpeakOutcome) {
            let waiting = lock.withLock { () -> CheckedContinuation<SpeakOutcome, Never>? in
                if let utterance, self.utterance != ObjectIdentifier(utterance) { return nil }
                guard self.utterance != nil else { return nil }
                self.utterance = nil
                defer { continuation = nil }
                if continuation == nil { early = outcome }
                return continuation
            }
            waiting?.resume(returning: outcome)
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            resolve(utterance, .finished)
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            resolve(utterance, .stopped)
        }
    }
}
