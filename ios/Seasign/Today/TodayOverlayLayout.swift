import SwiftUI
import UIKit

/// Where every part of Today's fixed overlay sits (design v11, the plan's
/// "Fixed overlay"): the left column, the events box, the hairline, the wind
/// line, the three buttons, the article rows and `∀`. Worked out once from
/// the screen size and the text, so nothing is measured back from the views.
///
/// All figures are the mockup's points (`design-ideas/v11-artemis/`, 393 wide)
/// times `scale`; everything is in screen points from the top-left corner.
///
/// The left column is fixed: the date's letters start level with the first
/// event line's letters and the temperature's sit on the baseline the third
/// line of the mockup's sample ends on. The events box grows and shrinks with
/// the real events, from its fixed top; the hairline runs along its bottom
/// edge, but never less than 16 points under the temperature, and the box is
/// drawn down to the hairline. The wind line and the buttons hang from the
/// hairline.
struct TodayOverlayLayout {
    /// One event in the box.
    struct EventRow: Equatable {
        var label: EventLabel
        /// The title broken into lines, in caps.
        var lines: [String]
        /// The top of the first line box.
        var top: CGFloat
        /// One line box per line.
        var height: CGFloat
    }

    /// The zip prompt, as a row under the events.
    struct PromptRow: Equatable {
        var lines: [String]
        var top: CGFloat
        var height: CGFloat
    }

    /// The mockup's figures, in its points.
    enum Mockup {
        static let left: CGFloat = 34
        static let boxLeft: CGFloat = 96
        static let boxRight: CGFloat = 377
        static let boxTop: CGFloat = 64
        static let boxPadding: CGFloat = 8
        /// Under the last row: its 10-point margin and the box's 2 points.
        static let boxPaddingBottom: CGFloat = 12
        static let rowGap: CGFloat = 10
        static let line: CGFloat = 16
        /// The 1-point rule at the left of each row, and the text after it.
        static let ruleX: CGFloat = 104
        static let textX: CGFloat = 112
        /// The time cell, before the title.
        static let timeCell: CGFloat = 66
        /// The tallest the rows may be together: five lines in three rows
        /// (the mockup's sample is four). Keeps the hairline at or above 184,
        /// so the saved button ends by 311, clear of the top of a sun or
        /// moon low at the right of the path (about 324 at its highest there).
        static let maxRowsHeight: CGFloat = 5 * line + 2 * rowGap
        static let hairlineUnderTemperature: CGFloat = 16
        static let windUnderHairline: CGFloat = 18
        static let buttonTops: [CGFloat] = [18, 63, 108]
        static let buttonX: CGFloat = 331
        static let icon: CGFloat = 19
        static let allBox: CGFloat = 10
        static let allTopFromBottom: CGFloat = 58
        static let rowPitch: CGFloat = 57
        static let titleLine: CGFloat = 17.5
        static let numberColumn: CGFloat = 23
        static let feedWidth: CGFloat = 332
        /// The day name's size is kept within this range (points before
        /// scaling); as wide as the date it would swing from about 15 (MON on
        /// JUL 1) to 38 (FRI on NOV 20). The lead's choice until the user
        /// decides; the stills show about 22.8.
        static let dayNameSizes: ClosedRange<CGFloat> = 20...28
        /// The 1-point drop of the number's line box under the title's.
        static let numberDrop: CGFloat = 1
    }

    /// The type of the overlay at this scale.
    struct Fonts {
        var date: UIFont
        var temperature: UIFont
        var event: UIFont
        var time: UIFont
        var wind: UIFont
        var number: UIFont
        var title: UIFont

        /// The size of the event times in mockup points. The scene's rise
        /// and set times under the horizon use the same size (task 165).
        static let timeSize: CGFloat = 10

        static let dateTracking: CGFloat = 0.26
        static let temperatureTracking: CGFloat = 0.2
        static let eventTracking: CGFloat = 0.13
        static let timeTracking: CGFloat = 0.04
        static let windTracking: CGFloat = 0.14
        static let numberTracking: CGFloat = 0.08
        static let titleTracking: CGFloat = 0.01
        static let dayTracking: CGFloat = 0.03

