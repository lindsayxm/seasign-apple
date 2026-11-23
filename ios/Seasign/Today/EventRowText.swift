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
        let columns = max(columns, minimumColumns)
        let head = pad(String(time.prefix(5)), to: 5) + " " + String(letter ?? " ") + " "
        let room = columns - headCount
        let title = Array(plain(title))
        // Whole: a dash or more, a space each side of the title, " /".
        if title.count + 4 <= room {
            return head + String(repeating: "-", count: room - title.count - 3) + " " + String(title) + " /"
        }
        // Cut: "- ", as much of the title as fits, "/".
        return head + cut(title, room: room)
    }

    /// `text` cut to `room` characters as "- ", the text, "/". A cut that
    /// would end in a space (so read as a whole title) ends at the word
    /// before it instead, the spare room going to the dashes in front.
    private static func cut(_ text: [Character], room: Int) -> String {
        var kept = Array(text.prefix(room - 3))
        while kept.last?.isWhitespace == true { kept.removeLast() }
        let dashes = room - 2 - kept.count
        return String(repeating: "-", count: dashes) + " " + String(kept) + "/"
    }

    /// A message in the row's form, for the zip prompt: dashes, a space,
    /// the text, a space and a slash, right-aligned in `columns`; cut like a
    /// title when it does not fit.
    static func message(_ text: String, columns: Int) -> String {
        let columns = max(columns, minimumColumns)
        let text = Array(plain(text))
        if text.count + 4 <= columns {
            return String(repeating: "-", count: columns - text.count - 3) + " " + String(text) + " /"
        }
        return cut(text, room: columns)
    }

    /// `row` held to `maxWidth` as measured: characters outside the mono
    /// face (CJK, emoji) are wider than a cell, so a row of them is cut
    /// further, one character at a time, still ending in the slash.
    static func row(_ label: EventLabel, columns: Int, maxWidth: CGFloat, measure: (String) -> CGFloat) -> String {
        fit(row(label, columns: columns), maxWidth: maxWidth, measure: measure)
    }

    static func message(_ text: String, columns: Int, maxWidth: CGFloat, measure: (String) -> CGFloat) -> String {
        fit(message(text, columns: columns), maxWidth: maxWidth, measure: measure)
    }

    /// How many characters of `cell` points fit in `width`.
    static func columns(width: CGFloat, cell: CGFloat) -> Int {
        guard cell > 0, width.isFinite, width > 0 else { return minimumColumns }
        // A hair of tolerance for rounding in the measured sizes.
        return max(minimumColumns, Int(((width + 0.01) / cell).rounded(.down)))
    }

    /// Cuts the text before the final slash, one character at a time,
    /// until the row fits; the slash stays.
    static func fit(_ row: String, maxWidth: CGFloat, measure: (String) -> CGFloat) -> String {
        var characters = Array(row)
        while characters.count > headCount + 2, measure(String(characters)) > maxWidth + 0.5 {
            characters.removeLast(2)
            characters.append("/")
        }
        return String(characters)
    }

    /// Runs of white space (tabs, line breaks) as one space, trimmed.
    private static func plain(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func pad(_ text: String, to width: Int) -> String {
        String(repeating: " ", count: max(0, width - text.count)) + text
    }
}
