import SwiftData
import SwiftUI
import UIKit

extension SkyStore {
    /// The HUD accent's hue chosen in Settings (task 195), as stored; nil is
    /// the default orange-red. `HUDAccentRoot` reads the same row.
    var hudHue: Double? {
        settings().hudHue
    }

    /// The HUD accent's lightness chosen in Settings (task 206), held to
    /// 0...1; nil is lightness 0, the colour of the hue.
    var hudLightness: Double? {
        settings().hudLightness.map { HUDAccent.clampedLightness($0) }
    }

    /// Sets the HUD colour (both nil go back to the default orange-red),
    /// creating the settings row if there is none, as every setting does.
    /// Hue and lightness are written together, so a pick is never half
    /// stored. `save` false leaves the write in the context for a drag
    /// still under way; the screens follow at once either way, and the
    /// drag's end saves.
    func setHUDColour(hue: Double?, lightness: Double?, save: Bool = true) {
        let settings = settings()
        if settings.hudHue != hue { settings.hudHue = hue }
        if settings.hudLightness != lightness { settings.hudLightness = lightness }
        if save { try? context.save() }
    }

    /// Saves a colour a drag wrote with `save: false` and never saved (task
    /// 196): the drag was cancelled, or Settings closed during it. Nothing
    /// happens when nothing is waiting, so it can be called at every chance.
    func saveHUDColour() {
        if context.hasChanges { try? context.save() }
    }
}

/// One point in the colour picker: a hue in whole degrees (0...360) and a
/// lightness in whole percent (0...1).
struct HUDColourPick: Equatable {
    var hue: Double
    var lightness: Double
}

/// What the colour block does with a touch, kept apart from the view so it
/// can be tested (task 196 for the hue track; task 206 for the block). The
/// block sits in Settings' scroll view:
///
/// - A drag that starts in the block is a UIKit pan (`HUDColourFieldPan`)
///   that begins whichever way the finger moves, and the scroll view's pan
///   waits for it to fail, so the page does not scroll under it. A drag
///   that starts outside the block never reaches it and scrolls as usual.
/// - A pan that began sets the colour as it moves (written, not saved),
///   sets it where it lifts and saves when it ends, and, when it is
///   cancelled (the system took the touch, Settings closed), saves what it
///   wrote. UIKit ends a pan once, with either `.ended` or
///   `.cancelled`/`.failed`. A finger that leaves the block keeps moving
///   the marker along the nearest edge.
/// - A tap is SwiftUI's `onTapGesture`, not the pan: it sets the colour
///   where it lands and saves (`tap`).
struct HUDColourTouch: Equatable {
    /// A pan recognizer's state, as far as the block cares.
    enum Phase: Equatable {
        case began
        case changed
        case ended
        /// `.cancelled` or `.failed`.
        case cancelled
    }

    /// What the block does to the stored colour.
    enum Write: Equatable {
        /// Nothing.
        case none
        /// Set hue and lightness; save if `save`, else leave it for a later save.
        case set(HUDColourPick, save: Bool)
        /// Save a colour written earlier and not saved yet.
        case saveWaiting
    }

    /// A colour was written during this pan and not saved yet.
    private(set) var owesSave = false

    /// The pan reached `phase` with the finger at `point` in a block of
    /// `size`: what to write. The touch is reset when the pan ends either way.
    mutating func handle(_ phase: Phase, at point: CGPoint, size: CGSize) -> Write {
        let pick = HUDColourField.pick(at: point, size: size)
        switch phase {
        case .began, .changed:
            owesSave = true
            return .set(pick, save: false)
        case .ended:
            self = HUDColourTouch()
            return .set(pick, save: true)
        case .cancelled:
            let owes = owesSave
            self = HUDColourTouch()
            return owes ? .saveWaiting : .none
        }
    }

    /// A tap at `point` in a block of `size`: the colour there, saved.
    static func tap(at point: CGPoint, size: CGSize) -> Write {
        .set(HUDColourField.pick(at: point, size: size), save: true)
    }
}

