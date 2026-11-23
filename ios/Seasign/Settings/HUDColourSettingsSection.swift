import SwiftData
import SwiftUI

extension SkyStore {
    /// The HUD accent's hue chosen in Settings (task 195), as stored; nil is
    /// the default orange-red. `HUDAccentRoot` reads the same row.
    var hudHue: Double? {
        settings().hudHue
    }

    /// Sets the HUD hue (nil goes back to the default orange-red), creating
    /// the settings row if there is none, as every setting does. `save`
    /// false leaves the write in the context for a drag still under way;
    /// the screens follow at once either way, and the drag's end saves.
    func setHUDHue(_ hue: Double?, save: Bool = true) {
        let settings = settings()
        if settings.hudHue != hue { settings.hudHue = hue }
        if save { try? context.save() }
    }
}

/// The HUD colour slider's arithmetic (task 195), kept apart from the view
/// so it can be tested: where the thumb sits, what a touch or VoiceOver
/// sets, and what VoiceOver says.
enum HUDHueSlider {
    /// The slider runs over the whole hue circle, in degrees.
    static let range: ClosedRange<Double> = 0...360
    /// One VoiceOver swipe moves the hue this many degrees.
    static let step: Double = 10
    /// The track is drawn from the accent at every this many degrees.
    static let trackSpacing = 5

    /// Where the thumb sits for the stored hue: the hue itself, held to the
    /// slider's range, or the default's own hue when none is stored.
    static func shownHue(_ stored: Double?) -> Double {
        guard let stored, stored.isFinite else { return HUDAccent.defaultHue }
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    /// The hue for a touch at `x` along a track `width` wide, in whole
    /// degrees; touches past either end give that end.
    static func hue(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0, x.isFinite else { return range.lowerBound }
        let fraction = min(max(Double(x / width), 0), 1)
        return (fraction * range.upperBound).rounded()
    }

    /// Where the thumb's centre sits along a track `width` wide.
    static func x(forHue hue: Double, width: CGFloat) -> CGFloat {
        CGFloat(hue / range.upperBound) * width
    }

    /// The hue after one VoiceOver swipe up (`up`) or down: the next whole
    /// step of `step` degrees, kept inside the range.
    static func adjusted(_ stored: Double?, up: Bool) -> Double {
        let current = shownHue(stored)
        if up {
            return min(range.upperBound, (current / step).rounded(.down) * step + step)
        }
        return max(range.lowerBound, (current / step).rounded(.up) * step - step)
    }

    /// What VoiceOver says as the slider's value.
    static func spokenValue(_ stored: Double?) -> String {
        let degrees = Int(shownHue(stored).rounded())
        return stored == nil
            ? "default orange-red, hue \(degrees) degrees"
            : "hue \(degrees) degrees"
    }

    /// The track's colours, left to right: the accent the app would use at
    /// each hue (`HUDAccent.rgb(hue:)`), not the raw hue circle.
    static let trackColours: [SRGB] = stride(from: 0, through: Int(range.upperBound), by: trackSpacing)
        .map { HUDAccent.rgb(hue: Double($0)) }
}

/// The HUD colour part of Settings (task 195): one hue slider whose track
/// shows the accent each hue gives, a live preview (a filled tile, an
/// outlined tile and a line of accent text on the dark plate), and Default,
/// which goes back to the orange-red. It writes `Settings.hudHue` in the
/// main store; every screen follows at once (`HUDAccentRoot`).
struct HUDColourSettingsSection: View {
    @Environment(\.modelContext) private var context
    @Environment(\.hudAccent) private var accent
    @Query private var settings: [Settings]

    private var stored: Double? { settings.first?.hudHue }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HUDSectionHeader(title: "HUD colour")

            preview

            HueTrack(stored: stored) { hue, done in
                SkyStore(context: context).setHUDHue(hue, save: done)
            }

            HStack(alignment: .center, spacing: 16) {
                Text(caps: stored == nil ? "Default orange-red" : "Hue \(Int(HUDHueSlider.shownHue(stored).rounded()))°")
                    .hudText(.detail)
                    .foregroundStyle(Palette.dimText)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                Button {
                    SkyStore(context: context).setHUDHue(nil)
                } label: {
                    Text(caps: "Default")
                }
                .buttonStyle(.hudLink(minWidth: 44, alignment: .trailing))
                .disabled(stored == nil)
                .accessibilityLabel("Default HUD colour")
                .accessibilityHint("Goes back to the orange-red.")
            }

            HUDNote(text: "Every screen uses this colour. Seasign sets its brightness so it stays easy to see on the dark ground.")
        }
    }

    /// A filled tile with dark words, an outlined tile, and a line of
    /// accent text on the plate, in the accent being chosen.
    private var preview: some View {
        HStack(alignment: .center, spacing: 6) {
            HUDTileFace(label: "DAY", glyph: .day, isFilled: true)
                .frame(width: 84)
            HUDTileFace(label: "LIST", glyph: .list, isFilled: false)
                .frame(width: 84)
            Text(verbatim: "Daylight 9h 50m/")
                .font(HUDType.frameLabel.font)
                .kerning(HUDType.frameLabel.drawnKern)
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            .padding(.leading, 6)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Palette.hudPlate, in: HUDShape.rect)
        .overlay(HUDShape.rect.strokeBorder(Palette.rule.opacity(0.6), lineWidth: 1))
        // The slider's value says the colour; the preview is for the eye.
        .accessibilityHidden(true)
    }
}

/// The hue slider itself: a track painted with the accent each hue gives,
/// and a thumb at the stored hue (at the default's hue when none is
/// stored). A drag sets the hue as it moves and saves when it ends;
/// VoiceOver reads it as "HUD colour" with the hue as its value and adjusts
/// it in steps of `HUDHueSlider.step` degrees.
private struct HueTrack: View {
    var stored: Double?
    /// A new hue, and whether the change is finished (save it).
    var set: (Double, Bool) -> Void

    @Environment(\.hudAccent) private var accent

    private static let trackHeight: CGFloat = 22
    private static let thumbWidth: CGFloat = 14
    private static let thumbHeight: CGFloat = 34

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let thumbX = HUDHueSlider.x(forHue: HUDHueSlider.shownHue(stored), width: width)
            ZStack(alignment: .leading) {
                HUDShape.rect
                    .fill(LinearGradient(
                        colors: HUDHueSlider.trackColours.map(\.color),
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(height: Self.trackHeight)
                RoundedRectangle(cornerRadius: 3)
                    .fill(accent)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.white, lineWidth: 2))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.hudPlate, lineWidth: 1))
                    .frame(width: Self.thumbWidth, height: Self.thumbHeight)
                    .offset(x: thumbX - Self.thumbWidth / 2)
            }
            .frame(width: width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in set(HUDHueSlider.hue(atX: drag.location.x, width: width), false) }
                    .onEnded { drag in set(HUDHueSlider.hue(atX: drag.location.x, width: width), true) }
            )
        }
        .frame(height: 44)
        .padding(.horizontal, Self.thumbWidth / 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("HUD colour")
        .accessibilityValue(HUDHueSlider.spokenValue(stored))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(HUDHueSlider.adjusted(stored, up: true), true)
            case .decrement: set(HUDHueSlider.adjusted(stored, up: false), true)
            @unknown default: break
            }
        }
    }
}
