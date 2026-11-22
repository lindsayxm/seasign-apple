import AVFoundation
import SwiftData
import SwiftUI

extension SkyStore {
    /// The voice chosen in Settings (task 172), as stored; nil is the
    /// system default. `VoiceChoice` falls back when it is not installed.
    var voiceIdentifier: String? {
        settings().voiceIdentifier
    }

    func setVoiceIdentifier(_ identifier: String?) {
        settings().voiceIdentifier = identifier
        try? context.save()
    }
}

/// The Voice part of Settings (task 172): which voice reads the confirm
/// popup aloud after an event is said with the mic. "System default" plus
/// the English voices installed on the phone, grouped by region with the
/// character voices last, and Preview, which reads a sample confirmation.
/// A stored voice that is no longer installed shows (and reads) as the
/// system default.
struct VoiceSettingsSection: View {
    @Environment(\.modelContext) private var context

    @State private var groups: [VoiceCatalog.Group] = []
    @State private var selected: String?
    @State private var choosing = false
    @State private var preview = VoicePreview()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(caps: "Voice")
                .capsRelative(11)
                .foregroundStyle(Palette.dimText)
                .padding(.top, 24)
                .accessibilityAddTraits(.isHeader)

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(caps: selectedName)
                        .capsRelative(12, medium: true, tracking: 0.12)
                        .foregroundStyle(Palette.white)
                    if let detail = selectedDetail {
                        Text(caps: detail)
                            .capsRelative(9.5, tracking: 0.12)
                            .foregroundStyle(Palette.dimText)
                    }
                }
                Spacer()
                pill(preview.isPlaying ? "Stop" : "Preview") { preview.toggle(voice: selected) }
                    .accessibilityLabel(preview.isPlaying ? "Stop the preview" : "Preview the voice")
            }

            textLink(choosing ? "Done" : "Change voice") { choosing.toggle() }

            if choosing {
                VStack(alignment: .leading, spacing: 0) {
                    row(name: "System default", detail: defaultDetail, identifier: nil)
                    ForEach(groups) { group in
                        Text(caps: group.title)
                            .capsRelative(9.5, tracking: 0.15)
                            .foregroundStyle(Palette.dimText)
                            .padding(.top, 16)
                            .padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.voices) { voice in
                            row(name: voice.name, detail: voice.quality.label, identifier: voice.identifier)
                        }
                    }
                }
            }

            Text(caps: "After you add an event with the mic, Seasign reads it aloud in this voice. The voices are on this iPhone; more can be downloaded in the iPhone's Settings, under Accessibility, Spoken Content, Voices.")
                .capsRelative(10, tracking: 0.12)
                .lineSpacing(4)
                .foregroundStyle(Palette.dimText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: load)
        .onDisappear { preview.stop() }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            load()
        }
    }

    private func load() {
        let installed = VoiceCatalog.installed()
        groups = VoiceCatalog.groups(installed)
        selected = VoiceChoice.resolve(SkyStore(context: context).voiceIdentifier, installed: installed)
    }

    private var allVoices: [VoiceInfo] {
        groups.flatMap(\.voices)
    }

    private var selectedName: String {
        guard let selected, let voice = allVoices.first(where: { $0.identifier == selected }) else { return "System default" }
        return voice.name
    }

    private var selectedDetail: String? {
        guard let selected, let voice = allVoices.first(where: { $0.identifier == selected }) else { return defaultDetail }
        let region = VoiceCatalog.regionName(VoiceCatalog.region(of: voice.language))
        return [region, voice.quality.label].compactMap { $0 }.joined(separator: " · ")
    }

    /// The default voice's own name, when there is one.
    private var defaultDetail: String? {
        VoiceChoice.defaultVoice()?.name
    }

    private func choose(_ identifier: String?) {
        selected = identifier
        SkyStore(context: context).setVoiceIdentifier(identifier)
    }

    private func row(name: String, detail: String?, identifier: String?) -> some View {
        let isSelected = selected == identifier
        return Button {
            choose(identifier)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(isSelected ? Palette.white : Color.clear)
                    .overlay(Circle().stroke(Palette.dimText, lineWidth: 1))
                    .frame(width: 9, height: 9)
                Text(caps: name)
                    .capsRelative(11, medium: isSelected, tracking: 0.12)
                    .foregroundStyle(Palette.white)
                if let detail {
                    Text(caps: detail)
                        .capsRelative(9.5, tracking: 0.12)
                        .foregroundStyle(Palette.dimText)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: [name, detail].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func pill(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(caps: label)
                .capsRelative(11, medium: true)
                .foregroundStyle(Palette.charcoal)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(Palette.white, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func textLink(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(caps: label)
                .capsRelative(10)
                .foregroundStyle(Palette.dimText)
                .underline()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Settings' Preview button: plays the sample in the chosen voice; a second
/// tap stops it.
@MainActor
@Observable
final class VoicePreview {
    private(set) var isPlaying = false

    @ObservationIgnored private let makeSpeaker: @MainActor () -> any SpeechSpeaking
    @ObservationIgnored private var speaker: (any SpeechSpeaking)?
    /// Bumped by every Preview and Stop: an older preview that ends later
    /// does not turn the button back while a newer one plays.
    @ObservationIgnored private var run = 0

    init(makeSpeaker: @escaping @MainActor () -> any SpeechSpeaking = { SystemSpeechSpeaker() }) {
        self.makeSpeaker = makeSpeaker
    }

    func toggle(voice: String?) {
        if isPlaying {
            stop()
            return
        }
        let speaker = speaker ?? makeSpeaker()
        self.speaker = speaker
        run += 1
        let mine = run
        isPlaying = true
        Task {
            _ = await speaker.speak(VoiceWords.preview, voiceIdentifier: voice)
            guard mine == run else { return }
            isPlaying = false
        }
    }

    func stop() {
        run += 1
        speaker?.stop()
        isPlaying = false
    }
}
