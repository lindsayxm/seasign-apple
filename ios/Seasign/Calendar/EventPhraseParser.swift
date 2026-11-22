import Foundation

// Task 171: one typed (later spoken, task 172) line becomes an event draft,
// on the phone, with no network. Pure: the line, a fixed "now", the events'
// time zone and a calendar in; a draft or a problem out.
//
// Apple's date detector (`NSDataDetector`) takes no reference date: it reads
// relative words against the real now, in the phone's zone, invents times
// (12:00 for a day with no time, 19:00 for "dinner") and its matches swallow
// title words ("lunch tomorrow at noon"). So the parser reads relative days
// (today, tonight, tomorrow, weekday names, next week, in N days), times and
// lengths with its own rules from the given now and zone, and uses the
// detector only for explicit calendar dates ("Dec 3", "3rd of December",
// "12/3/2026"), whose wall-clock day it takes, re-deriving the year from now
// when the line gives none. What the real detector returned on the day this
// was built is in task 171's log.

/// One date the detector found: where, and its wall-clock parts in the zone
/// it read them in.
struct DetectedDate: Equatable, Sendable {
    /// UTF-16 range in the text given to the detector.
    var range: NSRange
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    /// Seconds, when the text gave a span ("3pm to 5pm"); 0 otherwise.
    var duration: TimeInterval
    /// A zone written in the text ("3 pm EST"); nil otherwise.
    var timeZone: TimeZone?
}

/// Finds dates in text. The app uses `SystemDateDetector`; tests give a fake.
protocol EventDateDetecting: Sendable {
    func dates(in text: String) -> [DetectedDate]
}

/// `NSDataDetector` for dates. It reads in the phone's zone against the real
/// now; only the wall-clock parts are passed on, never its `Date`.
struct SystemDateDetector: EventDateDetecting {
    func dates(in text: String) -> [DetectedDate] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let length = (text as NSString).length
        return detector.matches(in: text, range: NSRange(location: 0, length: length)).compactMap { match in
            guard let date = match.date else { return nil }
            let parts = calendar.dateComponents(in: match.timeZone ?? .current, from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
            return DetectedDate(
                range: match.range, year: year, month: month, day: day,
                hour: parts.hour ?? 0, minute: parts.minute ?? 0,
                duration: match.duration, timeZone: match.timeZone
            )
        }
    }
}

/// An event as understood from a line, before it is confirmed.
struct EventDraft: Equatable, Sendable {
    enum Timing: Equatable, Sendable {
        case timed(start: Date, end: Date)
        /// `YYYY-MM-DD` in the draft's zone; the event covers that one day.
        case allDay(date: String)
    }

    var title: String
    var timing: Timing
    /// The events' zone (`EventZone.resolve`): what times were read in.
    var timeZone: TimeZone

    var isAllDay: Bool {
        if case .allDay = timing { return true }
        return false
    }
}

/// Why a line gave no draft. Fixed words: never the line itself.
enum EventDraftProblem: Error, Equatable, Sendable {
    /// Nothing was typed.
    case empty
    /// Everything was date, time or lead-in words: no title is left.
    case noTitle
    /// A time-like word could not be read ("at 25", "pm" on its own).
    case unclearTime
    /// A part of the day with no clock time ("tomorrow night"): which time is not guessed.
    case partOfDay
    /// A day-like word could not be read ("this weekend", "December third").
    case unclearDay
    /// More than one day named ("tomorrow friday").
    case twoDays
    /// A date that does not exist ("Feb 30").
    case noSuchDate
    /// Longer than a day, or not after its start.
    case badLength
    /// More than a year back or five years ahead (the API's limit).
    case outOfRange
    /// A time from now ("in 30 minutes", "in two hours"): not read; a day
    /// and a clock time are asked for instead.
    case relativeTime

    var message: String {
        switch self {
        case .empty:
            "Type what the event is and when, like “Lunch with Ann tomorrow at noon”."
        case .noTitle:
            "What is the event? Add a few words, like “Lunch with Ann tomorrow at noon”."
        case .unclearTime:
            "The time couldn't be read. Write it like “3pm”, “15:30” or “noon”."
        case .partOfDay:
            "Give a time as well as the part of the day, like “tomorrow at 7pm”."
        case .unclearDay:
            "The day couldn't be read. Write it like “Sunday”, “tomorrow” or “Dec 3”."
        case .twoDays:
            "The line names more than one day. Give just one."
        case .noSuchDate:
            "That date doesn't exist. Check the day and month."
        case .badLength:
            "An event can last at most a day, and must end after it starts."
        case .outOfRange:
            "Events can be added from a year ago up to five years ahead."
        case .relativeTime:
            "Give a day and time, like “today at 3pm”, instead of a time from now."
        }
    }
}

enum EventParse: Equatable, Sendable {
    case draft(EventDraft)
    case problem(EventDraftProblem)
}

