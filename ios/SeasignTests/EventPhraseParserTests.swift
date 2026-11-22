import Foundation
import Testing

@testable import Seasign

// Task 171: the line typed after + (and later spoken) becomes a draft, on the
// phone. Every test uses a fixed "now" and zone; the date detector is a fake
// except in the wiring tests, which run Apple's detector on explicit dates
// whose meaning does not depend on today's date.

/// Stands in for `NSDataDetector`: each listed piece of text, where it
/// appears in the line, reads as the given day (at noon, as the real one
/// reads a date with no time). Matching ignores case.
struct FakeDateDetector: EventDateDetecting {
    var dates: [(text: String, year: Int, month: Int, day: Int)] = []

    func dates(in text: String) -> [DetectedDate] {
        dates.compactMap { entry in
            let range = (text as NSString).range(of: entry.text, options: .caseInsensitive)
            guard range.location != NSNotFound else { return nil }
            return DetectedDate(range: range, year: entry.year, month: entry.month, day: entry.day, hour: 12, minute: 0, duration: 0, timeZone: nil)
        }
    }
}

/// What a line should give: a timed event (local wall times in Chicago,
/// "2026-11-22 15:00"), an all-day date, or a problem.
enum Expected: CustomStringConvertible {
    case timed(String, String, String)
    case allDay(String, String)
    case problem(EventDraftProblem)

    var description: String {
        switch self {
        case .timed(let title, let start, let end): "\(title) \(start)–\(end)"
        case .allDay(let title, let date): "\(title) all day \(date)"
        case .problem(let problem): "problem \(problem)"
        }
    }
}

@Suite struct EventPhraseParserTests {
    static let chicago = TimeZone(identifier: "America/Chicago")!
    /// Sunday 22 November 2026, 1:30 PM in Chicago.
    static let now = instant("2026-11-22T19:30:00Z")

    /// The detector's readings of the explicit dates in the table, as the
    /// real one gives them (see the wiring tests below and task 171's log).
    static let detector = FakeDateDetector(dates: [
        ("December 3, 2026", 2026, 12, 3), ("Dec 3rd", 2026, 12, 3), ("3rd of December", 2026, 12, 3),
        ("12/3/2026", 2026, 12, 3), ("march 3", 2027, 3, 3), ("Dec 24", 2026, 12, 24), ("Dec 4", 2026, 12, 4),
        // "Feb 30" is moved to March 2 by the real detector.
        ("Feb 30", 2027, 3, 2), ("Dec 3-5", 2026, 12, 3), ("2026-11-25", 2026, 11, 25), ("Jan 5 2033", 2033, 1, 5), ("Nov 1 2025", 2025, 11, 1),
    ])

    static func wall(_ text: String, in zone: TimeZone = chicago) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    static func parse(_ line: String, now: Date = now, zone: TimeZone = chicago) -> EventParse {
        EventPhraseParser(detector: detector).parse(line, now: now, timeZone: zone)
    }

