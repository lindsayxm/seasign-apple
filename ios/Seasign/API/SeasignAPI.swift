import Foundation
import HTTPTypes
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

    /// Whether `discover` refuses to send the key to a server that is not
    /// https. On in Release builds; Debug builds talk to `wrangler dev` over
    /// plain http on this Mac.
    static var keyNeedsHTTPSByDefault: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    /// The one URLSession every API call goes through. Ephemeral, with no
    /// cookies, cache or credential store, and it never follows a redirect:
    /// URLSession would send the request's headers, the user's LLM key
    /// among them, again to whatever address a redirect names. None of the
    /// API's routes redirects, so a 3xx answer comes back as itself and each
    /// call reports it as a failure. Shared, because a session with a
    /// delegate lives until it is invalidated.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    /// The transport over `session`. Buffered, not streaming: in streaming
    /// mode swift-openapi-urlsession puts a delegate of its own on each task,
    /// and buffered mode leaves the session's delegate as the only one that
    /// decides on redirects. The API's bodies are small JSON.
    static var defaultTransport: any ClientTransport {
        URLSessionTransport(configuration: .init(session: session, httpBodyProcessingMode: .buffered))
    }

    private let client: Client
    private let serverURL: URL
    private let keyNeedsHTTPS: Bool

    init(
        serverURL: URL = SeasignAPI.defaultServerURL,
        transport: any ClientTransport = SeasignAPI.defaultTransport,
        keyNeedsHTTPS: Bool = SeasignAPI.keyNeedsHTTPSByDefault
    ) {
        self.serverURL = serverURL
        self.keyNeedsHTTPS = keyNeedsHTTPS
        client = Client(serverURL: serverURL, transport: transport, middlewares: [RawKeyHeader()])
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

    /// Why a sites or feed request failed as a whole. Payload-free, like
    /// `CalendarFailure`: the generated client's errors describe the request.
    enum SitesFailure: Error, Equatable {
        /// The API refused the request (400): a bad body, too many sites, or
        /// a body over 64 KB.
        case invalidRequest
        /// The server could not be reached, failed, or sent something unreadable.
        case unavailable
    }

    /// `POST /v1/sites/resolve`: how the page at `url` can be followed, or why
    /// it cannot. A page that cannot be read is `.failed`, not thrown. Throws
    /// a `SitesFailure`.
    func resolveSite(url: String) async throws -> SiteResolveResult {
        let output: Operations.postSitesResolve.Output
        do {
            output = try await client.postSitesResolve(body: .json(.init(url: url)))
        } catch {
            throw SitesFailure.unavailable
        }
        switch output {
        case .ok(let response):
            guard let body = try? response.body.json,
                  let result = SiteResolveResult(body)
            else { throw SitesFailure.unavailable }
            return result
        case .badRequest:
            throw SitesFailure.invalidRequest
        default:
            throw SitesFailure.unavailable
        }
    }

    /// `POST /v1/feed`: the last 7 days of items from up to 50 sites, newest
    /// first, and how reading each site went. A site that cannot be read is
    /// reported in `sites`, not thrown. Throws a `SitesFailure`.
    func feed(sites: [FeedAnswer.Request]) async throws -> FeedAnswer {
        let output: Operations.postFeed.Output
        do {
            output = try await client.postFeed(
                body: .json(.init(sites: sites.map {
                    Components.Schemas.FeedSite(
                        url: $0.url,
                        mode: $0.mode == .feed ? .feed : .links,
                        feedUrl: $0.feedUrl
                    )
                }))
            )
        } catch {
            throw SitesFailure.unavailable
        }
        switch output {
        case .ok(let response):
            guard let body = try? response.body.json else { throw SitesFailure.unavailable }
            return FeedAnswer(body)
        case .badRequest:
            throw SitesFailure.invalidRequest
        default:
            throw SitesFailure.unavailable
        }
    }

    /// Why `discover` failed: the API's fixed error codes, plus `unavailable`
    /// for a server that could not be reached or answered with something
    /// unreadable. Payload-free: the generated client's errors describe the
    /// request, and this request carries the user's key in a header.
    enum DiscoverFailure: Error, Equatable, CaseIterable {
        case invalidRequest
        case invalidKey
        case quotaExceeded
        case rateLimited
        case providerError
        case timeout
        case internalError
        case unavailable
    }

    /// `POST /v1/discover`: recent publications on `interests`, found by
    /// `provider` with the user's own `key`, which goes in the `X-LLM-Key`
    /// header and nowhere else. `timezone` is sent only when it is an IANA
    /// name the API accepts (`SearchDay.ianaName(identifier:)`); anything
    /// else is left out, so the API uses UTC rather than refusing the search.
    /// When `keyNeedsHTTPS` is on (Release builds) and the server is not
    /// https, nothing is sent and the call fails as `unavailable`.
    /// Throws a `DiscoverFailure`, chosen by the status code alone; a
    /// redirect, which is never followed, is `unavailable`.
    func discover(
        key: APIKey,
        provider: AIProvider,
        interests: [String],
        timezone: String?
    ) async throws -> DiscoverAnswer {
        guard !keyNeedsHTTPS || serverURL.scheme?.lowercased() == "https" else {
            throw DiscoverFailure.unavailable
        }
        let output: Operations.postDiscover.Output
        do {
            output = try await client.postDiscover(
                headers: .init(x_hyphen_llm_hyphen_key: key.secret),
                body: .json(.init(
                    provider: Components.Schemas.DiscoverRequest.providerPayload(rawValue: provider.rawValue) ?? .anthropic,
                    interests: interests,
                    timezone: timezone.flatMap(SearchDay.ianaName(identifier:))
                ))
            )
        } catch {
            // Dropped on purpose: a ClientError describes the request, key header included.
            throw DiscoverFailure.unavailable
        }
        switch output {
        case .ok(let response):
            guard let body = try? response.body.json else { throw DiscoverFailure.unavailable }
            return DiscoverAnswer(body)
        case .badRequest:
            throw DiscoverFailure.invalidRequest
        case .unauthorized:
            throw DiscoverFailure.invalidKey
        case .code402:
            throw DiscoverFailure.quotaExceeded
        case .tooManyRequests:
            throw DiscoverFailure.rateLimited
        case .badGateway:
            throw DiscoverFailure.providerError
        case .gatewayTimeout:
            throw DiscoverFailure.timeout
        case .internalServerError:
            throw DiscoverFailure.internalError
        case .undocumented:
            throw DiscoverFailure.unavailable
        }
    }
}