/// The colour picker's arithmetic (task 206, from task 195's hue slider),
/// kept apart from the view so it can be tested: what the block shows,
/// where the marker sits, what a touch or VoiceOver sets, and what is said.
///
/// Across the block, left to right, is the hue (0 to 360 degrees); up it is
/// the lightness, from the colour of each hue along the bottom (lightness 0,
/// `HUDAccent.rgb(hue:)`) to white along the top (lightness 1).
enum HUDColourField {
    /// The hue runs over the whole circle, in degrees.
    static let hueRange: ClosedRange<Double> = 0...360
    /// One VoiceOver swipe moves the hue this many degrees.
    static let hueStep: Double = 10
    /// One VoiceOver swipe moves the lightness this many percent.
    static let lightnessStepPercent: Double = 10

    /// The block's picture is one pixel per whole degree (0 to 360) by one
    /// per whole percent of lightness (100 at the top row, 0 at the bottom):
    /// the points a touch can pick.
    static let columns = 361
    static let rows = 101

    /// Where the marker sits across for the stored hue: the hue itself, held
    /// to the range, or the default's own hue when none is stored.
    static func shownHue(_ stored: Double?) -> Double {
        guard let stored, stored.isFinite else { return HUDAccent.defaultHue }
        return min(max(stored, hueRange.lowerBound), hueRange.upperBound)
    }

    /// Where the marker sits up for the stored lightness: held to 0...1;
    /// none stored is the bottom.
    static func shownLightness(_ stored: Double?) -> Double {
        HUDAccent.clampedLightness(stored)
    }

    /// The colour for a touch at `point` in a block of `size`: the hue in
    /// whole degrees across, the lightness in whole percent up from the
    /// bottom. A touch past an edge gives that edge.
    static func pick(at point: CGPoint, size: CGSize) -> HUDColourPick {
        func fraction(_ value: CGFloat, _ length: CGFloat) -> Double {
            guard length > 0, value.isFinite else { return 0 }
            return min(max(Double(value / length), 0), 1)
        }
        let hue = (fraction(point.x, size.width) * hueRange.upperBound).rounded()
        // Up from the bottom; a block with no height, or no position, is the bottom.
        let up = size.height > 0 && point.y.isFinite ? 1 - fraction(point.y, size.height) : 0
        return HUDColourPick(hue: hue, lightness: (up * 100).rounded() / 100)
    }

    /// The marker's centre in a block of `size` for what is stored.
    static func point(hue: Double?, lightness: Double?, size: CGSize) -> CGPoint {
        CGPoint(
            x: CGFloat(shownHue(hue) / hueRange.upperBound) * size.width,
            y: CGFloat(1 - shownLightness(lightness)) * size.height
        )
    }

    /// The hue after one VoiceOver swipe up (`up`) or down: the next whole
    /// step of `hueStep` degrees, kept inside the range.
    static func adjustedHue(_ stored: Double?, up: Bool) -> Double {
        let current = shownHue(stored)
        if up {
            return min(hueRange.upperBound, (current / hueStep).rounded(.down) * hueStep + hueStep)
        }
        return max(hueRange.lowerBound, (current / hueStep).rounded(.up) * hueStep - hueStep)
    }

    /// The lightness after one VoiceOver swipe up (`up`) or down: the next
    /// whole step of `lightnessStepPercent`, kept inside 0...1. Worked in
    /// whole percent so steps land exactly (0.3, not 0.30000000000000004).
    static func adjustedLightness(_ stored: Double?, up: Bool) -> Double {
        let percent = (shownLightness(stored) * 100).rounded()
        let step = lightnessStepPercent
        let next = up
            ? min(100, (percent / step).rounded(.down) * step + step)
            : max(0, (percent / step).rounded(.up) * step - step)
        return next / 100
    }

    /// What VoiceOver says as the hue's value ("HUD color hue, 210 degrees").
    static func spokenHue(_ stored: Double?) -> String {
        let degrees = Int(shownHue(stored).rounded())
        return stored == nil ? "default orange-red, \(degrees) degrees" : "\(degrees) degrees"
    }

    /// What VoiceOver says as the lightness's value ("HUD color lightness,
    /// 40 percent").
    static func spokenLightness(_ stored: Double?) -> String {
        "\(Int((shownLightness(stored) * 100).rounded())) percent"
    }