    /// The table compares title, timing and zone; whether a start was put
    /// on the day after the one named is checked on its own
    /// (`startsAfterTheDayNamedIsMarked`).
    static func check(_ line: String, _ expected: Expected, now: Date = now, zone: TimeZone = chicago) {
        var result = parse(line, now: now, zone: zone)
        if case .draft(var draft) = result {
            draft.startsAfterDayNamed = false
            result = .draft(draft)
        }
        switch expected {
        case .timed(let title, let start, let end):
            #expect(result == .draft(EventDraft(
                title: title, timing: .timed(start: wall(start, in: zone), end: wall(end, in: zone)), timeZone: zone
            )), "\(line) → \(expected)")
        case .allDay(let title, let date):
            #expect(result == .draft(EventDraft(title: title, timing: .allDay(date: date), timeZone: zone)), "\(line) → \(expected)")
        case .problem(let problem):
            #expect(result == .problem(problem), "\(line) → \(expected)")
        }
    }

    // MARK: The table

    static let table: [(String, Expected)] = [
        // The user's own example: Sunday is today, so 3 pm today.
        ("add a meeting to my calendar sunday at 3pm with Rahaf", .timed("Meeting with Rahaf", "2026-11-22 15:00", "2026-11-22 16:00")),
        // Today and tomorrow.
        ("lunch with Ann today at 2pm", .timed("Lunch with Ann", "2026-11-22 14:00", "2026-11-22 15:00")),
        ("lunch with Ann tomorrow at noon", .timed("Lunch with Ann", "2026-11-23 12:00", "2026-11-23 13:00")),
        ("dinner tomorrow", .allDay("Dinner", "2026-11-23")),
        ("the day after tomorrow lunch", .allDay("Lunch", "2026-11-24")),
        ("yoga tonight at 7", .timed("Yoga", "2026-11-22 19:00", "2026-11-22 20:00")),
        // Weekday names: the next one, today included; "next" is the first after today.
        ("dentist friday at 9am", .timed("Dentist", "2026-11-27 09:00", "2026-11-27 10:00")),
        ("dentist on tuesday", .allDay("Dentist", "2026-11-24")),
        ("dentist next friday", .allDay("Dentist", "2026-11-27")),
        ("call Sam next sunday at 10am", .timed("Call Sam", "2026-11-29 10:00", "2026-11-29 11:00")),
        ("this coming saturday brunch at 11", .timed("Brunch", "2026-11-28 11:00", "2026-11-28 12:00")),
        ("meeting at 10 a.m. friday", .timed("Meeting", "2026-11-27 10:00", "2026-11-27 11:00")),
        ("party on sat", .allDay("Party", "2026-11-28")),
        // Next week: a week from today, or the weekday in the next calendar week (Sunday first).
        ("party next week", .allDay("Party", "2026-11-29")),
        ("friday next week lunch", .allDay("Lunch", "2026-12-04")),
        ("next week on wednesday team review at 4pm", .timed("Team review", "2026-12-02 16:00", "2026-12-02 17:00")),
        ("in 3 days dinner with Ann", .allDay("Dinner with Ann", "2026-11-25")),
        ("in 2 weeks review", .allDay("Review", "2026-12-06")),
        // No time: all-day. No date: today.
        ("Farmers market saturday", .allDay("Farmers market", "2026-11-28")),
        ("call mom at 5pm", .timed("Call mom", "2026-11-22 17:00", "2026-11-22 18:00")),
        // A past time today stays today.
        ("call at 9am", .timed("Call", "2026-11-22 09:00", "2026-11-22 10:00")),
        // 24-hour phrasing, noon and midnight.
        ("call mom at 15:00", .timed("Call mom", "2026-11-22 15:00", "2026-11-22 16:00")),
        ("standup tomorrow 09:30", .timed("Standup", "2026-11-23 09:30", "2026-11-23 10:30")),
        ("review at 18:45 friday", .timed("Review", "2026-11-27 18:45", "2026-11-27 19:45")),
        ("doctor at noon", .timed("Doctor", "2026-11-22 12:00", "2026-11-22 13:00")),
        ("flight at midnight", .timed("Flight", "2026-11-23 00:00", "2026-11-23 01:00")),
        ("flight friday at midnight", .timed("Flight", "2026-11-28 00:00", "2026-11-28 01:00")),
        // Bare hours: after "at" only; tonight, evening, dinner mean pm; morning am; else 1-6 pm, 7-11 am.
        ("dinner at 8", .timed("Dinner", "2026-11-22 20:00", "2026-11-22 21:00")),
        ("meeting sunday at 3", .timed("Meeting", "2026-11-22 15:00", "2026-11-22 16:00")),
        ("coffee at 8", .timed("Coffee", "2026-11-22 08:00", "2026-11-22 09:00")),
        ("call at 9 tomorrow morning", .timed("Call", "2026-11-23 09:00", "2026-11-23 10:00")),
        ("Room 3 meeting at 4", .timed("Room 3 meeting", "2026-11-22 16:00", "2026-11-22 17:00")),
        ("dinner for 2 at 7", .timed("Dinner for 2", "2026-11-22 19:00", "2026-11-22 20:00")),
        ("lunch 3.30pm", .timed("Lunch", "2026-11-22 15:30", "2026-11-22 16:30")),
        ("meeting at 2:30", .timed("Meeting", "2026-11-22 14:30", "2026-11-22 15:30")),
        // Lengths and spans.
        ("meeting at 3pm for 2 hours", .timed("Meeting", "2026-11-22 15:00", "2026-11-22 17:00")),
        ("standup at 9:30am for 30 minutes", .timed("Standup", "2026-11-22 09:30", "2026-11-22 10:00")),
        ("workshop tomorrow at 1pm for an hour and a half", .timed("Workshop", "2026-11-23 13:00", "2026-11-23 14:30")),
        ("call at 4 for half an hour", .timed("Call", "2026-11-22 16:00", "2026-11-22 16:30")),
        ("meeting 3pm to 5pm", .timed("Meeting", "2026-11-22 15:00", "2026-11-22 17:00")),
        ("meeting from 3 to 5pm tomorrow", .timed("Meeting", "2026-11-23 15:00", "2026-11-23 17:00")),
        ("party 3-5pm", .timed("Party", "2026-11-22 15:00", "2026-11-22 17:00")),
        ("shift from 9 to 5", .timed("Shift", "2026-11-22 09:00", "2026-11-22 17:00")),
        ("at 9 to 5 shift", .timed("Shift", "2026-11-22 09:00", "2026-11-22 17:00")),
        // Plain numbers without "at" (or a span without "at" or "from") are title text.
        ("shift 9 to 5", .allDay("Shift 9 to 5", "2026-11-22")),
        ("kids ages 3 to 5 party saturday", .allDay("Kids ages 3 to 5 party", "2026-11-28")),
        ("talk about 3 things tomorrow", .allDay("Talk about 3 things", "2026-11-23")),
        ("flowers from 2 friends", .allDay("Flowers from 2 friends", "2026-11-22")),
        ("meeting around 3pm", .timed("Meeting", "2026-11-22 15:00", "2026-11-22 16:00")),
        ("brunch 11 to 1pm", .timed("Brunch", "2026-11-22 11:00", "2026-11-22 13:00")),
        ("party 10pm to 1am", .timed("Party", "2026-11-22 22:00", "2026-11-23 01:00")),
        ("meeting monday 3pm until 4:30pm", .timed("Meeting", "2026-11-23 15:00", "2026-11-23 16:30")),
        // Explicit dates through the detector; no year means the next one.
        ("December 3, 2026 at 4pm review", .timed("Review", "2026-12-03 16:00", "2026-12-03 17:00")),
        ("Dec 3rd party", .allDay("Party", "2026-12-03")),
        ("the 3rd of December party", .allDay("Party", "2026-12-03")),
        ("12/3/2026 dentist", .allDay("Dentist", "2026-12-03")),
        ("march 3 haircut", .allDay("Haircut", "2027-03-03")),
        ("dinner on Dec 24", .allDay("Dinner", "2026-12-24")),
        ("Friday, Dec 4 dinner at 7", .timed("Dinner", "2026-12-04 19:00", "2026-12-04 20:00")),
        ("party on 2026-11-25", .allDay("Party", "2026-11-25")),
        ("party on the 5th", .allDay("Party", "2026-12-05")),
        ("rent due the 30th", .allDay("Rent due", "2026-11-30")),
        // Titles.
        ("please add an event called Dentist tomorrow", .allDay("Dentist", "2026-11-23")),
        ("schedule a call with Rahaf on my calendar at 4pm", .timed("Call with Rahaf", "2026-11-22 16:00", "2026-11-22 17:00")),
        ("put Game night tomorrow on the calendar", .allDay("Game night", "2026-11-23")),
        ("create a new appointment with Dr. Lee friday at 2", .timed("Appointment with Dr. Lee", "2026-11-27 14:00", "2026-11-27 15:00")),
        // Problems, never guesses.
        ("", .problem(.empty)),
        ("   ", .problem(.empty)),
        ("tomorrow at 3pm", .problem(.noTitle)),
        ("add to my calendar friday", .problem(.noTitle)),
        ("this weekend hike", .problem(.unclearDay)),
        ("dinner tomorrow night", .problem(.partOfDay)),
        ("run sunday morning", .problem(.partOfDay)),
        ("meeting at 25", .problem(.unclearTime)),
        ("meeting at 3 pm or 4 pm", .problem(.unclearTime)),
        ("call at pm", .problem(.unclearTime)),
        ("hike tomorrow for 3 hours", .problem(.unclearTime)),
        ("lunch tomorrow friday", .problem(.twoDays)),
        ("Thursday, Dec 4 dinner", .problem(.twoDays)),
        ("dentist on Feb 30", .problem(.noSuchDate)),
        ("December third party", .problem(.unclearDay)),
        ("team offsite Dec 3-5", .problem(.unclearDay)),
        ("trip friday to sunday", .problem(.twoDays)),
        ("party next month", .problem(.unclearDay)),
        ("retreat at 9am for 30 hours", .problem(.badLength)),
        ("reunion Jan 5 2033", .problem(.outOfRange)),
        ("reunion Nov 1 2025", .problem(.outOfRange)),
        // Review fixes (second pass).
        // (3) A single a or p glued to a number is a time only as a bare number is.
        ("meeting in room 3a", .allDay("Meeting in room 3a", "2026-11-22")),
        ("seat 12a flight tomorrow", .allDay("Seat 12a flight", "2026-11-23")),
        ("gate 5p", .allDay("Gate 5p", "2026-11-22")),
        ("party 3-5p", .allDay("Party 3-5p", "2026-11-22")),
        ("call at 3p", .timed("Call", "2026-11-22 15:00", "2026-11-22 16:00")),
        ("nap at 3a", .timed("Nap", "2026-11-22 03:00", "2026-11-22 04:00")),
        ("from 9a to 5p shift", .timed("Shift", "2026-11-22 09:00", "2026-11-22 17:00")),
        ("call mom 3 pm", .timed("Call mom", "2026-11-22 15:00", "2026-11-22 16:00")),
        ("lunch 3p.m. tomorrow", .timed("Lunch", "2026-11-23 15:00", "2026-11-23 16:00")),
        ("call 3pm friday", .timed("Call", "2026-11-27 15:00", "2026-11-27 16:00")),
        // (5) 12 with tonight, night or evening is midnight at the end of that
        // day; 12am and midnight agree (the end of the day named); 12 alone is noon.
        ("party at 12 tonight", .timed("Party", "2026-11-23 00:00", "2026-11-23 01:00")),
        ("show at 12 friday night", .timed("Show", "2026-11-28 00:00", "2026-11-28 01:00")),
        ("flight at 12am", .timed("Flight", "2026-11-23 00:00", "2026-11-23 01:00")),
        // Lead's ruling in task 172 (b): "12am" or "12:30am" with a day named
        // is the start of that day, as "00:30 friday" is (it was the end
        // before); with no day it is still the night at the end of today.
        ("flight friday 12am", .timed("Flight", "2026-11-27 00:00", "2026-11-27 01:00")),
        ("flight friday at 12:30am", .timed("Flight", "2026-11-27 00:30", "2026-11-27 01:30")),
        ("flight 00:30 friday", .timed("Flight", "2026-11-27 00:30", "2026-11-27 01:30")),
        ("flight on Dec 4 at 12:15am", .timed("Flight", "2026-12-04 00:15", "2026-12-04 01:15")),
        ("flight tomorrow at 12am", .timed("Flight", "2026-11-23 00:00", "2026-11-23 01:00")),
        ("flight at 12:30am", .timed("Flight", "2026-11-23 00:30", "2026-11-23 01:30")),
        ("party friday 10pm to 12am", .timed("Party", "2026-11-27 22:00", "2026-11-28 00:00")),
        ("party at 12am tonight", .timed("Party", "2026-11-23 00:00", "2026-11-23 01:00")),
        ("party 10pm to 12am", .timed("Party", "2026-11-22 22:00", "2026-11-23 00:00")),
        ("lunch at 12", .timed("Lunch", "2026-11-22 12:00", "2026-11-22 13:00")),
        ("breakfast at 12", .timed("Breakfast", "2026-11-22 12:00", "2026-11-22 13:00")),
        ("tea at 12 in the afternoon", .timed("Tea", "2026-11-22 12:00", "2026-11-22 13:00")),
        ("lunch at 12pm friday", .timed("Lunch", "2026-11-27 12:00", "2026-11-27 13:00")),
        // (6) A time from now is a problem, not an all-day event today.
        ("call mom in 30 minutes", .problem(.relativeTime)),
        ("nap in two hours", .problem(.relativeTime)),
        ("call back in 30min", .problem(.relativeTime)),
        ("call in an hour", .problem(.relativeTime)),
        ("break in half an hour", .problem(.relativeTime)),
        ("tea in 1 hr", .problem(.relativeTime)),
        ("standup 15 minutes from now", .problem(.relativeTime)),
        ("call back in a few minutes", .problem(.relativeTime)),
        // (7) Titles keep what was typed; a plain number right after the day is a problem.
        ("9-5 shift", .allDay("9-5 shift", "2026-11-22")),
        ("meeting tomorrow 3-4", .problem(.unclearTime)),
        ("shift friday 9 to 5", .problem(.unclearTime)),
        ("standup tomorrow 9", .problem(.unclearTime)),
        ("flight tomorrow 5p", .problem(.unclearTime)),
        // Task 172 (d): with a clock time in the line, a number after the day
        // and "in an hour" are title text.
        ("lunch tuesday 4 guests at 1pm", .timed("Lunch 4 guests", "2026-11-24 13:00", "2026-11-24 14:00")),
        ("book club friday 7 at 7pm", .timed("Book club 7", "2026-11-27 19:00", "2026-11-27 20:00")),
        ("check in an hour early tomorrow at 9am", .timed("Check in an hour early", "2026-11-23 09:00", "2026-11-23 10:00")),
        // Task 172: numbers in words, as speech transcripts give them. Same
        // rules as digits; anything not read is a problem, never a guess.
        // ("call three pm" was a problem before task 172.)
        ("call three pm", .timed("Call", "2026-11-22 15:00", "2026-11-22 16:00")),
        ("meeting with Rahaf tomorrow at three pm", .timed("Meeting with Rahaf", "2026-11-23 15:00", "2026-11-23 16:00")),
        ("lunch friday at twelve thirty pm", .timed("Lunch", "2026-11-27 12:30", "2026-11-27 13:30")),
        ("meeting three thirty pm friday", .timed("Meeting", "2026-11-27 15:30", "2026-11-27 16:30")),
        ("meeting at three thirty", .timed("Meeting", "2026-11-22 15:30", "2026-11-22 16:30")),
        ("call at three oh five pm", .timed("Call", "2026-11-22 15:05", "2026-11-22 16:05")),
        ("call at three forty five pm", .timed("Call", "2026-11-22 15:45", "2026-11-22 16:45")),
        ("call at three o'clock", .timed("Call", "2026-11-22 15:00", "2026-11-22 16:00")),
        ("yoga tomorrow at seven in the morning", .timed("Yoga", "2026-11-23 07:00", "2026-11-23 08:00")),
        ("dinner at eight", .timed("Dinner", "2026-11-22 20:00", "2026-11-22 21:00")),
        ("lunch at twelve noon", .timed("Lunch", "2026-11-22 12:00", "2026-11-22 13:00")),
        ("tea half past three tomorrow", .timed("Tea", "2026-11-23 15:30", "2026-11-23 16:30")),
        ("call at quarter past ten am", .timed("Call", "2026-11-22 10:15", "2026-11-22 11:15")),
        ("meeting quarter to four friday", .timed("Meeting", "2026-11-27 15:45", "2026-11-27 16:45")),
        ("meeting at a quarter to four", .timed("Meeting", "2026-11-22 15:45", "2026-11-22 16:45")),
        ("lunch quarter to one", .timed("Lunch", "2026-11-22 12:45", "2026-11-22 13:45")),
        ("shift from nine to five", .timed("Shift", "2026-11-22 09:00", "2026-11-22 17:00")),
        ("meeting from three to four thirty pm", .timed("Meeting", "2026-11-22 15:00", "2026-11-22 16:30")),
        ("meeting tomorrow at three pm for two hours", .timed("Meeting", "2026-11-23 15:00", "2026-11-23 17:00")),
        ("meeting at three pm for ninety minutes", .timed("Meeting", "2026-11-22 15:00", "2026-11-22 16:30")),
        ("standup at nine am for fifteen minutes", .timed("Standup", "2026-11-22 09:00", "2026-11-22 09:15")),
        ("call at four pm for forty five minutes", .timed("Call", "2026-11-22 16:00", "2026-11-22 16:45")),
        ("workshop at one pm for two and a half hours", .timed("Workshop", "2026-11-22 13:00", "2026-11-22 15:30")),
        // Minutes past and to the hour, as speech says them (task 172
        // review): never a silent wrong time.
        ("meeting at ten past three", .timed("Meeting", "2026-11-22 15:10", "2026-11-22 16:10")),
        ("meeting at ten to four", .timed("Meeting", "2026-11-22 15:50", "2026-11-22 16:50")),
        ("meeting at five to nine", .timed("Meeting", "2026-11-22 08:55", "2026-11-22 09:55")),
        ("call at twenty to four", .timed("Call", "2026-11-22 15:40", "2026-11-22 16:40")),
        ("call at twenty five past four pm", .timed("Call", "2026-11-22 16:25", "2026-11-22 17:25")),
        ("standup at ten to nine am", .timed("Standup", "2026-11-22 08:50", "2026-11-22 09:50")),
        ("tea ten after three tomorrow", .timed("Tea", "2026-11-23 15:10", "2026-11-23 16:10")),
        ("meeting ten minutes past three friday", .timed("Meeting", "2026-11-27 15:10", "2026-11-27 16:10")),
        ("lunch ten to one", .allDay("Lunch ten to one", "2026-11-22")),
        ("lunch at ten to one", .timed("Lunch", "2026-11-22 12:50", "2026-11-22 13:50")),
        ("call at 10 past 3", .timed("Call", "2026-11-22 15:10", "2026-11-22 16:10")),
        ("call at 5 past 9 am", .timed("Call", "2026-11-22 09:05", "2026-11-22 10:05")),
        // "from ... to" stays a span; "N to H" with no "at" stays title text,
        // as "ages 3 to 5" does.
        ("shift from ten to four", .timed("Shift", "2026-11-22 10:00", "2026-11-22 16:00")),
        ("kids ages five to ten party saturday", .allDay("Kids ages five to ten party", "2026-11-28")),
        ("lunch at twelve to one", .timed("Lunch", "2026-11-22 12:00", "2026-11-22 13:00")),
        // Typed "at 5 to 9" could be either: a problem.
        ("dinner at 5 to 9", .problem(.unclearTime)),
        ("meeting at 10 to 4", .problem(.unclearTime)),
        ("meeting at 10 to 4pm", .timed("Meeting", "2026-11-22 10:00", "2026-11-22 16:00")),
        ("meeting at ten past thirteen", .problem(.unclearTime)),
        ("meeting ten past fifteen", .problem(.unclearTime)),
        ("meeting at 3 past 4 past 5", .problem(.unclearTime)),
        // The day of a date is not minutes, and in digits only "past" is.
        ("party Dec 4 after 5 pm", .timed("Party after", "2026-12-04 17:00", "2026-12-04 18:00")),
        ("party Dec 4 after 5", .allDay("Party after 5", "2026-12-04")),
        ("party Dec 4 past 5", .problem(.unclearTime)),
        ("room 4 after 5pm", .timed("Room 4 after", "2026-11-22 17:00", "2026-11-22 18:00")),
        // Two numbers in words are a time only after "at" or with am or pm.
        ("room four twelve meeting tomorrow", .allDay("Room four twelve meeting", "2026-11-23")),
        ("meeting around three thirty", .allDay("Meeting around three thirty", "2026-11-22")),
        ("dentist friday three thirty", .problem(.unclearTime)),
        // Words that are not times stay title text.
        ("one on one with Sam friday at 2pm", .timed("One on one with Sam", "2026-11-27 14:00", "2026-11-27 15:00")),
        ("dinner for two at seven", .timed("Dinner for two", "2026-11-22 19:00", "2026-11-22 20:00")),
        ("kids ages three to five party saturday", .allDay("Kids ages three to five party", "2026-11-28")),
        ("quarter finals saturday", .allDay("Quarter finals", "2026-11-28")),
        // Problems.
        ("meeting tomorrow three", .problem(.unclearTime)),
        ("meeting at twenty five", .problem(.unclearTime)),
        ("meeting at thirteen pm", .problem(.unclearTime)),
        ("meeting quarter to thirteen", .problem(.unclearTime)),
        ("call in ninety minutes", .problem(.relativeTime)),
        ("party on the third of December", .problem(.unclearDay)),
        ("party on the twenty third of December", .problem(.unclearDay)),
        ("party December twenty third", .problem(.unclearDay)),
        ("party on the third", .problem(.unclearDay)),
    ]

    @Test(arguments: table.indices)
    func readsTheTable(_ index: Int) {
        let (line, expected) = Self.table[index]
        Self.check(line, expected)
    }

    /// Task 172 (b): a start put on the day after the one named is marked,
    /// so the popup and the spoken sentence can say so; a start at the
    /// beginning of the day named is not.
    @Test(arguments: [
        ("flight friday at midnight", true), ("flight at midnight", true), ("party at 12 tonight", true),
        ("show at 12 friday night", true), ("flight at 12am", true), ("flight at 12:30am", true),
        ("party at 12am tonight", true),
        ("flight friday 12am", false), ("flight friday at 12:30am", false), ("flight 00:30 friday", false),
        ("flight at 9am", false), ("party friday 10pm to 12am", false), ("dinner tomorrow", false),
    ])
    func startsAfterTheDayNamedIsMarked(_ line: String, _ marked: Bool) {
        guard case .draft(let draft) = Self.parse(line) else {
            Issue.record("\(line): expected a draft")
            return
        }
        #expect(draft.startsAfterDayNamed == marked, "\(line)")
    }

    // MARK: The events' zone

    @Test func timesAreReadInTheEventsZoneNotThePhones() {
        // The same instant is Monday 23 November, 4:30 AM in Tokyo.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        Self.check("lunch tomorrow at noon", .timed("Lunch", "2026-11-24 12:00", "2026-11-24 13:00"), zone: tokyo)
        Self.check("call sunday", .allDay("Call", "2026-11-29"), zone: tokyo)
        Self.check("call monday at 3pm", .timed("Call", "2026-11-23 15:00", "2026-11-23 16:00"), zone: tokyo)
    }

    @Test func aZoneWrittenAfterTheTimeIsUsedForThatTime() {
        // 3 pm in New York is 2 pm in Chicago; the event stays in the events' zone.
        Self.check("meeting at 3pm EST", .timed("Meeting", "2026-11-22 14:00", "2026-11-22 15:00"))
    }

    @Test func aSpanFromTheDetectorSetsTheLengthWhenTheLineGivesNone() {
        var detector = FakeDateDetector()
        let line = "call at 2pm"
        detector.dates = []
        let base = EventPhraseParser(detector: detector).parse(line, now: Self.now, timeZone: Self.chicago)
        #expect(base == .draft(EventDraft(title: "Call", timing: .timed(start: Self.wall("2026-11-22 14:00"), end: Self.wall("2026-11-22 15:00")), timeZone: Self.chicago)))
        struct Spanning: EventDateDetecting {
            func dates(in text: String) -> [DetectedDate] {
                [DetectedDate(range: (text as NSString).range(of: "2pm"), year: 2026, month: 11, day: 22, hour: 14, minute: 0, duration: 5400, timeZone: nil)]
            }
        }
        let spanned = EventPhraseParser(detector: Spanning()).parse(line, now: Self.now, timeZone: Self.chicago)
        #expect(spanned == .draft(EventDraft(title: "Call", timing: .timed(start: Self.wall("2026-11-22 14:00"), end: Self.wall("2026-11-22 15:30")), timeZone: Self.chicago)))
    }

    @Test func relativeWordsIgnoreWhatTheDetectorSaysAboutThem() {
        // The real detector reads "sunday" on a Sunday as next week, invents
        // 19:00 for "dinner" and swallows the word into its match.
        struct Wrong: EventDateDetecting {
            func dates(in text: String) -> [DetectedDate] {
                [DetectedDate(range: NSRange(location: 0, length: (text as NSString).length), year: 2026, month: 11, day: 29, hour: 19, minute: 0, duration: 0, timeZone: nil)]
            }
        }
        let parser = EventPhraseParser(detector: Wrong())
        #expect(parser.parse("dinner sunday", now: Self.now, timeZone: Self.chicago)
            == .draft(EventDraft(title: "Dinner", timing: .allDay(date: "2026-11-22"), timeZone: Self.chicago)))
    }

    @Test func theRangeIsOneYearBackToFiveYearsAheadAsTheAPIs() {
        let now = Self.now
        let yearAgo = instant("2025-11-22T19:30:00Z")
        let fiveYears = instant("2031-11-22T19:30:00Z")
        #expect(EventPhraseParser.isInRange(.timed(start: yearAgo, end: yearAgo.addingTimeInterval(3600)), now: now))
        #expect(!EventPhraseParser.isInRange(.timed(start: yearAgo.addingTimeInterval(-60), end: yearAgo.addingTimeInterval(3600)), now: now))
        #expect(EventPhraseParser.isInRange(.timed(start: fiveYears.addingTimeInterval(-3600), end: fiveYears), now: now))
        #expect(!EventPhraseParser.isInRange(.timed(start: fiveYears, end: fiveYears.addingTimeInterval(60)), now: now))
        #expect(EventPhraseParser.isInRange(.allDay(date: "2025-11-22"), now: now))
        #expect(!EventPhraseParser.isInRange(.allDay(date: "2025-11-21"), now: now))
        #expect(EventPhraseParser.isInRange(.allDay(date: "2031-11-22"), now: now))
        #expect(!EventPhraseParser.isInRange(.allDay(date: "2031-11-23"), now: now))
    }

    // MARK: The real detector

    /// Apple's detector on explicit dates with a year: their meaning does
    /// not depend on the day the test runs, so this proves the wiring.
    @Test(arguments: [
        ("review December 3, 2026 at 4pm", Expected.timed("Review", "2026-12-03 16:00", "2026-12-03 17:00")),
        ("dentist 12/3/2026", .allDay("Dentist", "2026-12-03")),
        ("party Dec 24, 2026", .allDay("Party", "2026-12-24")),
        ("launch on 2026-12-03 at 9:30am", .timed("Launch", "2026-12-03 09:30", "2026-12-03 10:30")),
        ("the 3rd of December 2026 party", .allDay("Party", "2026-12-03")),
    ])
    func theRealDetectorReadsExplicitDates(_ line: String, _ expected: Expected) {
        let result = EventPhraseParser().parse(line, now: Self.now, timeZone: Self.chicago)
        switch expected {
        case .timed(let title, let start, let end):
            #expect(result == .draft(EventDraft(title: title, timing: .timed(start: Self.wall(start), end: Self.wall(end)), timeZone: Self.chicago)), "\(line)")
        case .allDay(let title, let date):
            #expect(result == .draft(EventDraft(title: title, timing: .allDay(date: date), timeZone: Self.chicago)), "\(line)")
        case .problem(let problem):
            #expect(result == .problem(problem), "\(line)")
        }
    }

    @Test func theRealDetectorsImpossibleDateIsAProblem() {
        #expect(EventPhraseParser().parse("dentist Feb 30, 2027", now: Self.now, timeZone: Self.chicago) == .problem(.noSuchDate))
    }

    @Test func theRealDetectorsZoneAndSpanAreItsOwnWallClock() {
        let found = SystemDateDetector().dates(in: "review December 3, 2026 from 3pm to 5pm")
        #expect(found.count == 1)
        #expect(found.first.map { [$0.year, $0.month, $0.day, $0.hour, $0.minute] } == [2026, 12, 3, 15, 0])
        #expect(found.first?.duration == 7200)
    }
}

