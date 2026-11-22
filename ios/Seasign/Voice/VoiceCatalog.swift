import AVFoundation
import Foundation

/// One installed system voice, as the Voice section lists it (task 172).
struct VoiceInfo: Equatable, Sendable, Identifiable {
    enum Quality: Int, Comparable, Sendable {
        case standard = 1, enhanced, premium

        static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }

        /// "Enhanced", "Premium"; nil for the standard one.
        var label: String? {
            switch self {
            case .standard: nil
            case .enhanced: "Enhanced"
            case .premium: "Premium"
            }
        }
    }

    var identifier: String
    var name: String
    /// BCP 47: "en-US".
    var language: String
    var quality: Quality
    /// Apple's character voices ("Bells", "Bubbles", "Zarvox").
    var isNovelty = false
    /// A Personal Voice the user made; it needs its own permission.
    var isPersonal = false

    var id: String { identifier }

    init(identifier: String, name: String, language: String, quality: Quality, isNovelty: Bool = false, isPersonal: Bool = false) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
        self.isNovelty = isNovelty
        self.isPersonal = isPersonal
    }

    init(_ voice: AVSpeechSynthesisVoice) {
        let quality: Quality = switch voice.quality {
        case .premium: .premium
        case .enhanced: .enhanced
        default: .standard
        }
        self.init(
            identifier: voice.identifier, name: voice.name, language: voice.language, quality: quality,
            isNovelty: voice.voiceTraits.contains(.isNoveltyVoice),
            isPersonal: voice.voiceTraits.contains(.isPersonalVoice)
        )
    }
}

/// The voices the Voice section offers, grouped.
enum VoiceCatalog {
    struct Group: Equatable, Sendable, Identifiable {
        var title: String
        var voices: [VoiceInfo]
        var id: String { title }
    }

    /// The installed voices, as the system lists them.
    static func installed() -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map(VoiceInfo.init)
    }

    /// Regions in the order they are listed; any other English region
    /// follows, by name.
    private static let regionOrder = ["US", "GB", "AU", "CA", "IE", "NZ", "IN", "ZA"]

    /// How natural a voice family sounds, by its identifier: today's voices
    /// ("com.apple.voice…", Siri's) first, then the Eloquence ones, then the
    /// old MacinTalk ones (Fred, Junior, Kathy, Ralph), which the system does
    /// not mark as character voices but which sound like them.
    static func family(_ identifier: String) -> Int {
        if identifier.hasPrefix("com.apple.speech.synthesis.") { return 2 }
        if identifier.hasPrefix("com.apple.eloquence.") { return 1 }
        return 0
    }

    /// English voices only, Personal Voices left out (they need their own
    /// permission). One group per region, the phone's own region first, then
    /// the US, the UK and the rest; in each, today's voices before the older
    /// families (`family`), best quality first, then by name. The character
    /// voices come last, in their own group, never first.
    static func groups(_ voices: [VoiceInfo], phoneRegion: String? = Locale.current.region?.identifier) -> [Group] {
        let english = voices.filter { $0.language.lowercased().hasPrefix("en") && !$0.isPersonal }
        func sorted(_ list: [VoiceInfo]) -> [VoiceInfo] {
            list.sorted {
                if family($0.identifier) != family($1.identifier) { return family($0.identifier) < family($1.identifier) }
                if $0.quality != $1.quality { return $0.quality > $1.quality }
                if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return $0.identifier < $1.identifier
            }
        }
        let regular = english.filter { !$0.isNovelty }
        let byRegion = Dictionary(grouping: regular) { region(of: $0.language) }
        var order = regionOrder
        if let phoneRegion, byRegion[phoneRegion] != nil, let index = order.firstIndex(of: phoneRegion) {
            order.remove(at: index)
            order.insert(phoneRegion, at: 0)
        } else if let phoneRegion, byRegion[phoneRegion] != nil {
            order.insert(phoneRegion, at: 0)
        }
        let rest = byRegion.keys.filter { !order.contains($0) }.sorted { regionName($0) < regionName($1) }
        var groups: [Group] = (order + rest).compactMap { code in
            guard let list = byRegion[code], !list.isEmpty else { return nil }
            return Group(title: regionName(code), voices: sorted(list))
        }
        let novelty = english.filter(\.isNovelty)
        if !novelty.isEmpty {
            groups.append(Group(title: "Character voices", voices: sorted(novelty)))
        }
        return groups
    }

    /// "en-GB" → "GB"; "en" alone → "".
    static func region(of language: String) -> String {
        let parts = language.split(whereSeparator: { $0 == "-" || $0 == "_" })
        return parts.count > 1 ? String(parts[1]).uppercased() : ""
    }

    /// "English (United States)"; "English" with no region.
    static func regionName(_ code: String) -> String {
        guard !code.isEmpty else { return "English" }
        let name = Locale(identifier: "en_US").localizedString(forRegionCode: code) ?? code
        return "English (\(name))"
    }
}

/// Which voice reads aloud.
enum VoiceChoice {
    /// The stored identifier when that voice is still installed; nil (the
    /// system default) otherwise.
    static func resolve(_ stored: String?, installed: [VoiceInfo]) -> String? {
        guard let stored, installed.contains(where: { $0.identifier == stored }) else { return nil }
        return stored
    }

    /// The voice for `identifier`, or the default English voice when it is
    /// nil or no longer installed.
    static func voice(for identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) { return voice }
        return defaultVoice()
    }

    /// The system's voice for the phone's language when that is English,
    /// else for US English.
    static func defaultVoice() -> AVSpeechSynthesisVoice? {
        let code = AVSpeechSynthesisVoice.currentLanguageCode()
        return AVSpeechSynthesisVoice(language: code.lowercased().hasPrefix("en") ? code : "en-US")
    }
}