    /// The line beside Default, describing the current choice (shown in
    /// capitals).
    static func choiceLabel(hue: Double?, lightness: Double?) -> String {
        let percent = Int((shownLightness(lightness) * 100).rounded())
        switch (hue, lightness) {
        case (nil, nil): return "Default orange-red"
        case (nil, _): return "Orange-red · lightness \(percent)%"
        case (_, _): return "Hue \(Int(shownHue(hue).rounded()))° · lightness \(percent)%"
        }
    }

    /// Every colour in the block's picture, row by row from the top
    /// (lightness 1) to the bottom (lightness 0), each row left to right
    /// (hue 0 to 360): exactly what `HUDAccent.rgb(hue:lightness:)` gives
    /// there. Each hue's colour is solved once and mixed for every row.
    static func fieldColours() -> [SRGB] {
        let floors = (0..<columns).map { HUDAccent.rgb(hue: Double($0)) }
        var colours: [SRGB] = []
        colours.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let lightness = Double(rows - 1 - row) / Double(rows - 1)
            for floor in floors {
                colours.append(HUDAccent.mix(floor, toWhite: lightness))
            }
        }
        return colours
    }

    /// The picture's bytes, RGBX with 8 bits each, for an sRGB `CGImage`.
    static func fieldBytes() -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(columns * rows * 4)
        for colour in fieldColours() {
            bytes.append(UInt8((colour.red * 255).rounded()))
            bytes.append(UInt8((colour.green * 255).rounded()))
            bytes.append(UInt8((colour.blue * 255).rounded()))
            bytes.append(255)
        }
        return bytes
    }

    /// The block's picture, made once: an sRGB bitmap of `fieldColours`.
    @MainActor static let fieldImage: CGImage? = {
        let data = Data(fieldBytes())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: columns,
            height: rows,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: columns * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }()

    /// Where the picture is drawn for a block of `size`, so that each
    /// pixel's centre sits on the point a touch there picks (column `i` at
    /// hue `i`, the top row's centre on the top edge): half a pixel spills
    /// past every edge and is clipped. Between pixel centres the picture is
    /// smoothed; neighbours are one degree or one percent apart.
    static func imageFrame(size: CGSize) -> CGRect {
        let columnWidth = size.width / CGFloat(columns - 1)
        let rowHeight = size.height / CGFloat(rows - 1)
        return CGRect(
            x: -columnWidth / 2,
            y: -rowHeight / 2,
            width: size.width + columnWidth,
            height: size.height + rowHeight
        )
    }
}

/// The HUD colour part of Settings (task 195; the picker since task 206): a
/// live preview (a filled tile, an outlined tile and a line of accent text
/// on the dark plate), the colour block, a line that says the choice, and
/// Default, which goes back to the orange-red. It writes `Settings.hudHue`
/// and `Settings.hudLightness` in the main store; every screen follows at
/// once (`HUDAccentRoot`).
struct HUDColourSettingsSection: View {
    @Environment(\.modelContext) private var context
    @Environment(\.hudAccent) private var accent
    @Query private var settings: [Settings]

    private var storedHue: Double? { settings.first?.hudHue }
    private var storedLightness: Double? { settings.first?.hudLightness }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HUDSectionHeader(title: "HUD color")

            preview

            HUDColourBlock(hue: storedHue, lightness: storedLightness) { hue, lightness, done in
                SkyStore(context: context).setHUDColour(hue: hue, lightness: lightness, save: done)
            } saveWaiting: {
                SkyStore(context: context).saveHUDColour()
            }

            HStack(alignment: .center, spacing: 16) {
                Text(caps: HUDColourField.choiceLabel(hue: storedHue, lightness: storedLightness))
                    .hudText(.detail)
                    .foregroundStyle(Palette.dimText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                Button {
                    SkyStore(context: context).setHUDColour(hue: nil, lightness: nil)
                } label: {
                    Text(caps: "Default")
                }
                .buttonStyle(.hudLink(minWidth: 44, alignment: .trailing))
                .disabled(storedHue == nil && storedLightness == nil)
                .accessibilityLabel("Default HUD color")
                .accessibilityHint("Goes back to the orange-red.")
            }

            HUDNote(text: "Every screen uses this color.")
        }
        // Settings closed during a drag: keep the colour it showed.
        .onDisappear { SkyStore(context: context).saveHUDColour() }
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
        // The picker's values say the colour; the preview is for the eye.
        .accessibilityHidden(true)
    }
}

