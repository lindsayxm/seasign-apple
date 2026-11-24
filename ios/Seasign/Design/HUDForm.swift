import SwiftUI

/// The HUD's look (design v12) for screens that scroll and hold body text and
/// text fields: Settings first (task 195), the other restyled pages after.
///
/// The type is the system monospaced face at text styles, so it follows
/// Dynamic Type; `Text(hud:)` is fixed-size and only for Today's fixed
/// composition. The ground is `Palette.hudPlate`; headers, outlines, filled
/// buttons, chips, switches and the text cursor take the user's accent from
/// the environment (`\.hudAccent`); body text is white, secondary text and
/// hairlines are the grey of before. A problem is white with a leading "!"
/// (`HUDWarning`), never a colour near the accent (task 197).
///
/// Case (task 197): headings, labels and buttons are capitals
/// (`Text(caps:)`); titles, data and sentences people read are mixed case
/// as written (`Text(verbatim:)`).
enum HUDTextRole: CaseIterable {
    /// A full-screen page's title in its header row.
    case title
    /// A section's heading ("Calendars").
    case section
    /// A small label over a field or a group ("Calendar link").
    case label
    /// A row's name (a calendar, a site, the chosen voice).
    case rowName
    /// The line under a row's name (a host, "Main calendar").
    case detail
    /// Explanations, statuses and problems.
    case note
    /// A filled or outlined button's words.
    case button
    /// An underlined text button ("Remove").
    case link
    /// A chip or one side of a two-sided switch.
    case chip
    /// What is typed into a field.
    case field
    /// The large zip code field.
    case display
    /// An article's or list item's title in a list (Saved, History, Do / Get),
    /// and what is typed for a list item.
    case itemTitle

    var textStyle: Font.TextStyle {
        switch self {
        case .title: .subheadline
        case .section: .footnote
        case .label: .caption2
        case .rowName: .footnote
        case .detail: .caption2
        case .note: .caption
        case .button: .footnote
        case .link: .caption
        case .chip: .caption
        case .field: .subheadline
        case .display: .largeTitle
        case .itemTitle: .subheadline
        }
    }

    var weight: Font.Weight {
        switch self {
        case .title, .button: .semibold
        case .section, .rowName, .itemTitle: .medium
        default: .regular
        }
    }

    /// Extra space between letters, in points.
    var tracking: CGFloat {
        switch self {
        case .title: 1.2
        case .section, .button: 0.6
        case .label, .link, .chip, .detail: 0.4
        default: 0
        }
    }

    /// The system mono face at this role's text style: it scales with the
    /// reader's text size.
    var font: Font {
        .system(textStyle, design: .monospaced, weight: weight)
    }
}

extension View {
    /// The HUD's mono type for `role`, following Dynamic Type.
    func hudText(_ role: HUDTextRole) -> some View {
        font(role.font).tracking(role.tracking)
    }

    /// A text field in the HUD's look: mono type, white text and the
    /// accent's cursor.
    func hudField(_ role: HUDTextRole = .field) -> some View {
        modifier(HUDFieldStyle(role: role))
    }
}

private struct HUDFieldStyle: ViewModifier {
    var role: HUDTextRole
    @Environment(\.hudAccent) private var accent

    func body(content: Content) -> some View {
        content
            .font(role.font)
            .foregroundStyle(Palette.white)
            .tint(accent)
    }
}

/// A section's heading in the accent, marked as a heading for VoiceOver.
struct HUDSectionHeader: View {
    var title: String
    var topPadding: CGFloat = 24

    @Environment(\.hudAccent) private var accent

    var body: some View {
        Text(caps: title)
            .hudText(.section)
            .foregroundStyle(accent)
            .padding(.top, topPadding)
            .accessibilityAddTraits(.isHeader)
    }
}

/// An explanation or status in grey, or a problem (`HUDWarning`). Mixed
/// case as written: notes are sentences, not headings (task 197).
struct HUDNote: View {
    var text: String
    var warning = false

    var body: some View {
        if warning {
            HUDWarning(text: text)
        } else {
            Text(verbatim: text)
                .hudText(.note)
                .lineSpacing(3)
                .foregroundStyle(Palette.dimText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The one look of a problem or warning on every HUD screen (task 197):
/// white words after a white "!", so it never reads as the accent at any
/// hue (white is the HUD's second colour). The "!" is hidden from
/// VoiceOver, which reads the words as before. In a row's name
/// (`.rowName`) the words are in capitals like every other row name
/// ("KEY SAVED", task 198); notes stay as written.
struct HUDWarning: View {
    var text: String
    var role: HUDTextRole = .note

    /// The mark before the words.
    static let mark = "!"
    /// The colour of the mark and the words.
    static let colour = SRGB(255, 255, 255)

    /// The words as drawn: capitals in a row's name, as written otherwise.
    static func shown(_ text: String, role: HUDTextRole) -> String {
        role == .rowName ? text.uppercased() : text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: Self.mark)
                .font(.system(role.textStyle, design: .monospaced, weight: .bold))
                .accessibilityHidden(true)
            Text(verbatim: Self.shown(text, role: role))
                .hudText(role)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(verbatim: text))
        }
        .foregroundStyle(Self.colour.color)
        .accessibilityElement(children: .combine)
    }
}

/// A one-point hairline: grey between rows, or the accent under a field.
struct HUDRule: View {
    var accent = false