/// The rules, in order:
///
/// 1. The line is cleaned as titles are (`EventTitle`): control and
///    invisible format characters go, so they cannot hide inside words.
/// 2. A length: "for 2 hours", "for 30 minutes", "for an hour and a half",
///    "for 90 min" (at most a day).
/// 3. One time: "3pm", "3:30 pm", "3.30pm", "15:00", "noon", "midnight",
///    "at 3", "3 o'clock", a span "3 to 5pm", "3-5pm", "from 3 until 4:30pm",
///    and a zone after it ("3pm EST"). A bare hour, or one with a single
///    "a" or "p" glued to it ("3p"), needs "at" before it ("dinner at 8"),
///    or "at" or "from" before a span of them ("from 9a to 5p"); else it is
///    title text ("Room 3", "seat 12a"). With no am or pm: 13-23, 0 and a
///    leading zero are 24-hour; the other end of a span lends its half of
///    the day; "tonight", "evening", "afternoon", "night", "dinner" or
///    "supper" in the line mean pm, "morning" or "breakfast" am; otherwise
///    1-6 is pm and 7-11 am. 12 alone is noon, but midnight with
///    "tonight", "night" or "evening" in the line. "Midnight", "12am" (and
///    "12:30am") are at the midnight at the end of the day named (or of
///    today), so "friday at midnight" and "friday 12am" both start as
///    Friday ends; a 24-hour "00:00" is the start of the day named.
/// 4. One day: "today", "tonight", "tomorrow", "the day after tomorrow",
///    "in 3 days", "in 2 weeks", a weekday ("sunday" is today on a Sunday,
///    else the next one; "next sunday" is the first one after today;
///    "sunday next week" is the one in the following calendar week), "next
///    week" (a week from today), "the 5th" (this month, or next if past),
///    or an explicit date the detector finds ("Dec 3", "12/3/2026"); a date
///    without a year is the next one on or after today.
/// 5. No time: an all-day event. No day: today. A time already past today
///    stays today. No length: one hour.
/// 6. The rest is the title: "to my calendar" and lead-ins at the start
///    ("add", "create", "schedule", "put", "new", "an event called", "a",
///    "an", "please") are dropped, the first letter capitalised, at most 200
///    characters. Names stay title text ("Meeting with Rahaf").
/// 7. Anything left that looks like a time or a day it could not read is a
///    problem, never a guess: a plain number right after the day
///    ("tomorrow 3-4", "friday 9 to 5") and a time from now ("in 30
///    minutes") among them.
struct EventPhraseParser: Sendable {
    var detector: any EventDateDetecting = SystemDateDetector()

    /// Gregorian, weeks starting on Sunday (as in the US), for `calendar`.
    static var defaultCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        return calendar
    }

    func parse(_ line: String, now: Date, timeZone: TimeZone, calendar: Calendar = EventPhraseParser.defaultCalendar) -> EventParse {
        var calendar = calendar
        calendar.timeZone = timeZone
        let text = EventTitle.cleanLine(line)
        guard !text.isEmpty else { return .problem(.empty) }
        var scan = PhraseScan(text: text, detected: detector.dates(in: text))
        do {
            let length = try scan.readLength()
            let time = try scan.readTime()
            let day = try scan.readDay(hasTime: time != nil)
            try scan.checkLeftovers(hasTime: time != nil)
            let title = EventTitle.fromWords(scan.leftoverWords())
            guard !title.isEmpty else { return .problem(.noTitle) }
            let timing = try Self.timing(
                day: day, time: time, length: length, detected: scan.detectedLength(for: time),
                now: now, calendar: calendar
            )
            guard Self.isInRange(timing, now: now) else { return .problem(.outOfRange) }
            return .draft(EventDraft(title: title, timing: timing, timeZone: timeZone))
        } catch let problem as EventDraftProblem {
            return .problem(problem)
        } catch {
            return .problem(.unclearDay)
        }
    }

    // MARK: Building the draft

    private static func timing(
        day: PhraseScan.Day?, time: PhraseScan.Time?, length: TimeInterval?, detected: TimeInterval?,
        now: Date, calendar: Calendar
    ) throws -> EventDraft.Timing {
        let today = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
        guard let year = today.year, let month = today.month, let dayOfMonth = today.day, let weekday = today.weekday,
              let todayStart = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))
        else { throw EventDraftProblem.unclearDay }
        let base: DateComponents
        switch day ?? .offset(0) {
        case .offset(let days):
            base = try shifted(todayStart, days: days, calendar: calendar)
        case .weekday(let target, let mode):
            var days = (target - weekday + 7) % 7
            switch mode {
            case .plain:
                break
            case .next:
                if days == 0 { days = 7 }
            case .nextWeek:
                // The target weekday in the calendar week after this one.
                let intoWeek = (weekday - calendar.firstWeekday + 7) % 7
                let targetIntoWeek = (target - calendar.firstWeekday + 7) % 7
                days = 7 - intoWeek + targetIntoWeek
            }
            base = try shifted(todayStart, days: days, calendar: calendar)
        case .dayOfMonth(let wanted):
            var candidate = (year: year, month: month)
            if wanted < dayOfMonth {
                candidate = month == 12 ? (year + 1, 1) : (year, month + 1)
            }
            guard isReal(year: candidate.year, month: candidate.month, day: wanted, calendar: calendar) else {
                throw EventDraftProblem.noSuchDate
            }
            base = DateComponents(year: candidate.year, month: candidate.month, day: wanted)
        case .explicit(let givenYear, let wantedMonth, let wantedDay, let writtenWeekday):
            let year = givenYear ?? ((wantedMonth, wantedDay) < (month, dayOfMonth) ? year + 1 : year)
            guard isReal(year: year, month: wantedMonth, day: wantedDay, calendar: calendar),
                  let date = calendar.date(from: DateComponents(year: year, month: wantedMonth, day: wantedDay))
            else { throw EventDraftProblem.noSuchDate }
            if let writtenWeekday, calendar.component(.weekday, from: date) != writtenWeekday {
                throw EventDraftProblem.twoDays
            }
            base = DateComponents(year: year, month: wantedMonth, day: wantedDay)
        }
        guard let time else {
            guard length == nil else { throw EventDraftProblem.unclearTime }
            return .allDay(date: String(format: "%04d-%02d-%02d", base.year ?? 0, base.month ?? 0, base.day ?? 0))
        }
        var timeCalendar = calendar
        if let zone = time.zone { timeCalendar.timeZone = zone }
        func wall(_ hour: Int, _ minute: Int, nextDay: Bool) throws -> Date {
            guard let midnight = timeCalendar.date(from: DateComponents(year: base.year, month: base.month, day: base.day)),
                  let day = timeCalendar.date(byAdding: .day, value: nextDay ? 1 : 0, to: midnight),
                  let date = timeCalendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            else { throw EventDraftProblem.unclearTime }
            return date
        }
        let start = try wall(time.start.hour, time.start.minute, nextDay: time.start.isMidnight)
        var end: Date
        if let finish = time.end {
            end = try wall(finish.hour, finish.minute, nextDay: finish.isMidnight)
            if end <= start { end = timeCalendar.date(byAdding: .day, value: 1, to: end) ?? end }
            guard length == nil else { throw EventDraftProblem.unclearTime }
        } else if let length {
            end = start.addingTimeInterval(length)
        } else if let detected, detected > 0 {
            end = start.addingTimeInterval(detected)
        } else {
            end = start.addingTimeInterval(3600)
        }
        let seconds = end.timeIntervalSince(start)
        guard seconds > 0, seconds <= 86_400 else { throw EventDraftProblem.badLength }
        return .timed(start: start, end: end)
    }

    private static func shifted(_ date: Date, days: Int, calendar: Calendar) throws -> DateComponents {
        guard let moved = calendar.date(byAdding: .day, value: days, to: date) else { throw EventDraftProblem.unclearDay }
        return calendar.dateComponents([.year, .month, .day], from: moved)
    }

    private static func isReal(year: Int, month: Int, day: Int, calendar: Calendar) -> Bool {
        guard (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
        else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day
    }

    /// The API's range: from one year before now to five years after, by
    /// the calendar in UTC; an all-day date by its UTC dates.
    static func isInRange(_ timing: EventDraft.Timing, now: Date) -> Bool {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let earliest = utc.date(byAdding: .year, value: -1, to: now),
              let latest = utc.date(byAdding: .year, value: 5, to: now)
        else { return false }
        switch timing {
        case .timed(let start, let end):
            return start >= earliest && end <= latest
        case .allDay(let date):
            func key(_ value: Date) -> String {
                let parts = utc.dateComponents([.year, .month, .day], from: value)
                return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            }
            return date >= key(earliest) && date <= key(latest)
        }
    }
}