        init(scale s: CGFloat) {
            date = TodayType.jost(9 * s)
            temperature = TodayType.jost(10 * s)
            event = TodayType.jost(11 * s)
            time = TodayType.mono(Self.timeSize * s)
            wind = TodayType.mono(8.5 * s)
            number = TodayType.mono(8 * s)
            title = TodayType.title(13.5 * s)
        }
    }

    static let zipPromptText = "SET YOUR ZIP CODE IN SETTINGS"

    let size: CGSize
    let scale: CGFloat
    let fonts: Fonts

    // Left column.
    let leftX: CGFloat
    let dateText: String
    let dateBaseline: CGFloat
    let dayText: String
    let dayFont: UIFont
    let dayBaseline: CGFloat
    let temperatureBaseline: CGFloat

    // Events box.
    /// Nil when there is nothing to put in it.
    let box: CGRect?
    let rows: [EventRow]
    let prompt: PromptRow?
    let ruleX: CGFloat
    let timeX: CGFloat
    /// The second time column (`PM`, `ALL`).
    let tailX: CGFloat
    let titleX: CGFloat
    let titleWidth: CGFloat
    /// The baselines inside one 16-point line box.
    let eventBaseline: CGFloat
    let timeBaseline: CGFloat

    // Under the box.
    let hairlineY: CGFloat
    let hairlineX: ClosedRange<CGFloat>
    let windBaseline: CGFloat
    /// Centres of the settings, list and saved icons.
    let buttonCenters: [CGPoint]
    let iconSize: CGFloat

    // The sea.
    let headlinesTop: CGFloat
    /// The lowest the article rows' text may reach: the top of `∀`'s target.
    let headlinesBottom: CGFloat
    /// `∀`'s 10-point box.
    let allRect: CGRect