// MARK: - Titles

@Suite struct EventTitleTests {
    /// The API's title rule (task 176, `isTitle` in the route), restated
    /// here independently of `EventTitle`.
    static func apiAccepts(_ title: String) -> Bool {
        guard title == title.trimmingCharacters(in: .whitespacesAndNewlines), (1...200).contains(title.utf16.count) else { return false }
        let scalars = Array(title.unicodeScalars)
        var visible = false
        for (index, scalar) in scalars.enumerated() {
            let category = scalar.properties.generalCategory
            if [.control, .lineSeparator, .paragraphSeparator, .surrogate].contains(category) { return false }
            if category == .format {
                let joiner = scalar.value == 0x200C || scalar.value == 0x200D
                func text(_ other: Unicode.Scalar) -> Bool {
                    ![.control, .format, .surrogate, .spaceSeparator, .lineSeparator, .paragraphSeparator].contains(other.properties.generalCategory)
                        && !other.properties.isWhitespace
                }
                let between = index > 0 && index + 1 < scalars.count && text(scalars[index - 1]) && text(scalars[index + 1])
                let tag = (0xE0020...0xE007F).contains(scalar.value) && scalars[..<index].contains { $0.value == 0x1F3F4 }
                if !(joiner && between) && !tag { return false }
            }
            if !scalar.properties.isDefaultIgnorableCodePoint, scalar.value != 0x2800,
               [.uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber,
                .letterNumber, .otherNumber, .otherPunctuation, .dashPunctuation, .otherSymbol, .mathSymbol,
                .currencySymbol, .modifierSymbol, .privateUse, .openPunctuation, .closePunctuation].contains(category) {
                visible = true
            }
        }
        return visible
    }