// MARK: - The scan

/// The words of one line, which of them have been read as a length, a time
/// or a day, and what they said.
private struct PhraseScan {
    struct Token {
        /// As typed, with its punctuation.
        var raw: String
        /// Lower case, outer punctuation removed.
        var word: String
        var range: NSRange
    }

    enum Meridiem { case am, pm }

    struct Clock {
        var hour: Int
        var minute: Int
        var meridiem: Meridiem?
        var hasColon = false
        var leadingZero = false
        var isNoon = false
        var isMidnight = false
        var oclock = false
        /// The am or pm is a single letter glued to the number ("3p", "12a"),
        /// which is also how rooms, seats and gates are named.
        var singleLetter = false

        /// A plain number with nothing to say what it is ("3", not "3pm", "15:00" or "noon").
        var isBare: Bool {
            meridiem == nil && !hasColon && !isNoon && !isMidnight && !oclock
        }

        /// Read as a time only after "at" (or in a span after "at" or "from").
        var needsLead: Bool {
            isBare || singleLetter
        }

        /// Read as a 24-hour time whatever else the line says.
        var isTwentyFourHour: Bool {
            meridiem == nil && !isNoon && !isMidnight && (hour >= 13 || hour == 0 || leadingZero)
        }
    }

    /// A time resolved to 0-23 hours.
    struct ResolvedClock {
        var hour: Int
        var minute: Int
        var isMidnight: Bool
    }

    struct Time {
        var start: ResolvedClock
        var end: ResolvedClock?
        var zone: TimeZone?
        var tokens: Range<Int>
    }

    enum WeekdayMode { case plain, next, nextWeek }

    enum Day: Equatable {
        case offset(Int)
        case weekday(Int, WeekdayMode)
        case dayOfMonth(Int)
        /// `weekday` (1 is Sunday): one written beside the date ("Friday, Dec 4"), which must match it.
        case explicit(year: Int?, month: Int, day: Int, weekday: Int?)
    }

    var tokens: [Token]
    var used: [Bool]
    let detected: [DetectedDate]
    /// Where the date words were, to read a part of the day after them.
    private var dayTokens: [Int] = []

    init(text: String, detected: [DetectedDate]) {
        tokens = Self.tokenize(text)
        used = Array(repeating: false, count: tokens.count)
        self.detected = detected
    }

    // MARK: Words

    private static let outerPunctuation = CharacterSet(charactersIn: ",.;:!?\"()[]{}“”‘’'")