    /// - Parameters:
    ///   - labels: the next events, at most three, soonest first.
    ///   - showsZipPrompt: no zip is set yet.
    ///   - date: the header's date as shown (`NOV 16`).
    ///   - weekday: the day name (`Mon`), shown in caps.
    init(
        size: CGSize,
        labels: [EventLabel],
        showsZipPrompt: Bool,
        date: String,
        weekday: String
    ) {
        let scene = SceneLayout(size: size)
        let s = scene.scale
        let fonts = Fonts(scale: s)
        self.size = size
        self.scale = s
        self.fonts = fonts
        let line = Mockup.line * s

        // Rows of the events box.
        eventBaseline = TodayType.baseline(in: line, font: fonts.event)
        timeBaseline = TodayType.baseline(in: line, font: fonts.time)
        ruleX = Mockup.ruleX * s
        timeX = Mockup.textX * s
        let textRight = (Mockup.boxRight - Mockup.boxPadding) * s

        // Left column, fixed. The date's letters start where the first
        // event line's do; the temperature's end on the third line's baseline
        // (the mockup's 75.7 and 151.7).
        leftX = Mockup.left * s
        dateText = date.uppercased()
        let firstCapTop = (Mockup.boxTop + Mockup.boxPadding) * s + eventBaseline - fonts.event.capHeight
        dateBaseline = firstCapTop + fonts.date.capHeight
        temperatureBaseline = (Mockup.boxTop + Mockup.boxPadding + 3 * Mockup.line + 2 * Mockup.rowGap) * s + eventBaseline
        // The day name is as wide as the date, and midway between it and
        // the temperature.
        dayText = weekday.uppercased()
        dayFont = Self.dayFont(day: dayText, date: dateText, dateFont: fonts.date, scale: s)
        let temperatureCapTop = temperatureBaseline - fonts.temperature.capHeight
        let gap = (temperatureCapTop - dateBaseline - dayFont.capHeight) / 2
        dayBaseline = dateBaseline + gap + dayFont.capHeight

        // The two time columns, as wide as the widest time shown and never
        // narrower than the mockup's (5.6 characters, then the rest of 66); at
        // least a character between the columns and one and a half before the title.
        let digit = TodayType.width("0", font: fonts.time, tracking: 0)
        // Over the rows shown: at most three, and no event is ever dropped
        // after this (see the cap below).
        let shown = Array(labels.prefix(3))
        let leadWidths = shown.map { TodayType.width($0.timeLead, font: fonts.time, tracking: Fonts.timeTracking) }
        let tailWidths = shown.compactMap { $0.timeTail }.map {
            TodayType.width($0, font: fonts.time, tracking: Fonts.timeTracking)
        }
        let widestLead = leadWidths.max() ?? 0
        let timeEnd: CGFloat
        if let widestTail = tailWidths.max() {
            let leadColumn = max(5.6 * digit, widestLead + digit)
            tailX = timeX + leadColumn
            timeEnd = leadColumn + widestTail
        } else {
            tailX = timeX + widestLead
            timeEnd = widestLead
        }
        titleX = timeX + max(Mockup.timeCell * s, timeEnd + 1.5 * digit)
        let titleSpace = max(0, textRight - titleX)
        titleWidth = titleSpace

        let eventFont = fonts.event
        let measure: (String) -> CGFloat = { TodayType.width($0, font: eventFont, tracking: Fonts.eventTracking) }
        func lines(_ label: EventLabel, maxLines: Int) -> [String] {
            CapsWrapper.wrap(
                label.title.uppercased(), width: titleSpace, maxLines: maxLines, breakingLongWords: true, measure: measure
            )
        }
        var wrapped = shown.map { ($0, lines($0, maxLines: 2)) }
        // One line, so three one-line events and the prompt always fit the
        // cap below (3 + 1 lines and three gaps: 94 of 100 points).
        let promptLines = showsZipPrompt
            ? CapsWrapper.wrap(Self.zipPromptText, width: textRight - timeX, maxLines: 1, breakingLongWords: true, measure: measure)
            : []

        // Never taller than five lines of rows, so the button column hung
        // from the hairline stays clear of a low sun or moon at the right
        // of the path. Over that, the last two-line title is cut to one
        // line, from the last event up. That always fits (three one-line
        // events and the one-line prompt take 94 points), so no event is
        // ever dropped.
        func height(_ lineCounts: [Int]) -> CGFloat {
            let lines = lineCounts.reduce(0, +)
            return CGFloat(lines) * line + CGFloat(max(0, lineCounts.count - 1)) * Mockup.rowGap * s
        }
        let promptCount = promptLines.isEmpty ? [] : [promptLines.count]
        func tooTall() -> Bool {
            height(wrapped.map { max(1, $0.1.count) } + promptCount) > Mockup.maxRowsHeight * s + 0.5
        }
        while tooTall(), let index = wrapped.lastIndex(where: { $0.1.count > 1 }) {
            wrapped[index].1 = lines(wrapped[index].0, maxLines: 1)
        }

        var y = (Mockup.boxTop + Mockup.boxPadding) * s
        var rows: [EventRow] = []
        for (label, lines) in wrapped {
            let rowHeight = CGFloat(max(1, lines.count)) * line
            rows.append(EventRow(label: label, lines: lines, top: y, height: rowHeight))
            y += rowHeight + Mockup.rowGap * s
        }
        self.rows = rows
        if promptLines.isEmpty {
            prompt = nil
        } else {
            let rowHeight = CGFloat(promptLines.count) * line
            prompt = PromptRow(lines: promptLines, top: y, height: rowHeight)
            y += rowHeight + Mockup.rowGap * s
        }

        // The hairline along the box's bottom edge, never less than 16 points
        // under the temperature; the box is drawn down to it.
        let underTemperature = temperatureBaseline + Mockup.hairlineUnderTemperature * s
        let isEmpty = rows.isEmpty && prompt == nil
        let contentBottom = isEmpty ? 0 : y - Mockup.rowGap * s + Mockup.boxPaddingBottom * s
        let hairline = max(contentBottom, underTemperature)
        hairlineY = hairline
        hairlineX = (Mockup.left * s)...(Mockup.boxRight * s)
        box = isEmpty ? nil : CGRect(
            x: Mockup.boxLeft * s,
            y: Mockup.boxTop * s,
            width: (Mockup.boxRight - Mockup.boxLeft) * s,
            height: hairlineY - Mockup.boxTop * s
        )

        // Hung from the hairline: the wind line's letters start level with
        // the top of the settings icon.
        windBaseline = hairlineY + Mockup.windUnderHairline * s + fonts.wind.capHeight
        iconSize = Mockup.icon * s
        buttonCenters = Mockup.buttonTops.map {
            CGPoint(x: Mockup.buttonX * s, y: hairline + ($0 + Mockup.icon / 2) * s)
        }

        // The sea: titles from 100 under the horizon; ∀ centred, its top 58
        // above the bottom of the screen.
        headlinesTop = scene.headlinesTop
        let allSide = Mockup.allBox * s
        allRect = CGRect(
            x: size.width / 2 - allSide / 2,
            y: size.height - Mockup.allTopFromBottom * s,
            width: allSide,
            height: allSide
        )
        headlinesBottom = allRect.midY - 22
    }