    /// The API's refused titles (task 176's cases) and what cleaning makes of them.
    @Test(arguments: [
        ("Meeting\nwith Rahaf", "Meeting with Rahaf"),
        ("Meeting\u{85}with Rahaf", "Meeting with Rahaf"),
        ("Meeting\u{2028}with Rahaf", "Meeting with Rahaf"),
        ("Meeting\u{2029}with Rahaf", "Meeting with Rahaf"),
        ("\u{200B}", ""),
        ("\u{200B}\u{200D}\u{200C}\u{2060}", ""),
        ("Meet\u{200B}ing", "Meeting"),
        ("\u{200D}", ""),
        ("\u{200D}Meeting", "Meeting"),
        ("Meeting \u{200D} with Rahaf", "Meeting with Rahaf"),
        ("\u{1F468}\u{200D}\u{200D}\u{1F469}", "\u{1F468}\u{1F469}"),
        ("Meeting \u{202E}fahar\u{202C}", "Meeting fahar"),
        ("Meeting \u{2067}Rahaf\u{2069}", "Meeting Rahaf"),
        ("Meeting\u{200E} with Rahaf", "Meeting with Rahaf"),
        ("Meet\u{AD}ing", "Meeting"),
        ("Meet\u{FEFF}ing", "Meeting"),
        ("Meeting\u{E0069}\u{E0067}\u{E006E}\u{E006F}\u{E0072}\u{E0065}", "Meeting"),
        ("Match \u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}", "Match"),
        ("\u{3164}", ""),
        ("\u{2800}\u{2800}", ""),
        ("\u{301}", ""),
        ("\u{FE0F}", ""),
        ("  Lunch \t with   Ann  ", "Lunch with Ann"),
    ])
    func cleansWhatTheAPIRefuses(_ raw: String, _ cleaned: String) {
        let title = EventTitle.clean(raw)
        #expect(title == cleaned)
        if !title.isEmpty { #expect(Self.apiAccepts(title)) }
    }

    /// The API's accepted titles stay as they are.
    @Test(arguments: [
        "Réunion avec Rahaf à 15 h", "اجتماع مع رهف", "פגישה עם רהף", "می\u{200C}خواهم با رهف", "क्\u{200D}ष बैठक",
        "与拉哈夫开会", "ラハフと会議", "라하프와 회의",
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466} dinner", "\u{1F1FA}\u{1F1F8} Independence Day",
        "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F} match", "\u{2764}\u{FE0F}\u{200D}\u{1F525}",
        "\u{1F44D}\u{1F3FD} lunch", "1\u{FE0F}\u{20E3} on 1", "\u{1F382}", "\u{F8FF} Store",
    ])
    func keepsWhatTheAPIAccepts(_ title: String) {
        #expect(EventTitle.clean(title) == title)
        #expect(Self.apiAccepts(title))
    }