    private static func tokenize(_ text: String) -> [Token] {
        let ns = text as NSString
        guard let words = try? NSRegularExpression(pattern: "\\S+") else { return [] }
        var result: [Token] = []
        for match in words.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: match.range)
            // "3-5pm" and "3pm-5pm" are a span: three words.
            if let span = spanParts(raw) {
                let left = NSRange(location: match.range.location, length: (span.left as NSString).length)
                let dash = NSRange(location: left.location + left.length, length: 1)
                let right = NSRange(location: dash.location + 1, length: match.range.length - left.length - 1)
                result.append(Token(raw: span.left, word: span.left.lowercased(), range: left))
                result.append(Token(raw: "-", word: "-", range: dash))
                result.append(Token(raw: span.right, word: word(span.right), range: right))
                continue
            }
            result.append(Token(raw: raw, word: word(raw), range: match.range))
        }
        return result
    }

    private static func word(_ raw: String) -> String {
        raw.trimmingCharacters(in: outerPunctuation).lowercased()
    }

    private static let clockPattern = "\\d{1,2}(?:[:.]\\d{2})?(?:[ap]\\.?m?\\.?)?"

    private static func spanParts(_ raw: String) -> (left: String, right: String)? {
        guard let expression = try? NSRegularExpression(
            pattern: "^(\(clockPattern))-(\(clockPattern)[,.;:!?]*)$", options: [.caseInsensitive]
        ) else { return nil }
        let ns = raw as NSString
        guard let match = expression.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)))
    }

    private func word(_ index: Int) -> String? {
        tokens.indices.contains(index) && !used[index] ? tokens[index].word : nil
    }

    private mutating func use(_ range: Range<Int>) {
        for index in range where tokens.indices.contains(index) { used[index] = true }
    }

    private func words(_ index: Int, _ expected: String...) -> Bool {
        for (offset, wanted) in expected.enumerated() where word(index + offset) != wanted { return false }
        return true
    }

    /// The words not read, as typed: pieces of one typed word that were
    /// split ("9-5" into "9", "-", "5") are joined again, so a title keeps
    /// what was typed.
    func leftoverWords() -> [String] {
        var words: [String] = []
        var previous: Int?
        for index in tokens.indices where !used[index] {
            if let previous, previous == index - 1,
               NSMaxRange(tokens[previous].range) == tokens[index].range.location, !words.isEmpty {
                words[words.count - 1] += tokens[index].raw
            } else {
                words.append(tokens[index].raw)
            }
            previous = index
        }
        return words
    }

    // MARK: Numbers

    private static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "forty-five": 45, "ninety": 90,
    ]

    private static func number(_ word: String) -> Double? {
        if let value = numberWords[word] { return value }
        guard word.range(of: "^\\d+(\\.\\d+)?$", options: .regularExpression) != nil else { return nil }
        return Double(word)
    }

    private static let hourUnits: Set<String> = ["h", "hr", "hrs", "hour", "hours"]
    private static let minuteUnits: Set<String> = ["m", "min", "mins", "minute", "minutes"]

    // MARK: Length

    /// "for 2 hours", "for 30 minutes", "for an hour and a half", "for half
    /// an hour", "for 90min", "for 1.5 hrs".
    mutating func readLength() throws -> TimeInterval? {
        var found: TimeInterval?
        var index = 0
        while index < tokens.count {
            guard word(index) == "for", let (seconds, end) = length(after: index + 1) else {
                index += 1
                continue
            }
            if found != nil { throw EventDraftProblem.unclearTime }
            found = seconds
            use(index..<end)
            index = end
        }
        return found
    }

    private func length(after start: Int) -> (TimeInterval, Int)? {
        var index = start
        guard let first = word(index) else { return nil }
        // "half an hour"
        if first == "half", let article = word(index + 1), ["a", "an"].contains(article),
           let unit = word(index + 2), Self.hourUnits.contains(unit) {
            return (1800, index + 3)
        }
        // "90min", "2h", "1.5hrs"
        if let match = first.range(of: "^(\\d+(\\.\\d+)?)(h|hr|hrs|hours?|m|mins?|minutes?)$", options: .regularExpression),
           match.lowerBound == first.startIndex {
            let digits = first.prefix { $0.isNumber || $0 == "." }
            let unit = String(first.dropFirst(digits.count))
            guard let value = Double(digits) else { return nil }
            return (value * (Self.hourUnits.contains(unit) ? 3600 : 60), index + 1)
        }
        guard var value = Self.number(first) else { return nil }
        index += 1
        var half = false
        if words(index, "and", "a", "half") {
            half = true
            index += 3
        }
        guard let unit = word(index) else { return nil }
        let perUnit: Double
        if Self.hourUnits.contains(unit) {
            perUnit = 3600
        } else if Self.minuteUnits.contains(unit) {
            perUnit = 60
        } else {
            return nil
        }
        index += 1
        if !half, perUnit == 3600, words(index, "and", "a", "half") {
            half = true
            index += 3
        }
        if half { value += 0.5 }
        return (value * perUnit, index)
    }

    // MARK: Time

    private static let pmHints: Set<String> = ["tonight", "evening", "afternoon", "night", "dinner", "supper"]
    private static let amHints: Set<String> = ["morning", "breakfast"]
    /// With one of these in the line, 12 alone is midnight, not noon.
    private static let nightHints: Set<String> = ["tonight", "night", "evening"]
    private static let partsOfDay: Set<String> = ["morning", "afternoon", "evening", "night"]
    private static let timeLeads: Set<String> = ["at", "@", "from", "around", "about"]
    private static let spanWords: Set<String> = ["to", "till", "til", "until", "-", "through", "thru"]
    private static let zoneNames: Set<String> = ["EST", "EDT", "CST", "CDT", "MST", "MDT", "PST", "PDT", "AKST", "AKDT", "HST", "UTC", "GMT"]

    private func meridiem(of word: String) -> Meridiem? {
        switch word.replacingOccurrences(of: ".", with: "") {
        case "am": .am
        case "pm": .pm
        default: nil
        }
    }

    /// A clock at `index`: the clock and the index after it.
    private func clock(at index: Int) -> (Clock, Int)? {
        guard let word = self.word(index) else { return nil }
        var next = index + 1
        var clock: Clock
        switch word {
        case "noon", "midday", "12noon":
            clock = Clock(hour: 12, minute: 0, isNoon: true)
        case "midnight", "12midnight":
            clock = Clock(hour: 0, minute: 0, isMidnight: true)
        default:
            let pattern = "^(\\d{1,2})(?:([:.])(\\d{2}))?([ap]\\.?m?\\.?)?$"
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: word, range: NSRange(location: 0, length: (word as NSString).length))
            else { return nil }
            let ns = word as NSString
            let hourText = ns.substring(with: match.range(at: 1))
            guard let hour = Int(hourText) else { return nil }
            let separator = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2))
            let minute = match.range(at: 3).location == NSNotFound ? 0 : Int(ns.substring(with: match.range(at: 3))) ?? 0
            var meridiem = match.range(at: 4).location == NSNotFound ? nil : self.meridiem(of: ns.substring(with: match.range(at: 4)))
            var singleLetter = false
            if match.range(at: 4).location != NSNotFound, meridiem == nil {
                // "3a" or "3p": a single letter.
                meridiem = ns.substring(with: match.range(at: 4)).hasPrefix("a") ? .am : .pm
                singleLetter = true
            }
            // "3.30" is a time only with am or pm after it.
            if separator == ".", meridiem == nil, !(self.word(next).flatMap(self.meridiem(of:)) != nil) { return nil }
            clock = Clock(hour: hour, minute: minute, meridiem: meridiem, hasColon: separator != nil, leadingZero: hourText.count == 2 && hourText.hasPrefix("0"), singleLetter: singleLetter)
            if clock.meridiem == nil, let following = self.word(next), let value = self.meridiem(of: following) {
                clock.meridiem = value
                next += 1
            }
            if clock.meridiem == nil, let following = self.word(next), ["o'clock", "oclock"].contains(following) {
                clock.oclock = true
                next += 1
            }
            guard clock.minute <= 59 else { return nil }
        }
        return (clock, next)
    }

    /// Reads the one time in the line; nil when there is none.
    mutating func readTime() throws -> Time? {
        var found: Time?
        var index = 0
        let line = Set(tokens.map(\.word))
        let pm = !line.isDisjoint(with: Self.pmHints)
        let am = !line.isDisjoint(with: Self.amHints)
        let hint: Meridiem? = pm == am ? nil : (pm ? .pm : .am)
        let night = !line.isDisjoint(with: Self.nightHints)
        while index < tokens.count {
            guard let (time, end) = try time(at: index, hint: hint, night: night) else {
                index += 1
                continue
            }
            if found != nil { throw EventDraftProblem.unclearTime }
            found = time
            use(index..<end)
            index = end
        }
        return found
    }

    private func time(at start: Int, hint: Meridiem?, night: Bool) throws -> (Time, Int)? {
        guard let first = self.word(start) else { return nil }
        var index = start
        let led = Self.timeLeads.contains(first)
        if led { index += 1 }
        guard let (opening, afterOpening) = clock(at: index) else { return nil }
        index = afterOpening
        var closing: Clock?
        if let joiner = word(index), Self.spanWords.contains(joiner), let (value, after) = clock(at: index + 1) {
            closing = value
            index = after
        }
        // A plain number (or one with a single "a" or "p") is a time only
        // after "at" ("dinner at 8", "at 3p"); a span of them only after "at"
        // or "from" ("from 9 to 5"). Otherwise they are title text ("talk
        // about 3 things", "ages 3 to 5", "room 3a", "gate 5p").
        let strong = first == "at" || first == "@"
        if opening.needsLead, closing == nil, !strong { return nil }
        if opening.needsLead, let closing, closing.needsLead, !(strong || first == "from") { return nil }
        if opening.isBare, !(1...23).contains(opening.hour) { throw EventDraftProblem.unclearTime }
        var zone: TimeZone?
        if tokens.indices.contains(index), !used[index] {
            let raw = tokens[index].raw.trimmingCharacters(in: Self.outerPunctuation)
            if Self.zoneNames.contains(raw), let named = TimeZone(abbreviation: raw) {
                zone = named
                index += 1
            }
        }
        // "in the morning", or "morning" right after the time.
        if let part = word(index + 2), words(index, "in", "the"), Self.partsOfDay.contains(part) {
            index += 3
        } else if let part = word(index), Self.partsOfDay.contains(part) {
            index += 1
        }
        let (begin, finish) = try resolve(opening, closing, hint: hint, night: night)
        return (Time(start: begin, end: finish, zone: zone, tokens: start..<index), index)
    }

    private func resolve(_ opening: Clock, _ closing: Clock?, hint: Meridiem?, night: Bool) throws -> (ResolvedClock, ResolvedClock?) {
        func hour(_ clock: Clock, _ meridiem: Meridiem?) throws -> ResolvedClock {
            if clock.isNoon { return ResolvedClock(hour: 12, minute: 0, isMidnight: false) }
            if clock.isMidnight { return ResolvedClock(hour: 0, minute: 0, isMidnight: true) }
            if let meridiem = clock.meridiem ?? (clock.isTwentyFourHour ? nil : meridiem) {
                guard (1...12).contains(clock.hour) else { throw EventDraftProblem.unclearTime }
                // "12am", "12:30am": as "midnight", at the end of the day named.
                if clock.hour == 12, meridiem == .am {
                    return ResolvedClock(hour: 0, minute: clock.minute, isMidnight: true)
                }
                let base = clock.hour % 12
                return ResolvedClock(hour: meridiem == .pm ? base + 12 : base, minute: clock.minute, isMidnight: false)
            }
            guard (0...23).contains(clock.hour) else { throw EventDraftProblem.unclearTime }
            return ResolvedClock(hour: clock.hour, minute: clock.minute, isMidnight: false)
        }
        func plain(_ clock: Clock) -> Meridiem? {
            if clock.meridiem != nil || clock.isTwentyFourHour || clock.isNoon || clock.isMidnight { return nil }
            // 12 alone is noon; "at 12 tonight" is the midnight that ends tonight.
            if clock.hour == 12 { return night ? .am : .pm }
            if let hint { return hint }
            switch clock.hour {
            case 12, 1...6: return .pm
            default: return .am
            }
        }
        guard let closing else { return (try hour(opening, plain(opening)), nil) }
        // The start takes the end's half of the day unless that puts it
        // after the end ("11 to 1pm" is 11 am).
        var startMeridiem = plain(opening)
        if opening.meridiem == nil, !opening.isTwentyFourHour, !opening.isNoon, !opening.isMidnight,
           let endMeridiem = closing.meridiem {
            let startHour = opening.hour % 12
            let endHour = closing.hour % 12
            startMeridiem = endMeridiem == .pm && startHour > endHour ? .am : endMeridiem
        }
        let begin = try hour(opening, startMeridiem)
        // The end takes whichever half of the day puts it after the start.
        var endMeridiem: Meridiem?
        if closing.meridiem == nil, !closing.isTwentyFourHour, !closing.isNoon, !closing.isMidnight {
            let sameHalf: Meridiem = begin.hour >= 12 ? .pm : .am
            let tried = try hour(closing, sameHalf)
            endMeridiem = (tried.hour, tried.minute) > (begin.hour, begin.minute) ? sameHalf : (sameHalf == .am ? .pm : .am)
        }
        return (begin, try hour(closing, endMeridiem))
    }

    /// The detector's span when it read one over the time's words.
    func detectedLength(for time: Time?) -> TimeInterval? {
        guard let time else { return nil }
        let start = tokens[time.tokens.lowerBound].range.location
        let end = NSMaxRange(tokens[time.tokens.upperBound - 1].range)
        return detected.first { $0.duration > 0 && NSIntersectionRange($0.range, NSRange(location: start, length: end - start)).length > 0 }?.duration
    }

    // MARK: Day

    private static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "tues": 3, "wednesday": 4, "weds": 4,
        "thursday": 5, "thurs": 5, "thur": 5, "friday": 6, "saturday": 7,
    ]
    /// Short names that are also ordinary words ("sat", "sun", "wed"): a
    /// weekday only after "on", "this" or "next".
    private static let shortWeekdays: [String: Int] = [
        "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7,
    ]
    static let months: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4,
        "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9, "october": 10, "oct": 10, "november": 11, "nov": 11,
        "december": 12, "dec": 12,
    ]

    private static func dayNumber(_ word: String) -> Int? {
        guard word.range(of: "^\\d{1,2}(st|nd|rd|th)?$", options: .regularExpression) != nil else { return nil }
        return Int(word.prefix { $0.isNumber })
    }

    private static func isNumericDate(_ word: String) -> Bool {
        word.range(of: "^(\\d{1,2}/\\d{1,2}(/\\d{2}(\\d{2})?)?|\\d{4}-\\d{2}-\\d{2})$", options: .regularExpression) != nil
    }

    /// Reads the one day in the line; nil when there is none (today).
    mutating func readDay(hasTime: Bool) throws -> Day? {
        var found: [Day] = []
        try readExplicitDates(into: &found)
        var index = 0
        while index < tokens.count {
            guard let (day, range) = day(at: index) else {
                index += 1
                continue
            }
            found.append(day)
            use(range)
            dayTokens.append(range.upperBound - 1)
            index = range.upperBound
        }
        // "tomorrow morning": with a time, it only says which half of the day.
        for last in dayTokens {
            guard let part = word(last + 1), Self.partsOfDay.contains(part) else { continue }
            guard hasTime else { throw EventDraftProblem.partOfDay }
            use((last + 1)..<(last + 2))
        }
        var distinct: [Day] = []
        for day in found where !distinct.contains(day) { distinct.append(day) }
        // "Friday, Dec 4": the weekday only confirms the date.
        if distinct.count == 2, case .explicit(let year, let month, let day, nil) = distinct[0],
           case .weekday(let weekday, .plain) = distinct[1] {
            distinct = [.explicit(year: year, month: month, day: day, weekday: weekday)]
        }
        if distinct.count > 1 { throw EventDraftProblem.twoDays }
        return distinct.first
    }

    /// Explicit dates where the detector found one: its day and month, the
    /// year only when the line wrote one.
    private mutating func readExplicitDates(into found: inout [Day]) throws {
        for date in detected {
            let inside = tokens.indices.filter {
                !used[$0] && NSIntersectionRange(tokens[$0].range, date.range).length > 0
            }
            if let numeric = inside.first(where: { Self.isNumericDate(tokens[$0].word) }) {
                let text = tokens[numeric].word
                let parts = text.split(whereSeparator: { $0 == "/" || $0 == "-" }).compactMap { Int($0) }
                let iso = text.contains("-")
                let written = iso ? (parts[1], parts[2]) : (parts[0], parts[1])
                // Month first or day first, as the phone's region writes it.
                guard (date.month, date.day) == written || (!iso && (date.day, date.month) == written) else {
                    throw EventDraftProblem.noSuchDate
                }
                let hasYear = iso || parts.count == 3
                found.append(.explicit(year: hasYear ? date.year : nil, month: date.month, day: date.day, weekday: nil))
                var range = numeric..<(numeric + 1)
                if numeric > 0, word(numeric - 1) == "on" { range = (numeric - 1)..<range.upperBound }
                use(range)
                dayTokens.append(numeric)
                continue
            }
            guard let monthIndex = inside.first(where: { Self.months[tokens[$0].word] != nil }),
                  let month = Self.months[tokens[monthIndex].word]
            else { continue }
            // The day: right after the month ("Dec 3"), or before it ("3 Dec", "3rd of December").
            var dayIndex: Int?
            if let after = word(monthIndex + 1), Self.dayNumber(after) != nil {
                dayIndex = monthIndex + 1
            } else if monthIndex >= 1, let before = word(monthIndex - 1), Self.dayNumber(before) != nil {
                dayIndex = monthIndex - 1
            } else if monthIndex >= 2, word(monthIndex - 1) == "of", let before = word(monthIndex - 2), Self.dayNumber(before) != nil {
                dayIndex = monthIndex - 2
            }
            guard let dayIndex, let day = Self.dayNumber(tokens[dayIndex].word) else { continue }
            // "Feb 30": the detector moves it to March 2.
            guard date.month == month, date.day == day else { throw EventDraftProblem.noSuchDate }
            var first = min(monthIndex, dayIndex)
            var last = max(monthIndex, dayIndex)
            if first >= 1, word(first - 1) == "the" { first -= 1 }
            if first >= 1, word(first - 1) == "on" { first -= 1 }
            var year: Int?
            if let next = word(last + 1), next.range(of: "^\\d{4}$", options: .regularExpression) != nil {
                year = date.year
                last += 1
            }
            found.append(.explicit(year: year, month: month, day: day, weekday: nil))
            use(first..<(last + 1))
            dayTokens.append(last)
        }
    }

    private func day(at index: Int) -> (Day, Range<Int>)? {
        guard let word = self.word(index) else { return nil }
        let before = index >= 1 ? self.word(index - 1) : nil
        switch word {
        case "today", "tonight":
            return (.offset(0), withOn(index))
        case "tomorrow", "tmrw", "tmr", "tomorrow's":
            return (.offset(1), withOn(index))
        case "day":
            // "the day after tomorrow"
            guard words(index, "day", "after", "tomorrow") else { return nil }
            let first = before == "the" ? index - 1 : index
            return (.offset(2), withOn(first, through: index + 2))
        case "in":
            // "in 3 days", "in 2 weeks", "in a week"
            guard let amount = self.word(index + 1), let value = Self.number(amount), value == value.rounded(),
                  let unit = self.word(index + 2) else { return nil }
            switch unit {
            case "day", "days": return (.offset(Int(value)), index..<(index + 3))
            case "week", "weeks": return (.offset(7 * Int(value)), index..<(index + 3))
            default: return nil
            }
        case "next":
            if words(index, "next", "week") {
                // "next week friday" / "next week on friday"
                var target = index + 2
                if self.word(target) == "on" { target += 1 }
                if let name = self.word(target), let weekday = Self.weekdays[name] ?? Self.shortWeekdays[name] {
                    return (.weekday(weekday, .nextWeek), index..<(target + 1))
                }
                return (.offset(7), withOn(index, through: index + 1))
            }
            return nil
        case "the":
            // "the 5th" (not "the 5th of December", read with the explicit dates)
            guard let number = self.word(index + 1), number.range(of: "^\\d{1,2}(st|nd|rd|th)$", options: .regularExpression) != nil,
                  let value = Self.dayNumber(number) else { return nil }
            return (.dayOfMonth(value), withOn(index, through: index + 1))
        default:
            break
        }
        let modifier = before.flatMap { ["this", "next", "on", "coming"].contains($0) ? $0 : nil }
        guard let weekday = Self.weekdays[word] ?? (modifier != nil ? Self.shortWeekdays[word] : nil) else { return nil }
        var first = index
        var mode = WeekdayMode.plain
        if let modifier {
            first = index - 1
            if modifier == "next" { mode = .next }
            if modifier == "coming", index >= 2, self.word(index - 2) == "this" { first = index - 2 }
            if modifier != "on", first >= 1, self.word(first - 1) == "on" { first -= 1 }
        }
        var last = index
        if words(index + 1, "next", "week") {
            mode = .nextWeek
            last = index + 2
        }
        return (.weekday(weekday, mode), first..<(last + 1))
    }

    /// `first...through`, with an "on" or "for" just before it.
    private func withOn(_ first: Int, through last: Int? = nil) -> Range<Int> {
        let start = first >= 1 && ["on", "for"].contains(word(first - 1) ?? "") ? first - 1 : first
        return start..<((last ?? first) + 1)
    }

    // MARK: What is left

    private static let timeWords: Set<String> = ["am", "pm", "a.m", "p.m", "noon", "midnight", "o'clock", "oclock"]
    private static let dayWords: Set<String> = ["weekend", "yesterday", "fortnight"]
    private static let ordinalWords: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
        "eighteenth", "nineteenth", "twentieth", "thirtieth",
    ]

    /// "3", "15", "5p", "12a": an hour with nothing (or a single letter) to
    /// say which half of the day.
    private static func isPlainHour(_ word: String) -> Bool {
        guard word.range(of: "^\\d{1,2}([ap]\\.?)?$", options: .regularExpression) != nil,
              let hour = Int(word.prefix { $0.isNumber })
        else { return false }
        return (0...23).contains(hour)
    }

    /// "30 minutes", "an hour", "half an hour", "30min", "two hours", "a
    /// few minutes", "a couple of hours" from `start`.
    private func isAmountOfTime(after start: Int) -> Bool {
        if length(after: start) != nil { return true }
        var index = start
        if word(index) == "a" { index += 1 }
        guard let amount = word(index), ["few", "couple"].contains(amount) else { return false }
        index += 1
        if word(index) == "of" { index += 1 }
        guard let unit = word(index) else { return false }
        return Self.hourUnits.contains(unit) || Self.minuteUnits.contains(unit)
    }

    /// A time or day word that was not read is a problem, not title text.
    func checkLeftovers(hasTime: Bool) throws {
        for index in tokens.indices where !used[index] {
            let word = tokens[index].word
            if Self.timeWords.contains(word) { throw EventDraftProblem.unclearTime }
            // "at 25", "at 3:75"
            if word == "at" || word == "@", let next = self.word(index + 1),
               next.range(of: "^\\d{1,2}([:.]\\d{1,2})?$", options: .regularExpression) != nil {
                throw EventDraftProblem.unclearTime
            }
            // "in 30 minutes", "in an hour", "15 minutes from now": a time from now.
            if word == "in", isAmountOfTime(after: index + 1) { throw EventDraftProblem.relativeTime }
            if word == "from", self.word(index + 1) == "now" { throw EventDraftProblem.relativeTime }
            // "tomorrow 3-4", "friday 9 to 5", "tomorrow 9": a plain number
            // right after the day reads as a time, but its half of the day is
            // not said.
            if dayTokens.contains(index - 1), Self.isPlainHour(word) { throw EventDraftProblem.unclearTime }
            if Self.dayWords.contains(word) { throw EventDraftProblem.unclearDay }
            if word == "next", let next = self.word(index + 1), ["week", "month", "year"].contains(next) {
                throw EventDraftProblem.unclearDay
            }
            // "December third", "on the 3rd of Dec" the detector did not read.
            if Self.months[word] != nil, word.count > 3 || word == "dec" || word == "jan" || word == "feb" {
                let neighbours = [self.word(index - 1), self.word(index + 1)].compactMap { $0 }
                if neighbours.contains(where: { Self.dayNumber($0) != nil || Self.ordinalWords.contains($0) }) {
                    throw EventDraftProblem.unclearDay
                }
            }
            if Self.isNumericDate(word) { throw EventDraftProblem.unclearDay }
            // "Dec 3-5", "friday to sunday": an event of several days is not made.
            if Self.spanWords.contains(word), dayTokens.contains(index - 1), let next = self.word(index + 1),
               Self.dayNumber(next) != nil || Self.weekdays[next] != nil || Self.months[next] != nil {
                throw EventDraftProblem.unclearDay
            }
        }
    }
}