    /// The day name's face at the size that makes `day` as wide as `date`
    /// (each without the letter-space after its last letter), kept within
    /// `Mockup.dayNameSizes`.
    static func dayFont(day: String, date: String, dateFont: UIFont, scale: CGFloat) -> UIFont {
        let reference = 28 * scale
        let want = TodayType.width(date, font: dateFont, tracking: Fonts.dateTracking)
        let got = TodayType.width(day, font: TodayType.dayName(reference), tracking: Fonts.dayTracking)
        guard want > 0, got > 0 else { return TodayType.dayName(reference) }
        let size = min(max(reference * want / got, Mockup.dayNameSizes.lowerBound * scale), Mockup.dayNameSizes.upperBound * scale)
        return TodayType.dayName(size)
    }

    // MARK: Pull spinners

    /// The frame of each pull's spinner, in points (not scaled).
    static let spinnerSide: CGFloat = 20

    /// The calendar pull's spinner: in the events box's upper right corner,
    /// inside its padding, level with the first event line. Placed from the
    /// mockup's box, so it has a place even when there is no box.
    var calendarSpinnerCenter: CGPoint {
        CGPoint(
            x: spinnerCenterX,
            y: (Mockup.boxTop + Mockup.boxPadding + Mockup.line / 2) * scale
        )
    }

    /// The headline pull's spinner: at the upper right of the headlines,
    /// level with the first title line, under the calendar one.
    var headlineSpinnerCenter: CGPoint {
        CGPoint(x: spinnerCenterX, y: headlinesTop + titleLineHeight / 2)
    }

    private var spinnerCenterX: CGFloat {
        (Mockup.boxRight - Mockup.boxPadding) * scale - Self.spinnerSide / 2
    }

    // MARK: Article rows

    /// The top of article row `index`.
    func headlineRowTop(_ index: Int) -> CGFloat {
        headlinesTop + CGFloat(index) * Mockup.rowPitch * scale
    }

    var headlinePitch: CGFloat { Mockup.rowPitch * scale }
    var titleLineHeight: CGFloat { Mockup.titleLine * scale }
    var headlineTitleX: CGFloat { (Mockup.left + Mockup.numberColumn) * scale }
    var headlineTitleWidth: CGFloat { (Mockup.feedWidth - Mockup.numberColumn) * scale }
    /// A title line's baseline inside its 17.5-point line box.
    var titleBaseline: CGFloat { TodayType.baseline(in: titleLineHeight, font: fonts.title) }
    /// The number's baseline from the row's top: its line box is 1 point lower.
    var numberBaseline: CGFloat {
        Mockup.numberDrop * scale + TodayType.baseline(in: titleLineHeight, font: fonts.number)
    }
}