    @Test func cutsAt200UTF16UnitsBetweenCharacters() {
        #expect(EventTitle.clean(String(repeating: "y", count: 250)) == String(repeating: "y", count: 200))
        // Each emoji is two UTF-16 units: 100 fit, never half of one.
        let emoji = EventTitle.clean(String(repeating: "\u{1F382}", count: 150))
        #expect(emoji.utf16.count == 200 && emoji.count == 100)
        // A family emoji is one character of 11 units: it is left out whole.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let cut = EventTitle.clean(String(repeating: "y", count: 195) + family)
        #expect(cut == String(repeating: "y", count: 195))
        // White space at the cut is trimmed.
        let spaced = EventTitle.clean(String(repeating: "y", count: 199) + " and more")
        #expect(spaced == String(repeating: "y", count: 199))
        #expect(Self.apiAccepts(spaced))
    }

    @Test func aLineWithHiddenCharactersGivesATitleTheAPITakes() {
        let result = EventPhraseParser(detector: FakeDateDetector()).parse(
            "lunch\u{200B} with\u{2028}Ann\u{202E} tomorrow at noon", now: EventPhraseParserTests.now, timeZone: EventPhraseParserTests.chicago
        )
        guard case .draft(let draft) = result else {
            Issue.record("expected a draft, got \(result)")
            return
        }
        #expect(draft.title == "Lunch with Ann")
        #expect(Self.apiAccepts(draft.title))
    }