/// The colour block itself (task 206): the picture of every colour the
/// picker can give (`HUDColourField.fieldImage`, drawn from the colour
/// function, not a stock gradient), and a ring at the stored choice (at
/// the default's hue, bottom edge, when none is stored). A drag that starts
/// in the block moves the ring both ways and does not scroll the page; a
/// tap sets the colour where it lands (`HUDColourTouch`). VoiceOver finds
/// two adjustable elements over it: the hue and the lightness.
private struct HUDColourBlock: View {
    var hue: Double?
    var lightness: Double?
    /// A new hue and lightness, and whether the change is finished (save it).
    var set: (Double?, Double?, Bool) -> Void
    /// Saves a colour written during a touch that never ended.
    var saveWaiting: () -> Void

    static let height: CGFloat = 168
    private static let markerSize: CGFloat = 22

    /// Carries out what `HUDColourTouch` decided.
    private func apply(_ write: HUDColourTouch.Write) {
        switch write {
        case .none: break
        case .set(let pick, let save): set(pick.hue, pick.lightness, save)
        case .saveWaiting: saveWaiting()
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let frame = HUDColourField.imageFrame(size: size)
            let marker = HUDColourField.point(hue: hue, lightness: lightness, size: size)
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if let image = HUDColourField.fieldImage {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipShape(HUDShape.rect)
                .overlay(HUDShape.rect.strokeBorder(Palette.rule.opacity(0.6), lineWidth: 1))

                // A white ring between two dark lines reads on any colour,
                // white included.
                ZStack {
                    Circle().stroke(Palette.hudPlate, lineWidth: 5)
                    Circle().stroke(Palette.white, lineWidth: 2.5)
                }
                .frame(width: Self.markerSize, height: Self.markerSize)
                .position(marker)
                .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                apply(HUDColourTouch.tap(at: location, size: size))
            }
            .gesture(HUDColourFieldPan(size: size, apply: apply))
            .accessibilityHidden(true)
            .overlay { voiceOverElements }
        }
        .frame(height: Self.height)
    }

    /// Two adjustable elements over the block, for VoiceOver only: the hue
    /// over the top half, the lightness over the bottom. Each swipe steps
    /// one value and saves, keeping the other as stored.
    private var voiceOverElements: some View {
        VStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .accessibilityElement()
                .accessibilityLabel("HUD color hue")
                .accessibilityValue(HUDColourField.spokenHue(hue))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: set(HUDColourField.adjustedHue(hue, up: true), lightness, true)
                    case .decrement: set(HUDColourField.adjustedHue(hue, up: false), lightness, true)
                    @unknown default: break
                    }
                }
            Color.clear
                .contentShape(Rectangle())
                .accessibilityElement()
                .accessibilityLabel("HUD color lightness")
                .accessibilityValue(HUDColourField.spokenLightness(lightness))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: set(hue, HUDColourField.adjustedLightness(lightness, up: true), true)
                    case .decrement: set(hue, HUDColourField.adjustedLightness(lightness, up: false), true)
                    @unknown default: break
                    }
                }
        }
        .allowsHitTesting(false)
    }
}

/// The block's drag (task 196 for the hue track; task 206 for the block):
/// a UIKit pan, so the scroll view can be told to wait for it. It begins
/// whichever way the finger first moves, and the scroll view's pan waits
/// for it to fail, so a drag that starts in the block moves the colour and
/// never scrolls the page. Each state it reports goes through
/// `HUDColourTouch.handle`, which says what to write.
private struct HUDColourFieldPan: UIGestureRecognizerRepresentable {
    var size: CGSize
    var apply: (HUDColourTouch.Write) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var touch = HUDColourTouch()

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
        let phase: HUDColourTouch.Phase
        switch recognizer.state {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled, .failed: phase = .cancelled
        default: return
        }
        apply(context.coordinator.touch.handle(phase, at: context.converter.localLocation, size: size))
    }
}
