import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// Thin wrapper over the client that swift-openapi-generator builds from
/// `openapi/openapi.json`. Screens talk to this type, not to `Client` directly.
struct SeasignAPI: Sendable {
    /// Where the API lives. Debug builds talk to `npx wrangler dev` on this Mac,
    /// which the Simulator reaches as localhost.
    static var defaultServerURL: URL {
        #if DEBUG
        URL(string: "http://localhost:8787")!
        #else
        // Placeholder: nothing is deployed yet. Set when the Worker gets a real address.
        URL(string: "https://seasign-api.invalid")!
        #endif
    }

    private let client: Client

    init(
        serverURL: URL = SeasignAPI.defaultServerURL,
        transport: any ClientTransport = URLSessionTransport()
    ) {
        client = Client(serverURL: serverURL, transport: transport)
    }

    /// `GET /v1/health`. Throws when the server is unreachable or answers with anything but 200.
    func health() async throws -> Components.Schemas.Health {
        try await client.getHealth().ok.body.json
    }

    /// Why `sky(zip:)` failed.
    enum SkyFailure: Error, Equatable {
        /// The zip is not five digits (400).
        case invalidZip
        /// No US place is known for the zip (404). Some real zips are missing
        /// from the geocoder, such as PO-box-only zips.
        case unknownZip
        /// The server or the weather provider could not be reached or failed.
        case unavailable
    }

    /// `GET /v1/sky`: weather now, and sun and moon times for today and
    /// tomorrow, for a 5-digit US zip. Throws a `SkyFailure`.
    func sky(zip: String) async throws -> Components.Schemas.Sky {
        let output: Operations.getSky.Output
        do {
            output = try await client.getSky(query: .init(zip: zip))
        } catch {
            throw SkyFailure.unavailable
        }
        switch output {
        case .ok(let response):
            guard let sky = try? response.body.json else { throw SkyFailure.unavailable }
            return sky
        case .badRequest:
            throw SkyFailure.invalidZip
        case .notFound:
            throw SkyFailure.unknownZip
        default:
            throw SkyFailure.unavailable
        }
    }

    /// Why `calendarEvents(links:timezone:)` failed as a whole. It carries
    /// nothing from the request or the underlying error: either could hold a
    /// calendar link, which is a credential.
    enum CalendarFailure: Error, Equatable {
        /// The API refused the request (400): no links, more than ten, or a
        /// time zone it does not know.
        case invalidRequest
        /// The server could not be reached, failed, or sent something unreadable.
        case unavailable
    }

    /// `POST /v1/calendar/events`: the events of up to ten calendar links that
    /// have not ended and start within seven days, and how reading each link
    /// went. A link that cannot be read is reported in `calendars`, not
    /// thrown. Throws a `CalendarFailure`.
    func calendarEvents(links: [String], timezone: String?) async throws -> CalendarAnswer {
        let output: Operations.postCalendarEvents.Output
        do {
            output = try await client.postCalendarEvents(
                body: .json(.init(links: links, timezone: timezone))
            )
        } catch {
            // The error is dropped on purpose: its description includes the request.
            throw CalendarFailure.unavailable
        }
        switch output {
        case .ok(let response):
            guard let body = try? response.body.json else { throw CalendarFailure.unavailable }
            return CalendarAnswer(body)
        case .badRequest:
            throw CalendarFailure.invalidRequest
        default:
            throw CalendarFailure.unavailable
        }
    }
}

/// A `POST /v1/calendar/events` response in the app's own types. Calendars are
/// named by their index in the request; the response never holds a link.
struct CalendarAnswer: Sendable, Equatable {
    struct Event: Sendable, Equatable {
        /// Index of the link in the request this event came from.
        var calendar: Int
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        /// Only for all-day events: the local start date, `YYYY-MM-DD`.
        var date: String?
    }

    struct Status: Sendable, Equatable {
        var index: Int
        var ok: Bool
        var partial: Bool
        var error: LinkProblem?
    }

    var events: [Event]
    /// One entry per link, in request order.
    var calendars: [Status]
}

extension CalendarAnswer {
    /// Copies a response from the generated client.
    init(_ body: Components.Schemas.CalendarEvents) {
        events = body.events.map { event in
            Event(
                calendar: event.calendar,
                title: event.title,
                start: event.start,
                end: event.end,
                allDay: event.allDay,
                date: event.date
            )
        }
        calendars = body.calendars.map { status in
            Status(
                index: status.index,
                ok: status.ok,
                partial: status.partial,
                error: status.error.flatMap { LinkProblem(rawValue: $0.rawValue) }
            )
        }
    }
}
