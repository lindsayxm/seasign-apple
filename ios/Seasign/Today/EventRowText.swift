import Foundation

/// One row of Today's events box (design v12, `eventRow()` in
/// `design-ideas/v12-imago/index.html`): a line of mono characters as wide
/// as the box allows (34 on the mockup's screen), written as
///
///     11:00 A ----------- Hanna’s Show /
///      1:00 P - Wearables and sensing d/
///       ALL   ------------ Hanna’s Show /
///       TUE   ------------ Hanna’s Show /
///
/// The head is always eight characters: the time right-aligned in five,
/// a space, `A` or `P` (a space when there is no letter), a space. Then at
/// least one dash, a space, the title, a space and a slash. A title too long
/// for that is cut and ends in the slash with no space before it.
///
/// What VoiceOver says is the plain event (`EventLabel.spoken`), never this.
/// Pure: no font is read here; widths come in through `measure`.
enum EventRowText {
    /// The head: time in five, letter, spaces.
    static let headCount = 8
    /// The fewest columns a row is written in; below this only the head
    /// and a slash would fit.
    static let minimumColumns = headCount + 4

    /// The row for `label` in `columns` characters.
    static func row(_ label: EventLabel, columns: Int) -> String {
        row(time: label.rowTime, letter: label.rowLetter, title: label.title, columns: columns)
    }

    /// The row in `columns` characters (at least `minimumColumns`).
    static func row(time: String, letter: Character?, title: String, columns: Int) -> String {
        row(time: time, letter: letter, title: title, columns: columns, maxWidth: .infinity) { _ in 0 }
    }

    /// The row in `columns` characters, held to `maxWidth` as measured.
    /// Characters outside the mono face (CJK, emoji) are wider than a cell,
    /// so a row of them gives up dashes first (down to one) and only then
    /// cuts the title, still ending in the slash.
    static func row(
        time: String, letter: Character?, title: String, columns: Int,
        maxWidth: CGFloat, measure: (String) -> CGFloat
    ) -> String {
        let columns = max(columns, minimumColumns)
        let head = pad(String(time.prefix(5)), to: 5) + " " + String(letter ?? " ") + " "
        return head + body(Array(plain(title)), room: columns - headCount, maxWidth: maxWidth) { measure(head + $0) }
    }

    /// A message in the row's form, for the zip prompt: dashes, a space,
    /// the text, a space and a slash, right-aligned in `columns`; cut like a
    /// title when it does not fit.
    static func message(_ text: String, columns: Int) -> String {
        message(text, columns: columns, maxWidth: .infinity) { _ in 0 }
    }

    static func message(_ text: String, columns: Int, maxWidth: CGFloat, measure: (String) -> CGFloat) -> String {
        body(Array(plain(text)), room: max(columns, minimumColumns), maxWidth: maxWidth, measure: measure)
    }

    /// The row for `label`, held to `maxWidth` as measured.
    static func row(_ label: EventLabel, columns: Int, maxWidth: CGFloat, measure: (String) -> CGFloat) -> String {
        row(time: label.rowTime, letter: label.rowLetter, title: label.title, columns: columns, maxWidth: maxWidth, measure: measure)
    }

    /// How many characters of `cell` points fit in `width`.
    static func columns(width: CGFloat, cell: CGFloat) -> Int {
        guard cell > 0, width.isFinite, width > 0 else { return minimumColumns }
        // A hair of tolerance for rounding in the measured sizes.
        return max(minimumColumns, Int(((width + 0.01) / cell).rounded(.down)))
    }

    /// The part after the head in `room` characters: whole
    /// (`---- title /`) when the title fits with a dash, otherwise cut
    /// (`- titl/`). `fits` is checked as well: dashes go first, down to
    /// one, then the title is cut a character at a time. A cut never ends in
    /// a space (it would read as a whole title); the room it leaves goes to
    /// the dashes.
    private static func body(_ text: [Character], room: Int, maxWidth: CGFloat, measure: (String) -> CGFloat) -> String {
        func fits(_ candidate: String) -> Bool { maxWidth.isInfinite || measure(candidate) <= maxWidth + 0.5 }
        func dashes(_ count: Int) -> String { String(repeating: "-", count: max(1, count)) }
        // Whole.
        if text.count + 4 <= room {
            for count in stride(from: room - text.count - 3, through: 1, by: -1) {
                let candidate = dashes(count) + " " + String(text) + " /"
                if fits(candidate) { return candidate }
            }
        }
        // Cut, the longest that fits.
        var longest = min(text.count - 1, room - 3)
        if text.count + 4 > room { longest = min(text.count, room - 3) }
        var last = dashes(1) + " /"
        for length in stride(from: max(longest, 0), through: 0, by: -1) {
            var kept = Array(text.prefix(length))
            while kept.last?.isWhitespace == true { kept.removeLast() }
            for count in stride(from: room - 2 - kept.count, through: 1, by: -1) {
                let candidate = dashes(count) + " " + String(kept) + "/"
                last = candidate
                if fits(candidate) { return candidate }
            }
        }
        return last
    }

    /// Runs of white space (tabs, line breaks) as one space, trimmed.
    private static func plain(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func pad(_ text: String, to width: Int) -> String {
        String(repeating: " ", count: max(0, width - text.count)) + text
    }
}