    @Environment(\.hudAccent) private var hudAccent

    var body: some View {
        Rectangle()
            .fill(accent ? hudAccent : Palette.rule)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// The corner radius and line of the HUD's buttons: the tiles' own.
enum HUDShape {
    static let radius = TodayOverlayLayout.Mockup.tileRadius
    static let line = TodayOverlayLayout.Mockup.tileBorder
    static var rect: RoundedRectangle { RoundedRectangle(cornerRadius: radius) }
}

/// The main action of a form ("Save", "Add calendar"): filled with the
/// accent with dark words, like the page's tile; outlined in grey with grey
/// words while it cannot be used.
struct HUDFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.hudAccent) private var accent

        var body: some View {
            configuration.label
                .hudText(.button)
                .foregroundStyle(isEnabled ? Palette.onAccent : Palette.dimText)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(HUDShape.rect.fill(isEnabled ? accent : Color.clear))
                .overlay(HUDShape.rect.strokeBorder(isEnabled ? accent : Palette.rule, lineWidth: HUDShape.line))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(HUDShape.rect)
        }
    }
}

/// An underlined text button in the accent ("Remove", "Change voice");
/// grey while it cannot be used. At least 44 points tall.
struct HUDLinkButtonStyle: ButtonStyle {
    var minWidth: CGFloat?
    var alignment: Alignment = .leading

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, minWidth: minWidth, alignment: alignment)
    }

    private struct Face: View {
        let configuration: Configuration
        let minWidth: CGFloat?
        let alignment: Alignment
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.hudAccent) private var accent

        var body: some View {
            configuration.label
                .hudText(.link)
                .foregroundStyle(isEnabled ? accent : Palette.dimText)
                .underline()
                .frame(minWidth: minWidth, minHeight: 44, alignment: alignment)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// One choice among several (a provider, a category): filled with the
/// accent when chosen, outlined in it otherwise. The face is 36 points
/// tall; with `touchAlignment` the button's touch area is at least 44 by 44
/// round it, the face placed in it by that alignment (History's save chip,
/// task 198).
struct HUDChipButtonStyle: ButtonStyle {
    var selected: Bool
    var touchAlignment: Alignment?

    /// The smallest touch area, with `touchAlignment`.
    static let minimumTouch: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, selected: selected, touchAlignment: touchAlignment)
    }

    private struct Face: View {
        let configuration: Configuration
        let selected: Bool
        let touchAlignment: Alignment?
        @Environment(\.hudAccent) private var accent

        var body: some View {
            let face = configuration.label
                .hudText(.chip)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? Palette.onAccent : Palette.white)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(HUDShape.rect.fill(selected ? accent : Color.clear))
                .overlay(HUDShape.rect.strokeBorder(accent, lineWidth: HUDShape.line))
                .opacity(configuration.isPressed ? 0.7 : 1)
            if let touchAlignment {
                face
                    .frame(minWidth: HUDChipButtonStyle.minimumTouch, minHeight: HUDChipButtonStyle.minimumTouch, alignment: touchAlignment)
                    .contentShape(Rectangle())
            } else {
                face
                    .contentShape(HUDShape.rect)
            }
        }
    }
}

extension ButtonStyle where Self == HUDFilledButtonStyle {
    static var hudFilled: HUDFilledButtonStyle { HUDFilledButtonStyle() }
}

extension ButtonStyle where Self == HUDLinkButtonStyle {
    static var hudLink: HUDLinkButtonStyle { HUDLinkButtonStyle() }

    static func hudLink(minWidth: CGFloat?, alignment: Alignment = .leading) -> HUDLinkButtonStyle {
        HUDLinkButtonStyle(minWidth: minWidth, alignment: alignment)
    }
}

extension ButtonStyle where Self == HUDChipButtonStyle {
    static func hudChip(selected: Bool) -> HUDChipButtonStyle {
        HUDChipButtonStyle(selected: selected)
    }

    /// A chip whose touch area is at least 44 by 44, the face placed in it
    /// by `touchAlignment`.
    static func hudChip(selected: Bool, touchAlignment: Alignment) -> HUDChipButtonStyle {
        HUDChipButtonStyle(selected: selected, touchAlignment: touchAlignment)
    }
}
