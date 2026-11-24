import SwiftData
import SwiftUI
import UIKit

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

    /// Saves a hue a drag wrote with `save: false` and never saved (task
    /// 196): the drag was cancelled, or Settings closed during it. Nothing
    /// happens when nothing is waiting, so it can be called at every chance.
    func saveHUDHue() {
        if context.hasChanges { try? context.save() }
    }
}

/// One touch on the hue track (task 196), kept apart from the view so it can
/// be tested. The track sits in Settings' scroll view, so a touch is decided
/// once, after the finger has moved `slop` points: mostly sideways, and it
/// sets the hue as it moves; mostly up or down, and it is a scroll, which
/// changes nothing for the rest of the touch. A touch that lifts before it
/// is decided is a tap, which sets the hue where it lifts.
///
/// On screen the drag is a UIKit pan (`HueTrackPan`) that begins only when
/// `isSideways` says so; otherwise it fails at once and the scroll view,
/// which waits for it, scrolls.
struct HueTouch: Equatable {
    enum Kind: Equatable {
        case undecided
        /// Sideways: the hue follows the finger.
        case tracking
        /// Up or down: a scroll that passes through.
        case ignored
    }

    /// How far the finger moves before the touch is decided, in points.
    static let slop: CGFloat = 8

    private(set) var kind: Kind = .undecided
    /// A hue was written during this touch and not saved yet.
    private(set) var owesSave = false

    /// A drag that `isSideways` let begin: it is decided, whatever its
    /// first few points of movement were.
    mutating func beganSideways() {
        kind = .tracking
    }

    /// The finger has moved `translation` from where it went down: whether
    /// this movement sets the hue (written, not saved).
    mutating func moved(_ translation: CGSize) -> Bool {
        if kind == .undecided { kind = Self.kind(for: translation) }
        guard kind == .tracking else { return false }
        owesSave = true
        return true
    }

    /// The finger lifted `translation` from where it went down: whether to
    /// set the hue where it lifted and save it (a tap or a sideways drag).
    /// A touch not decided yet is decided by where it lifted, so a scroll
    /// whose end arrives after the touch was reset still sets nothing.
    mutating func ended(_ translation: CGSize) -> Bool {
        let kind = kind == .undecided ? Self.kind(for: translation) : kind
        self = HueTouch()
        return kind != .ignored
    }

    /// The touch went away without `ended` (the scroll view took it,
    /// Settings closed): whether a hue written during it must be saved now.
    /// Also called after every end; it owes nothing then.
    mutating func cancelled() -> Bool {
        let owes = owesSave
        self = HueTouch()
        return owes
    }

    /// Whether a drag that has just moved `translation` may begin: more
    /// sideways than up or down. A drag up or down is left to the scroll view.
    static func isSideways(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height)
    }

    private static func kind(for translation: CGSize) -> Kind {
        let across = abs(translation.width)
        let down = abs(translation.height)
        guard max(across, down) >= slop else { return .undecided }
        return across >= down ? .tracking : .ignored
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
            } saveWaiting: {
                SkyStore(context: context).saveHUDHue()
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
        // Settings closed during a drag: keep the hue it showed.
        .onDisappear { SkyStore(context: context).saveHUDHue() }
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
/// stored). A sideways drag sets the hue as it moves and saves when it ends,
/// a tap sets it where it lands, and a drag up or down is left to the
/// scroll view (`HueTouch`); a touch that is cancelled saves what it set;
/// VoiceOver reads it as "HUD colour" with the hue as its value and adjusts
/// it in steps of `HUDHueSlider.step` degrees.
private struct HueTrack: View {
    var stored: Double?
    /// A new hue, and whether the change is finished (save it).
    var set: (Double, Bool) -> Void
    /// Saves a hue written during a touch that never ended.
    var saveWaiting: () -> Void

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
            // A tap sets the hue where it lands; a sideways drag moves it
            // (`HueTrackPan`). A drag up or down scrolls the page and
            // changes nothing.
            .onTapGesture(coordinateSpace: .local) { location in
                set(HUDHueSlider.hue(atX: location.x, width: width), true)
            }
            .gesture(HueTrackPan(width: width, set: set, saveWaiting: saveWaiting))
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

/// The hue track's drag (task 196): a UIKit pan, so it can stand aside for
/// the scroll view. It begins only when the finger first moves sideways
/// (`HueTouch.isSideways`); the scroll view's pan waits for it to fail, so
/// a drag up or down that starts on the track scrolls the page and never
/// touches the colour. It sets the hue as it moves and saves when it ends;
/// a cancelled drag (the system took the touch, Settings closed) saves
/// what it set (`HueTouch.cancelled`).
private struct HueTrackPan: UIGestureRecognizerRepresentable {
    var width: CGFloat
    var set: (Double, Bool) -> Void
    var saveWaiting: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var touch = HueTouch()

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let moved = pan.translation(in: pan.view)
            return HueTouch.isSideways(CGSize(width: moved.x, height: moved.y))
        }

        /// The scroll view's pan waits for this one to fail.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let coordinator = context.coordinator
        let moved = context.converter.localTranslation ?? .zero
        let translation = CGSize(width: moved.x, height: moved.y)
        let hue = HUDHueSlider.hue(atX: context.converter.localLocation.x, width: width)
        switch recognizer.state {
        case .began:
            coordinator.touch.beganSideways()
            if coordinator.touch.moved(translation) { set(hue, false) }
        case .changed:
            if coordinator.touch.moved(translation) { set(hue, false) }
        case .ended:
            if coordinator.touch.ended(translation) { set(hue, true) }
        case .cancelled, .failed:
            if coordinator.touch.cancelled() { saveWaiting() }
        default:
            break
        }
    }
}