/// Refuses every redirect, so the completed task carries the 3xx answer
/// itself and no request goes to the address it names (see `SeasignAPI.session`).
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// The generated client writes header parameters as URI components, so a
/// key holding `/`, `+`, `=` or `%` would reach the server percent-encoded,
/// that is, as a different key. This puts the key's own characters back
/// before the request leaves. Percent-encoding is reversed exactly, and only
/// this one header is touched.
struct RawKeyHeader: ClientMiddleware {
    static let name = HTTPField.Name("x-llm-key")!

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let encoded = request.headerFields[Self.name], let raw = encoded.removingPercentEncoding {
            request.headerFields[Self.name] = raw
        }
        return try await next(request, body, baseURL)
    }
}

/// A `POST /v1/discover` response in the app's own types. Everything in an
/// item came from a model and the web: untrusted text, cleaned before it is stored.
struct DiscoverAnswer: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        var title: String
        var link: String
        var source: String
        var published: Date?
        var excerpt: String?
        /// The request's interest it matched, as sent; nil when unclear.
        var interest: String?
    }

    var items: [Item]
    var provider: AIProvider?
    var searchedAt: Date
}

extension DiscoverAnswer {
    init(_ body: Components.Schemas.Discover) {
        items = body.items.map {
            Item(
                title: $0.title,
                link: $0.link,
                source: $0.source,
                published: $0.published,
                excerpt: $0.excerpt,
                interest: $0.interest
            )
        }
        provider = AIProvider(rawValue: body.provider.rawValue)
        searchedAt = body.searchedAt
    }
}

/// A `POST /v1/sites/resolve` answer in the app's own types.
enum SiteResolveResult: Sendable, Equatable {
    struct Resolved: Sendable, Equatable {
        /// The page's or feed's title, as the site gives it (untrusted text).
        var title: String
        /// The address in normal form; what to store and send to `/v1/feed`.
        var url: String
        var mode: SiteMode
        /// Only in feed mode.
        var feedUrl: String?
        /// How many article links the page shows now; nil when the address is a feed.
        var linkCount: Int?
    }

    case resolved(Resolved)
    case failed(SiteProblem)
}

extension SiteResolveResult {
    /// Nil for an answer that says it worked but lacks what following the
    /// site needs (an address and a mode, and a feed address in feed mode).
    init?(_ body: Components.Schemas.SiteResolve) {
        guard body.ok else {
            let problem = body.error.flatMap { SiteProblem(rawValue: $0.rawValue) } ?? .fetchFailed
            self = .failed(problem)
            return
        }
        guard let url = body.url, !url.isEmpty, let rawMode = body.mode,
              let mode = SiteMode(rawValue: rawMode.rawValue)
        else { return nil }
        let feedUrl = mode == .feed ? body.feedUrl : nil
        if mode == .feed, feedUrl?.isEmpty ?? true { return nil }
        self = .resolved(Resolved(
            title: body.title ?? "",
            url: url,
            mode: mode,
            feedUrl: feedUrl,
            linkCount: body.linkCount
        ))
    }
}

/// A `POST /v1/feed` response in the app's own types. Sites are named by
/// their index in the request.
struct FeedAnswer: Sendable, Equatable {
    /// One site as the request names it.
    struct Request: Sendable, Equatable {
        var url: String
        var mode: SiteMode
        var feedUrl: String?
    }

    struct Item: Sendable, Equatable {
        /// Index of the site in the request.
        var site: Int
        var title: String
        var link: String
        var source: String
        var published: Date
        var dateSource: FeedDateSource
        /// Nil when the site gives no summary (always for links mode).
        var excerpt: String?
    }

    struct Status: Sendable, Equatable {
        var index: Int
        var ok: Bool
        var error: SiteProblem?
    }

    var items: [Item]
    /// One entry per site, in request order.
    var sites: [Status]
}

extension FeedAnswer {
    init(_ body: Components.Schemas.Feed) {
        items = body.items.map { item in
            Item(
                site: item.site,
                title: item.title,
                link: item.link,
                source: item.source,
                published: item.published,
                dateSource: FeedDateSource(rawValue: item.dateSource.rawValue) ?? .published,
                excerpt: item.excerpt
            )
        }
        sites = body.sites.map { status in
            Status(
                index: status.index,
                ok: status.ok,
                error: status.error.flatMap { SiteProblem(rawValue: $0.rawValue) }
            )
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
