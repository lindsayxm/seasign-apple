import Foundation

// Task 172: adding an event by voice. The mic records one phrase, recognised
// on the phone; the confirm popup reads the event aloud and listens, for a
// few seconds after the reading ends, for a spoken "confirm" or "cancel".
// The recognizer and the speaker sit behind these two protocols, so the
// whole flow (`VoiceEntryModel`) is tested with fakes; the real ones
// (`SystemSpeechListener`, `SystemSpeechSpeaker`) are thin.

/// Whether the mic can listen now, as far as is known without asking.
enum SpeechAvailability: Equatable, Sendable {
    /// Permissions given and on-device recognition ready.
    case ready
    /// Speech recognition or the microphone has not been asked for yet.
    case needsPermission
    /// This phone cannot recognise English speech on the phone itself; the
    /// mic stays off rather than send audio to a server.
    case unsupported
    case micDenied
    case speechDenied
    /// Speech recognition or the microphone is restricted on this phone.
    case restricted
    /// Recognition is not available right now (it can come back).
    case busy
}

/// What the recognizer reports while it listens.
enum SpeechEvent: Equatable, Sendable {
    /// The words so far; later ones may change them.
    case partial(String)
    /// The whole utterance, after the audio ended. Nothing follows.
    case final(String)
    /// Listening ended without a result. Nothing follows.
    case failed(SpeechFailure)
}

enum SpeechFailure: Error, Equatable, Sendable {
    /// A call, an alarm or another app took the audio.
    case interrupted
    /// The recognizer heard no speech: silence, not a fault
    /// (`kAFAssistantErrorDomain` 1110, "Failed to recognize any speech").
    case noSpeech
    /// Recognition could not start, or the recognizer stopped with any
    /// other error (on the Simulator a missing on-device model ended every
    /// attempt with `kAFAssistantErrorDomain` 1101).
    case unavailable
}

/// The microphone and speech recognition. Everything is on the main actor;
/// a real implementation hops its audio and recognition callbacks there.
@MainActor
protocol SpeechListening: AnyObject {
    /// What is known now, without asking the user anything.
    func availability() -> SpeechAvailability
    /// Asks for whatever has not been asked yet (the system prompts appear
    /// here, and only here), then answers as `availability()`.
    func requestPermission() async -> SpeechAvailability
    /// Starts listening (on the phone only). Events arrive until a final
    /// result or a failure; throws when listening cannot start.
    func start(contextualStrings: [String]) throws -> AsyncStream<SpeechEvent>
    /// No more audio: the final result follows.
    func finish()
    /// Stops at once, drops any result and releases the microphone and
    /// the audio session.
    func stop()
}

enum SpeakOutcome: Equatable, Sendable {
    /// Spoken to the end.
    case finished
    /// Stopped before the end (`stop()`).
    case stopped
    /// Could not be spoken, or did not end in time.
    case failed
}

/// Reading aloud.
@MainActor
protocol SpeechSpeaking: AnyObject {
    /// Speaks `text` in the voice with `voiceIdentifier` (nil, or one that is
    /// not installed: the system default English voice) and returns when it
    /// has ended.
    func speak(_ text: String, voiceIdentifier: String?) async -> SpeakOutcome
    /// Stops speaking at once; the `speak` waiting returns `.stopped`.
    func stop()
}

/// A spoken answer to the confirm popup. Only a whole utterance that is
/// exactly "confirm" or "cancel" counts, ignoring case, white space around
/// it and punctuation at its end: "Confirm." is confirm, "confirm that
/// later" is nothing. "Yes" is not taken: it is too common in speech that
/// is not meant for the phone, and this answer writes to a real calendar.
enum SpokenAnswer: Equatable, Sendable {
    case confirm
    case cancel

    init?(_ transcript: String) {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.unicodeScalars.last, CharacterSet(charactersIn: ".!?,;:…").contains(last) {
            text.unicodeScalars.removeLast()
        }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "confirm": self = .confirm
        case "cancel": self = .cancel
        default: return nil
        }
    }
}

/// Names from the user's own event titles, given to the recognizer as
/// `contextualStrings` so names like "Rahaf" are heard. Words that start
/// with a capital letter, most frequent first, at most 100 (Apple's limit).
enum ContextualNames {
    static let limit = 100

