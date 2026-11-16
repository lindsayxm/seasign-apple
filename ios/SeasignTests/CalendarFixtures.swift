import Foundation
import HTTPTypes
import OpenAPIRuntime

@testable import Seasign

/// A `POST /v1/calendar/events` response as the API sends it for three links
/// asked at 18:05 EST on Sunday 15 November 2026 in `America/New_York`: the
/// first calendar was read in full, the second only partly, and the third did
/// not return a calendar. It holds a timed event today, an all-day event
/// today, a timed event tomorrow and one without a length or a title.
let calendarJSONThreeLinks = """
{
  "events": [
    { "calendar": 1, "title": "Farmers' market", "start": "2026-11-15T05:00:00Z", "end": "2026-11-16T05:00:00Z", "allDay": true, "date": "2026-11-15" },
    { "calendar": 0, "title": "Hanna's show", "start": "2026-11-16T01:25:00Z", "end": "2026-11-16T03:00:00Z", "allDay": false },
    { "calendar": 0, "title": "Dentist", "start": "2026-11-16T14:00:00Z", "end": "2026-11-16T15:00:00Z", "allDay": false },
    { "calendar": 1, "title": "", "start": "2026-11-17T17:30:00Z", "end": "2026-11-17T17:30:00Z", "allDay": false }
  ],
  "calendars": [
    { "index": 0, "ok": true, "partial": false },
    { "index": 1, "ok": true, "partial": true },
    { "index": 2, "ok": false, "partial": false, "error": "not_calendar" }
  ]
}
"""

/// The start of the response the API's own route test expects for its Google,
/// iCloud and Outlook fixtures (`api/test/calendar.test.ts`, "merges three
/// calendars, soonest first"), copied as written there, so the app is tested
/// against what the Worker really sends: whole-second UTC instants, `date` on
/// all-day events only, an event without a length.
let calendarJSONFromAPITest = """
{
  "events": [
    { "calendar": 0, "title": "Road trip", "start": "2026-11-14T05:00:00Z", "end": "2026-11-18T05:00:00Z", "allDay": true, "date": "2026-11-14" },
    { "calendar": 1, "title": "Camping at the lake", "start": "2026-11-15T23:00:00Z", "end": "2026-11-17T17:00:00Z", "allDay": false },
    { "calendar": 1, "title": "Morning run", "start": "2026-11-17T12:30:00Z", "end": "2026-11-17T13:00:00Z", "allDay": false },
    { "calendar": 2, "title": "Budget review", "start": "2026-11-17T15:00:00Z", "end": "2026-11-17T16:00:00Z", "allDay": false },
    { "calendar": 0, "title": "Dentist", "start": "2026-11-17T19:00:00Z", "end": "2026-11-17T20:00:00Z", "allDay": false },
    { "calendar": 1, "title": "Call the landlord", "start": "2026-11-18T00:00:00Z", "end": "2026-11-18T00:00:00Z", "allDay": false },
    { "calendar": 0, "title": "Mom's birthday", "start": "2026-11-18T05:00:00Z", "end": "2026-11-19T05:00:00Z", "allDay": true, "date": "2026-11-18" }
  ],
  "calendars": [
    { "index": 0, "ok": true, "partial": false },
    { "index": 1, "ok": true, "partial": false },
    { "index": 2, "ok": true, "partial": false }
  ]
}
"""

/// Made-up links for tests. The "secret" parts are words the tests look for
/// to prove that nothing of a link is shown.
enum TestLinks {
    static let google = "https://calendar.google.com/calendar/ical/someone%40example.com/private-SECRETTOKEN/basic.ics"
    static let icloud = "webcal://p42-caldav.icloud.com/published/2/SECRETTOKEN"
    static let outlook = "https://outlook.live.com/owa/calendar/SECRETID/SECRETTOKEN/calendar.ics"
}

/// One event of a stubbed response, written the way the API writes it.
struct StubEvent {
    var title: String
    var start: String
    var end: String
    var allDay = false
    var date: String?
}

/// What the stub answers for one link.
enum StubCalendar {
    case events([StubEvent], partial: Bool = false)
    case failure(String)
}

/// Answers `POST /v1/calendar/events` from a table of links, the way the API
/// would, and records every request body. A link that is not in the table gets
/// `not_calendar`.
final class CalendarStub: ClientTransport, @unchecked Sendable {
    struct Request: Equatable {
        var links: [String]
        var timezone: String?
    }

    private let lock = NSLock()
    private var table: [String: StubCalendar]
    private var recorded: [Request] = []
    private var isOffline = false
    private var fixed: (HTTPResponse.Status, String)?

    init(_ table: [String: StubCalendar] = [:]) {
        self.table = table
    }

    /// Answers every request with one fixed status and body.
    init(status: HTTPResponse.Status, json: String) {
        table = [:]
        fixed = (status, json)
    }

    var requests: [Request] {
        lock.withLock { recorded }
    }

    func set(_ link: String, _ calendar: StubCalendar?) {
        lock.withLock { table[link] = calendar }
    }

    /// When set, every request fails as if the server were unreachable.
    func setOffline(_ offline: Bool) {
        lock.withLock { isOffline = offline }
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var sent = Request(links: [], timezone: nil)
        if let body {
            let data = try await Data(collecting: body, upTo: 1 << 20)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            sent.links = object?["links"] as? [String] ?? []
            sent.timezone = object?["timezone"] as? String
        }
        let (offline, table, fixed) = lock.withLock {
            recorded.append(sent)
            return (isOffline, self.table, self.fixed)
        }
        if offline { throw URLError(.cannotConnectToHost) }

        var response = HTTPResponse(status: fixed?.0 ?? .ok)
        response.headerFields[.contentType] = "application/json"
        if let fixed { return (response, HTTPBody(fixed.1)) }

        var events: [[String: Any]] = []
        var calendars: [[String: Any]] = []
        for (index, link) in sent.links.enumerated() {
            switch table[link] ?? .failure("not_calendar") {
            case .events(let list, let partial):
                calendars.append(["index": index, "ok": true, "partial": partial])
                for event in list {
                    var json: [String: Any] = [
                        "calendar": index, "title": event.title, "start": event.start,
                        "end": event.end, "allDay": event.allDay,
                    ]
                    json["date"] = event.date
                    events.append(json)
                }
            case .failure(let code):
                calendars.append(["index": index, "ok": false, "partial": false, "error": code])
            }
        }
        events.sort { ($0["start"] as? String ?? "") < ($1["start"] as? String ?? "") }
        let data = try JSONSerialization.data(withJSONObject: ["events": events, "calendars": calendars])
        return (response, HTTPBody(data))
    }
}

func stubbedCalendarAPI(_ stub: CalendarStub) -> SeasignAPI {
    SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: stub)
}