    @Test func aLongLineIsCutTo200() {
        let line = String(repeating: "word ", count: 60) + "tomorrow"
        let result = EventPhraseParser(detector: FakeDateDetector()).parse(line, now: EventPhraseParserTests.now, timeZone: EventPhraseParserTests.chicago)
        guard case .draft(let draft) = result else {
            Issue.record("expected a draft, got \(result)")
            return
        }
        #expect(draft.title.utf16.count <= 200)
        #expect(Self.apiAccepts(draft.title))
    }
}

// MARK: - What is sent

@Suite struct GoogleNewEventTests {
    @Test func idsAre32LowercaseHexAndNewEachTime() {
        let first = GoogleNewEvent.makeID()
        #expect(first.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil)
        #expect(first != GoogleNewEvent.makeID())
    }

    @Test func timesAreSentToTheSecondInUTC() {
        #expect(GoogleNewEvent.rfc3339(instant("2026-11-22T21:00:00Z")) == "2026-11-22T21:00:00Z")
        #expect(GoogleNewEvent.rfc3339(instant("2026-11-22T21:00:00Z").addingTimeInterval(0.75)) == "2026-11-22T21:00:00Z")
    }

    @Test func aZoneWithoutAnIANANameIsSentAsUTC() {
        #expect(GoogleNewEvent.zoneName(TimeZone(identifier: "America/Chicago")!) == "America/Chicago")
        #expect(GoogleNewEvent.zoneName(TimeZone(secondsFromGMT: -5 * 3600)!) == "UTC")
        #expect(GoogleNewEvent.zoneName(TimeZone(identifier: "GMT")!) == "UTC")
    }
}
