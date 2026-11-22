#if DEBUG
import Foundation

/// The voice flow's launch arguments, for screenshots on the Simulator,
/// which cannot be relied on for the microphone or on-device recognition.
/// They take effect only with the DEBUG Google sample (`-debugGoogle YES`,
/// checked on the model, not the argument), which sends nothing: with a real
/// connection the real recognizer and speaker are used and these are ignored,
/// so no launch argument can reach a create in a real calendar.
///
/// - `-debugVoiceSay "lunch with Rahaf tomorrow at noon"`: the mic hears this,
///   word by word, then a pause.
/// - `-debugVoiceAnswer confirm`: what is heard in the answer window
///   (anything; only "confirm" or "cancel" answers).
/// - `-debugVoiceHold YES`: listening never ends on its own (for a
///   screenshot of the listening state or the answer window).
/// - `-debugVoiceUnavailable unsupported|micDenied|speechDenied|restricted|busy`:
///   the mic reports this instead of listening.
/// - `-debugVoiceStart YES`: the mic is tapped when the day screen opens.
enum VoiceDebug {
    static var isRequested: Bool {
        let defaults = UserDefaults.standard
        return ["debugVoiceSay", "debugVoiceAnswer", "debugVoiceUnavailable"].contains { defaults.string(forKey: $0) != nil }
            || defaults.bool(forKey: "debugVoiceHold") || defaults.bool(forKey: "debugVoiceStart")
    }

    static var startsAtOnce: Bool {
        UserDefaults.standard.bool(forKey: "debugVoiceStart")
    }

    /// The scripted listener and speaker, or nil when the arguments are not
    /// given or the Google model is not the sample.
    @MainActor
    static func fakes(adder: AddEventModel) -> (any SpeechListening, any SpeechSpeaking, VoiceEntryModel.Timing)? {
        guard adder.usesSample, isRequested else { return nil }
        let defaults = UserDefaults.standard
        let hold = defaults.bool(forKey: "debugVoiceHold")
        var scripts: [[String]] = []
        if let say = defaults.string(forKey: "debugVoiceSay") { scripts.append(Self.growing(say)) }
        if let answer = defaults.string(forKey: "debugVoiceAnswer") { scripts.append(Self.growing(answer)) }
        let availability: SpeechAvailability = switch defaults.string(forKey: "debugVoiceUnavailable") {
        case "unsupported": .unsupported
        case "micDenied": .micDenied
        case "speechDenied": .speechDenied
        case "restricted": .restricted
        case "busy": .busy
        default: .ready
        }
        var timing = VoiceEntryModel.Timing()
        if hold {
            timing.pause = .seconds(600)
            timing.firstWords = .seconds(600)
            timing.phraseLimit = .seconds(600)
            timing.answerWindow = .seconds(600)
        }
        return (ScriptedSpeechListener(availability: availability, scripts: scripts), TimedSpeechSpeaker(), timing)
    }

    /// "lunch with Rahaf" → ["lunch", "lunch with", "lunch with Rahaf"].
    static func growing(_ text: String) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        return words.indices.map { words[0...$0].joined(separator: " ") }
    }
}

/// Hears scripted words: each `start` takes the next script and reports
/// its partial results a quarter second apart; `finish` gives the last of
/// them as the final result. With no script left it hears nothing.
@MainActor
final class ScriptedSpeechListener: SpeechListening {
    private let fixed: SpeechAvailability
    private var scripts: [[String]]
    private var continuation: AsyncStream<SpeechEvent>.Continuation?
    private var feeding: Task<Void, Never>?
    private var latest = ""

    init(availability: SpeechAvailability, scripts: [[String]]) {
        fixed = availability
        self.scripts = scripts
    }

    func availability() -> SpeechAvailability { fixed }

    func requestPermission() async -> SpeechAvailability { fixed }

    func start(contextualStrings: [String]) throws -> AsyncStream<SpeechEvent> {
        stop()
        let (stream, continuation) = AsyncStream.makeStream(of: SpeechEvent.self)
        self.continuation = continuation
        latest = ""
        let script = scripts.isEmpty ? [] : scripts.removeFirst()
        feeding = Task { [weak self] in
            for words in script {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.latest = words
                continuation.yield(.partial(words))
            }
        }
        return stream
    }

    func finish() {
        feeding?.cancel()
        continuation?.yield(.final(latest))
        continuation?.finish()
        continuation = nil
    }

    func stop() {
        feeding?.cancel()
        feeding = nil
        continuation?.finish()
        continuation = nil
    }
}

/// "Speaks" by waiting a little, about as long as reading the text would take.
@MainActor
final class TimedSpeechSpeaker: SpeechSpeaking {
    private var waiting: Task<Void, Never>?

    func speak(_ text: String, voiceIdentifier: String?) async -> SpeakOutcome {
        stop()
        let wait = Task<Void, Never> { try? await Task.sleep(for: .milliseconds(40 * text.count)) }
        waiting = wait
        await wait.value
        return wait.isCancelled ? .stopped : .finished
    }

    func stop() {
        waiting?.cancel()
        waiting = nil
    }
}
#endif