    /// Capitalised words that say nothing about a name.
    private static let common: Set<String> = [
        "a", "an", "and", "at", "for", "from", "in", "of", "on", "the", "to", "with", "my", "our", "i",
        "meeting", "call", "lunch", "dinner", "breakfast", "coffee", "appointment", "event", "review",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow",
        "am", "pm", "no", "title",
    ]

    static func from(titles: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var spelling: [String: String] = [:]
        var order = 0
        for title in titles {
            for raw in title.split(whereSeparator: { $0.isWhitespace || $0 == "/" }) {
                let word = String(raw).trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
                guard let first = word.first, first.isUppercase, word.count >= 2, word.count <= 30,
                      word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { continue }
                let key = word.lowercased()
                guard !common.contains(key) else { continue }
                counts[key, default: 0] += 1
                if firstSeen[key] == nil {
                    firstSeen[key] = order
                    spelling[key] = word
                    order += 1
                }
            }
        }
        return counts.keys
            .sorted { (counts[$0]!, -firstSeen[$0]!) > (counts[$1]!, -firstSeen[$1]!) }
            .prefix(limit)
            .compactMap { spelling[$0] }
    }
}

/// What the mic says when it cannot listen, or heard nothing; shown on the
/// day screen under the date, with the + still there.
enum VoiceNotice: Equatable, Sendable {
    case unsupported
    case micDenied
    case speechDenied
    case restricted
    case busy
    case notHeard
    /// The recognizer failed with nothing heard: not silence, so the mic
    /// is not blamed.
    case cannotRecognize
    case interrupted

    var message: String {
        switch self {
        case .unsupported:
            "This iPhone can't recognise speech on the phone itself, so the mic is off and nothing you say is sent anywhere. Use + to type the event."
        case .micDenied:
            "Seasign isn't allowed to use the microphone. Turn it on in the iPhone's Settings, or use + to type the event."
        case .speechDenied:
            "Seasign isn't allowed to recognise speech. Turn on Speech Recognition in the iPhone's Settings, or use + to type the event."
        case .restricted:
            "The microphone or speech recognition is restricted on this iPhone. Use + to type the event."
        case .busy:
            "Speech recognition isn't available right now. Try the mic again in a moment, or use + to type the event."
        case .notHeard:
            "Nothing was heard. Tap the mic and say the event and when, like “Lunch with Ann tomorrow at noon”."
        case .cannotRecognize:
            "Speech can't be recognised on this iPhone right now. Use + to type the event, or try the mic again later."
        case .interrupted:
            "Listening stopped because another sound took over. Tap the mic to try again."
        }
    }

    /// The fix is in the iPhone's Settings app.
    var opensSystemSettings: Bool {
        self == .micDenied || self == .speechDenied
    }
}

/// The popup's problems and blocks, worded to be heard after a mic entry.
enum VoiceWords {
    /// After the draft's own sentence.
    static let answerPrompt = "Say confirm or cancel."

    /// The sample Settings plays for Preview.
    static let preview = "Lunch with Ann, Monday at 12 PM, one hour. Say confirm or cancel."

    static func spoken(_ problem: EventDraftProblem) -> String {
        switch problem {
        case .empty, .noTitle:
            "I couldn't tell what the event is. Say what and when, like lunch with Ann tomorrow at noon."
        case .unclearTime:
            "I couldn't understand the time. Say it like three p.m. or three thirty p.m."
        case .partOfDay:
            "Please give a time as well as the part of the day, like tomorrow at seven p.m."
        case .unclearDay:
            "I couldn't understand the day. Say it like Sunday, tomorrow or December 3rd."
        case .twoDays:
            "That named more than one day. Please give just one."
        case .noSuchDate:
            "That date doesn't exist."
        case .badLength:
            "An event can last at most a day."
        case .outOfRange:
            "Events can be added from a year ago up to five years ahead."
        case .relativeTime:
            "Please give a day and a time, like today at three p.m., instead of a time from now."
        }
    }

    static func spoken(_ block: AddEventModel.Block) -> String {
        "This event can't be added yet. " + block.message
    }
}