// MARK: - Titles

/// The API's title rule (task 176), applied before sending so a pasted or
/// dictated line never meets the API's fixed 400: control characters, line
/// and paragraph separators become spaces; invisible format characters are
/// dropped, except a zero-width joiner or non-joiner between two characters
/// and the tags of a subdivision flag; white space is collapsed; at most 200
/// UTF-16 units (JavaScript's length), cut between characters; and there
/// must be a visible character.
enum EventTitle {
    static let maxLength = 200

    /// Lead-ins dropped from the start, and phrases dropped anywhere.
    private static let leadIns: Set<String> = ["please", "add", "create", "schedule", "put", "new", "a", "an"]
    private static let eventWords: Set<String> = ["event"]
    private static let namingWords: Set<String> = ["called", "named", "titled"]
    private static let calendarPhrases: [[String]] = [
        ["to", "my", "calendar"], ["on", "my", "calendar"], ["in", "my", "calendar"],
        ["to", "the", "calendar"], ["on", "the", "calendar"], ["in", "the", "calendar"],
        ["to", "calendar"], ["on", "calendar"],
    ]
    /// Left dangling at the end once the date words are gone.
    private static let danglers: Set<String> = ["at", "on", "from", "for", "this", "next", "the", "in", "and", "by", "to"]

    /// The title from the words the parser did not read.
    static func fromWords(_ raw: [String]) -> String {
        var words = raw
        func key(_ word: String) -> String {
            word.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"()")).lowercased()
        }
        // "to my calendar", anywhere.
        var index = 0
        while index < words.count {
            if let phrase = calendarPhrases.first(where: { phrase in
                index + phrase.count <= words.count && zip(phrase, words[index...]).allSatisfy { $0 == key($1) }
            }) {
                words.removeSubrange(index..<(index + phrase.count))
            } else {
                index += 1
            }
        }
        // Lead-ins at the start: "add a", "please create an event called".
        while let first = words.first {
            let word = key(first)
            if leadIns.contains(word) || (words.count > 1 && word == "set" && key(words[1]) == "up") {
                words.removeFirst(word == "set" ? 2 : 1)
            } else if eventWords.contains(word), words.count > 1, namingWords.contains(key(words[1])) {
                words.removeFirst(2)
            } else if eventWords.contains(word), words.count > 1, words.count < raw.count {
                // "add an event dentist": the word "event" after a lead-in.
                words.removeFirst()
            } else if namingWords.contains(word) {
                words.removeFirst()
            } else {
                break
            }
        }
        while let last = words.last, danglers.contains(key(last)) || key(last) == "please" { words.removeLast() }
        var title = clean(words.joined(separator: " "))
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ",;:-–—").union(.whitespaces))
        if let first = title.first, first.isLowercase {
            title = first.uppercased() + title.dropFirst()
        }
        return clean(title)
    }

    /// The line before it is read: the same characters dropped as for a
    /// title, curly apostrophes and dashes made plain, white space collapsed.
    static func cleanLine(_ line: String) -> String {
        let plain = line
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        return collapse(strip(plain))
    }

    /// A title the API takes, or "" when nothing visible is left.
    static func clean(_ text: String) -> String {
        var title = collapse(strip(text))
        if title.utf16.count > maxLength {
            var cut = ""
            for character in title {
                if cut.utf16.count + String(character).utf16.count > maxLength { break }
                cut.append(character)
            }
            // A cut can leave a joiner or white space at the end: clean again.
            title = collapse(strip(cut))
        }
        return hasVisible(title) ? title : ""
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.unicodeScalars.allSatisfy(\.properties.isWhitespace) })
            .joined(separator: " ")
    }

    /// Control characters, U+2028 and U+2029 become spaces (so words do not
    /// fuse); format characters go, except a joiner between two characters
    /// and a subdivision flag's tags.
    private static func strip(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var kept = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            // A subdivision flag: U+1F3F4, 1 to 6 tag digits or letters, U+E007F.
            if scalar.value == 0x1F3F4 {
                var end = index + 1
                while end < scalars.count, end - index <= 6, isFlagTag(scalars[end]) { end += 1 }
                if end > index + 1, end < scalars.count, scalars[end].value == 0xE007F {
                    kept.append(contentsOf: scalars[index...end])
                    index = end + 1
                    continue
                }
            }
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                kept.append(" ")
            case .format:
                if scalar.value == 0x200C || scalar.value == 0x200D,
                   index > 0, index + 1 < scalars.count,
                   isText(scalars[index - 1]), isText(scalars[index + 1]) {
                    kept.append(scalar)
                }
            case .surrogate:
                break
            default:
                kept.append(scalar)
            }
            index += 1
        }
        return String(kept)
    }

    private static func isFlagTag(_ scalar: Unicode.Scalar) -> Bool {
        (0xE0030...0xE0039).contains(scalar.value) || (0xE0061...0xE007A).contains(scalar.value)
    }

    /// Neither a control, format or surrogate character nor white space.
    private static func isText(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return false
        default:
            return !scalar.properties.isWhitespace
        }
    }

    /// A letter, number, punctuation, symbol or private-use character that
    /// is not default-ignorable or U+2800 BRAILLE PATTERN BLANK.
    static func hasVisible(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            guard !scalar.properties.isDefaultIgnorableCodePoint, scalar.value != 0x2800 else { return false }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber,
                 .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol, .privateUse:
                return true
            default:
                return false
            }
        }
    }
}
