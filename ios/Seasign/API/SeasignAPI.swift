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

    /// Whether `discover` and the `/v1/google/*` calls refuse to send the
    /// LLM key or the Google token to a server that is not https. On in Release builds; Debug builds talk to `wrangler dev` over
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
        client = Client(serverURL: serverURL, transport: transport, middlewares: [RawKeyHeader(), RawGoogleTokenHeader()])
    }

    /// Why a `/v1/google/*` request failed as a whole. Payload-free: the
    /// generated client's errors describe the request, and these requests
    /// carry the user's Google access token in a header.
    enum GoogleFailure: Error, Equatable {
        /// 401 `google_auth`: Google did not take the access token. Refresh
        /// it and ask once more.
        case googleAuth
        /// 403 `google_forbidden` (calendar list only): the token lacks a
        /// scope; refreshing will not help, the user must connect again.
        case forbidden
        /// 400: the request was refused (a bad header, ids or zone).
        case invalidRequest
        /// The API's own per-network limit (429): wait `retryAfter` seconds.
        case rateLimited(retryAfter: Int)
        /// The server or Google could not be reached, failed, or sent
        /// something unreadable (502, 500, a 3xx, no answer).
        case unavailable
    }

    /// Whether this server can wake the app with Google Calendar pushes: only
    /// a deployed API (https) can. Google calls the production Worker's
    /// webhook, never `wrangler dev` on this Mac, so channels made through a
    /// local server (`http://localhost:8787` in Debug) would never deliver a
    /// push while slowing Today's poll. The one place this is decided; the
    /// watch keeper does nothing for push when it is false.
    var pushAvailable: Bool {
        serverURL.scheme?.lowercased() == "https"
    }

    /// Whether a request carrying the user's LLM key or Google token may go
    /// to `serverURL`: Release builds (`keyNeedsHTTPS`) send them only over
    /// https.
    private var secretMayBeSent: Bool {
        !keyNeedsHTTPS || serverURL.scheme?.lowercased() == "https"
    }

    /// `GET /v1/google/calendars`: the calendars on the user's Google
    /// calendar list, read with `token` (sent in `X-Google-Token` and nowhere
    /// else). When `keyNeedsHTTPS` is on and the server is not https,
    /// nothing is sent and it fails as `unavailable`. Throws a `GoogleFailure`.
    func googleCalendars(token: GoogleSecret) async throws -> [GoogleCalendarEntry] {
        guard secretMayBeSent else { throw GoogleFailure.unavailable }
        let output: Operations.getGoogleCalendars.Output
        do {
            output = try await client.getGoogleCalendars(headers: .init(x_hyphen_google_hyphen_token: token.secret))
        } catch {
            // Dropped on purpose: its description includes the token header.
            if let delay = ServerRateLimit.delay(after: error) { throw GoogleFailure.rateLimited(retryAfter: delay) }
            throw GoogleFailure.unavailable
        }
        switch output {
        case .ok(let response):
            guard let body = try? response.body.json else { throw GoogleFailure.unavailable }
            return body.calendars.map {
                GoogleCalendarEntry(
                    id: $0.id, name: $0.name, primary: $0.primary,
                    accessRole: $0.accessRole.flatMap { GoogleAccessRole(rawValue: $0.rawValue) }
                )
            }
        case .badRequest:
            throw GoogleFailure.invalidRequest
        case .unauthorized:
            throw GoogleFailure.googleAuth
        case .forbidden:
            throw GoogleFailure.forbidden
        case .tooManyRequests(let response):
            throw GoogleFailure.rateLimited(retryAfter: ServerRateLimit.delay(response.headers.Retry_hyphen_After))
        default:
            throw GoogleFailure.unavailable
        }
    }

    /// `POST /v1/google/events`: the events of up to ten Google calendars
    /// (by Google's calendar id) that have not ended and start within seven
    /// days, and how reading each went, read with `token`. A calendar that
    /// cannot be read is reported in `calendars`, not thrown. Not sent over
    /// plain http when `keyNeedsHTTPS` is on (as `googleCalendars`). Throws a
    /// `GoogleFailure`.
    ///
    /// `day` (`YYYY-MM-DD` in `timezone`, today or one of the next six days)
    /// asks instead for every event that overlaps that day, ended ones
    /// included (the day screen). Any other date is the 400
    /// (`invalidRequest`). Left out of the body when nil, so Today's
    /// requests look as they always have.
    func googleEvents(token: GoogleSecret, calendars: [String], timezone: String?, day: String? = nil) async throws -> GoogleEventsAnswer {
        guard secretMayBeSent else { throw GoogleFailure.unavailable }
        let output: Operations.postGoogleEvents.Output
        do {
            output = try await client.postGoogleEvents(
                headers: .init(x_hyphen_google_hyphen_token: token.secret),
                body: .json(.init(calendars: calendars, timezone: timezone, day: day))
            )
        } catch {
            if let delay = ServerRateLimit.delay(after: error) { throw GoogleFailure.rateLimited(retryAfter: delay) }
            throw GoogleFailure.unavailable
        }
        switch output {
        case .ok(let response):
            guard let body = try? response.body.json else { throw GoogleFailure.unavailable }
            return GoogleEventsAnswer(body)
        case .badRequest:
            throw GoogleFailure.invalidRequest
        case .unauthorized:
            throw GoogleFailure.googleAuth
        case .tooManyRequests(let response):
            throw GoogleFailure.rateLimited(retryAfter: ServerRateLimit.delay(response.headers.Retry_hyphen_After))
        default:
            throw GoogleFailure.unavailable
        }
    }

    /// Why `googleCreateEvent` failed. Payload-free, like `GoogleFailure`:
    /// the request carries the Google token, and the title and times.
    enum GoogleCreateFailure: Error, Equatable {
        /// 401 `google_auth`: renew the access token and ask once more.
        case googleAuth
        /// 403 `insufficient_scope`: the sign-in has no write access; the
        /// user must connect again and allow adding events.
        case insufficientScope
        /// 403 `forbidden`: Google will not add events to this calendar.
        case forbidden
        /// 404 `not_found`: Google has no such calendar for this user.
        case notFound
        /// 400: the request was refused as sent. Not retried.
        case invalidRequest
        /// 502 `rejected`: Google refused the event as sent. Nothing was
        /// added; the same request would be refused again.
        case rejected
        /// 429: `retryAfter` seconds when it is the API's own limit (with
        /// `Retry-After`), nil when Google is limiting requests.
        case rateLimited(retryAfter: Int?)
        /// The server or Google could not be reached, timed out, failed or
        /// answered in a way that could not be read (502 `fetch_failed` or
        /// `timeout`, 500, no answer): the event may have been added, so
        /// retry with the same id.
        case unavailable
    }

    /// `POST /v1/google/events/create`: adds `event` to one of the user's
    /// Google calendars with `token` (sent in `X-Google-Token` only). Not
    /// sent over plain http when `keyNeedsHTTPS` is on. Throws a
    /// `GoogleCreateFailure`; the error code in a failure's body tells the
    /// 403s and 502s apart, and nothing else from it is kept.
    func googleCreateEvent(token: GoogleSecret, event: GoogleNewEvent) async throws -> GoogleCreateAnswer {
        guard secretMayBeSent else { throw GoogleCreateFailure.unavailable }
        var body = Components.Schemas.GoogleCreateEventRequest(
            calendar: event.calendarID, id: event.id, title: event.title, timezone: event.timezone
        )
        switch event.timing {
        case .timed(let start, let end):
            body.start = GoogleNewEvent.rfc3339(start)
            body.end = GoogleNewEvent.rfc3339(end)
        case .allDay(let date):
            body.date = date
        }
        let output: Operations.postGoogleCreateEvent.Output
        do {
            output = try await client.postGoogleCreateEvent(
                headers: .init(x_hyphen_google_hyphen_token: token.secret),
                body: .json(body)
            )
        } catch {
            // Dropped on purpose: its description includes the token header and the body.
            if let delay = ServerRateLimit.delay(after: error) { throw GoogleCreateFailure.rateLimited(retryAfter: delay) }
            throw GoogleCreateFailure.unavailable
        }
        switch output {
        case .ok(let response):
            guard let answer = try? response.body.json else { throw GoogleCreateFailure.unavailable }
            return GoogleCreateAnswer(id: answer.id, created: answer.created)
        case .badRequest:
            throw GoogleCreateFailure.invalidRequest
        case .unauthorized:
            throw GoogleCreateFailure.googleAuth
        case .forbidden(let response):
            let code = try? response.body.json.error.rawValue
            throw code == "insufficient_scope" ? GoogleCreateFailure.insufficientScope : GoogleCreateFailure.forbidden
        case .notFound:
            throw GoogleCreateFailure.notFound
        case .tooManyRequests(let response):
            throw GoogleCreateFailure.rateLimited(retryAfter: response.headers.Retry_hyphen_After.map { ServerRateLimit.delay($0) })
        case .badGateway(let response):
            let code = try? response.body.json.error.rawValue
            throw code == "rejected" ? GoogleCreateFailure.rejected : GoogleCreateFailure.unavailable
        default:
            throw GoogleCreateFailure.unavailable
        }
    }

    /// Why `googleWatch` or `googleUnwatch` failed as a whole. Payload-free,
    /// like `GoogleFailure`: these requests carry the Google token in a
    /// header and the device token in the body.
    enum GooglePushFailure: Error, Equatable {
        /// 401 `google_auth`: renew the access token and ask once more.
        case googleAuth
        /// 400: the request was refused.
        case invalidRequest
        /// The API's own per-network limit (429): wait `retryAfter` seconds.
        case rateLimited(retryAfter: Int)
        /// 503 `push_unavailable`: this server has no webhook address (local
        /// `wrangler dev`, say), so it cannot ask Google for notifications.
        case pushUnavailable
        /// The server could not be reached, failed, or sent something unreadable.
        case unavailable
    }

    /// `POST /v1/google/watch`: asks the API to wake this device (`deviceToken`,
    /// lowercase hex, on the `environment` APNs) whenever one of `calendars`
    /// (Google's ids, 1 to 10) changes. Replaces the device's earlier
    /// channels. Sent with `token` in `X-Google-Token`; never over plain http
    /// when `keyNeedsHTTPS` is on. Throws a `GooglePushFailure`.
    func googleWatch(
        token: GoogleSecret, calendars: [String], deviceToken: APNsDeviceToken, environment: APNsEnvironment
    ) async throws -> GoogleWatchAnswer {
        guard secretMayBeSent else { throw GooglePushFailure.unavailable }
        let output: Operations.postGoogleWatch.Output
        do {
            output = try await client.postGoogleWatch(
                headers: .init(x_hyphen_google_hyphen_token: token.secret),
                body: .json(.init(
                    calendars: calendars,
                    deviceToken: deviceToken.hex,
                    environment: environment == .production ? .production : .sandbox
                ))
            )
        } catch {
            // Dropped on purpose: its description includes the token header and the body.
            if let delay = ServerRateLimit.delay(after: error) { throw GooglePushFailure.rateLimited(retryAfter: delay) }
            throw GooglePushFailure.unavailable
        }
        switch output {
        case .ok(let response):
            guard let body = try? response.body.json else { throw GooglePushFailure.unavailable }
            return GoogleWatchAnswer(body)
        case .badRequest:
            throw GooglePushFailure.invalidRequest
        case .unauthorized:
            throw GooglePushFailure.googleAuth
        case .tooManyRequests(let response):
            throw GooglePushFailure.rateLimited(retryAfter: ServerRateLimit.delay(response.headers.Retry_hyphen_After))
        case .serviceUnavailable:
            throw GooglePushFailure.pushUnavailable
        default:
            throw GooglePushFailure.unavailable
        }
    }

    /// `POST /v1/google/unwatch`: stops waking this device; returns how many
    /// channels it had. Sent with `token` (Google stops the channels only if
    /// it still takes the token; the API forgets them either way). Throws a
    /// `GooglePushFailure`.
    @discardableResult
    func googleUnwatch(token: GoogleSecret, deviceToken: APNsDeviceToken) async throws -> Int {
        guard secretMayBeSent else { throw GooglePushFailure.unavailable }
        let output: Operations.postGoogleUnwatch.Output
        do {
            output = try await client.postGoogleUnwatch(
                headers: .init(x_hyphen_google_hyphen_token: token.secret),
                body: .json(.init(deviceToken: deviceToken.hex))
            )
        } catch {
            if let delay = ServerRateLimit.delay(after: error) { throw GooglePushFailure.rateLimited(retryAfter: delay) }
            throw GooglePushFailure.unavailable
        }
        switch output {
        case .ok(let response):
            guard let body = try? response.body.json else { throw GooglePushFailure.unavailable }
            return body.removed
        case .badRequest:
            throw GooglePushFailure.invalidRequest
        case .tooManyRequests(let response):
            throw GooglePushFailure.rateLimited(retryAfter: ServerRateLimit.delay(response.headers.Retry_hyphen_After))
        default:
            throw GooglePushFailure.unavailable
        }
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
        /// The API's own per-network limit (429): wait `retryAfter` seconds
        /// (`ServerRateLimit.delay`) before asking again.
        case rateLimited(retryAfter: Int)
    }

    /// `GET /v1/sky`: weather now, and sun and moon times for today and
    /// tomorrow, for a 5-digit US zip. Throws a `SkyFailure`.
    func sky(zip: String) async throws -> Components.Schemas.Sky {
        let output: Operations.getSky.Output
        do {
            output = try await client.getSky(query: .init(zip: zip))
        } catch {
            if let delay = ServerRateLimit.delay(after: error) { throw SkyFailure.rateLimited(retryAfter: delay) }
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
        case .tooManyRequests(let response):
            throw SkyFailure.rateLimited(retryAfter: ServerRateLimit.delay(response.headers.Retry_hyphen_After))
        default:
            throw SkyFailure.unavailable
        }
    }

    /// Why `calendarEvents(links:timezone:fresh:)` failed as a whole. It carries
    /// nothing from the request or the underlying error: either could hold a
    /// calendar link, which is a credential.
    enum CalendarFailure: Error, Equatable {
        /// The API refused the request (400): no links, more than ten, or a
        /// time zone it does not know.
        case invalidRequest
        /// The server could not be reached, failed, or sent something unreadable.
        case unavailable
        /// The API's own per-network limit (429): wait `retryAfter` seconds.
        case rateLimited(retryAfter: Int)
    }

    /// `POST /v1/calendar/events`: the events of up to ten calendar links that
    /// have not ended and start within seven days, and how reading each link
    /// went. A link that cannot be read is reported in `calendars`, not
    /// thrown. Throws a `CalendarFailure`.
    ///
    /// `fresh` asks the API to read every link again instead of answering
    /// from its 5-minute cache: for a pull, adding a link and a return to the
    /// foreground, never for the scheduled checks. It is left out of the body
    /// when false, so a scheduled request looks as it always has.
    ///
    /// `day` (`YYYY-MM-DD` in `timezone`, today or one of the next six days)
    /// asks instead for every event that overlaps that day, ended ones
    /// included (the day screen). Any other date is the 400
    /// (`invalidRequest`). Left out of the body when nil.
    func calendarEvents(links: [String], timezone: String?, fresh: Bool = false, day: String? = nil) async throws -> CalendarAnswer {
        let output: Operations.postCalendarEvents.Output
        do {
            output = try await client.postCalendarEvents(
                body: .json(.init(links: links, timezone: timezone, fresh: fresh ? true : nil, day: day))
            )
        } catch {
            // The error is dropped on purpose: its description includes the request.
            if let delay = ServerRateLimit.delay(after: error) { throw CalendarFailure.rateLimited(retryAfter: delay) }
            throw CalendarFailure.unavailable
        }
        switch output {
        case .ok(let response):
            guard let body = try? response.body.json else { throw CalendarFailure.unavailable }
            return CalendarAnswer(body)
        case .badRequest:
            throw CalendarFailure.invalidRequest
        case .tooManyRequests(let response):
            throw CalendarFailure.rateLimited(retryAfter: ServerRateLimit.delay(response.headers.Retry_hyphen_After))
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
        /// The API's own per-network limit (429): wait `retryAfter` seconds.
        /// Resolve and feed are limited separately.
        case rateLimited(retryAfter: Int)
    }

    /// `POST /v1/sites/resolve`: how the page at `url` can be followed, or why
    /// it cannot. A page that cannot be read is `.failed`, not thrown. Throws
    /// a `SitesFailure`.
    func resolveSite(url: String) async throws -> SiteResolveResult {
        let output: Operations.postSitesResolve.Output
        do {
            output = try await client.postSitesResolve(body: .json(.init(url: url)))
        } catch {
            if let delay = ServerRateLimit.delay(after: error) { throw SitesFailure.rateLimited(retryAfter: delay) }
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
        case .tooManyRequests(let response):
            throw SitesFailure.rateLimited(retryAfter: ServerRateLimit.delay(response.headers.Retry_hyphen_After))
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
            if let delay = ServerRateLimit.delay(after: error) { throw SitesFailure.rateLimited(retryAfter: delay) }
            throw SitesFailure.unavailable
        }
        switch output {
        case .ok(let response):
            guard let body = try? response.body.json else { throw SitesFailure.unavailable }
            return FeedAnswer(body)
        case .badRequest:
            throw SitesFailure.invalidRequest
        case .tooManyRequests(let response):
            throw SitesFailure.rateLimited(retryAfter: ServerRateLimit.delay(response.headers.Retry_hyphen_After))
        default:
            throw SitesFailure.unavailable
        }
    }

    /// Why `discover` failed: the API's fixed error codes, plus `unavailable`
    /// for a server that could not be reached or answered with something
    /// unreadable. Payload-free: the generated client's errors describe the
    /// request, and this request carries the user's key in a header.
    ///
    /// The API answers 429 for two reasons with the same body: the provider
    /// is limiting the user's key (`rateLimited`, sent without
    /// `Retry-After`), or Seasign's own per-network limit refused the request
    /// before any provider call (`limitedByServer`, always with
    /// `Retry-After`). They are told apart by that header alone.
    enum DiscoverFailure: Error, Equatable, CaseIterable {
        case invalidRequest
        case invalidKey
        case quotaExceeded
        /// The provider is limiting the key (429 without a usable `Retry-After`).
        case rateLimited
        /// Seasign's own limit (429 with `Retry-After`): nothing reached the
        /// provider. Carries only the delay in seconds (`ServerRateLimit.delay`).
        case limitedByServer(retryAfter: Int)
        case providerError
        case timeout
        case internalError
        case unavailable

        static var allCases: [DiscoverFailure] {
            [
                .invalidRequest, .invalidKey, .quotaExceeded, .rateLimited,
                .limitedByServer(retryAfter: ServerRateLimit.fallbackDelay),
                .providerError, .timeout, .internalError, .unavailable,
            ]
        }
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
        guard secretMayBeSent else { throw DiscoverFailure.unavailable }
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
            // Dropped on purpose: a ClientError describes the request, key
            // header included. Only the status and `Retry-After` are read.
            // A 429 lands here when its `Retry-After` is not a number (the
            // generated client fails to decode it): that is not ours, so it
            // is the provider's limit.
            if ServerRateLimit.status(of: error) == 429 {
                if let raw = ServerRateLimit.header(of: error), let seconds = ServerRateLimit.parse(raw) {
                    throw DiscoverFailure.limitedByServer(retryAfter: ServerRateLimit.delay(seconds))
                }
                throw DiscoverFailure.rateLimited
            }
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
        case .tooManyRequests(let response):
            // Ours always sends `Retry-After`; the route forwards no provider
            // headers, so a provider 429 never has one.
            if let seconds = response.headers.Retry_hyphen_After {
                throw DiscoverFailure.limitedByServer(retryAfter: ServerRateLimit.delay(seconds))
            }
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

/// The API's own per-network rate limit (429 `rate_limited` with
/// `Retry-After`, declared on sky, calendar, sites/resolve, feed and
/// discover). The app never retries on its own because of it; each model
/// only holds its automatic refreshes until the delay has passed.
enum ServerRateLimit {
    /// The delay the app honours, in seconds: a value from the server is
    /// brought into this range, so a strange one can neither stop refreshes
    /// for long nor let them run at once.
    static let delayRange = 1...3600
    /// Used when a 429 on a route that requires `Retry-After` arrives
    /// without a readable one. The API sends 60.
    static let fallbackDelay = 60

    /// Fixed text for Settings when sky, calendar or sites answer 429.
    static let message = "Too many requests from this network. Try again in a minute."

    /// `seconds` brought into `delayRange`; nil is `fallbackDelay`.
    static func delay(_ seconds: Int?) -> Int {
        guard let seconds else { return fallbackDelay }
        return min(delayRange.upperBound, max(delayRange.lowerBound, seconds))
    }

    /// A `Retry-After` value as a whole number of seconds; nil for anything
    /// else (an HTTP date, text, empty).
    static func parse(_ value: String) -> Int? {
        Int(value.trimmingCharacters(in: .whitespaces))
    }

    /// For a route whose 429 must carry `Retry-After`: the delay when
    /// `error` is the generated client failing to read a 429 (no or an
    /// unreadable header, or an unexpected body), else nil. Reads only the
    /// status and that one header; the error itself is dropped by the caller.
    static func delay(after error: any Error) -> Int? {
        guard status(of: error) == 429 else { return nil }
        return delay(header(of: error).flatMap(parse))
    }

    /// The HTTP status of the response the generated client failed to read, if any.
    static func status(of error: any Error) -> Int? {
        (error as? ClientError)?.response?.status.code
    }

    /// That response's `Retry-After`, as sent.
    static func header(of error: any Error) -> String? {
        (error as? ClientError)?.response?.headerFields[retryAfter]
    }

    private static let retryAfter = HTTPField.Name("Retry-After")!
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

/// The same for the Google access token in `X-Google-Token`: Google's
/// tokens may hold `/`, `+` and `=`, which the generated client would
/// percent-encode. Only this one header is touched.
struct RawGoogleTokenHeader: ClientMiddleware {
    static let name = HTTPField.Name("x-google-token")!

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

/// One calendar on the user's Google calendar list (`GET /v1/google/calendars`).
struct GoogleCalendarEntry: Sendable, Equatable {
    /// Google's calendar id, sent back in `POST /v1/google/events`.
    var id: String
    /// The user's name for it; may be empty.
    var name: String
    var primary: Bool
    /// The user's access to it, as Google's calendar list gives it; nil when
    /// the API left it out (Google gave none, or a value it does not know).
    var accessRole: GoogleAccessRole? = nil
}

/// Google's `accessRole` for a calendar on the user's list.
enum GoogleAccessRole: String, Sendable, Equatable, CaseIterable {
    case owner
    case writer
    case writerWithoutPrivateAccess
    case reader
    case freeBusyReader

    /// Whether Seasign offers this calendar for new events. The sign-in
    /// asks for `calendar.events.owned` ("See, create, change, and delete
    /// events on Google calendars you own"); Google's docs do not say it
    /// covers calendars the user may only write to, so only `owner` is
    /// offered. The one place this is decided.
    var takesNewEvents: Bool {
        self == .owner
    }
}

/// A `POST /v1/google/events` response in the app's own types. Calendars are
/// named by their index in the request.
struct GoogleEventsAnswer: Sendable, Equatable {
    struct Status: Sendable, Equatable {
        var index: Int
        var ok: Bool
        var partial: Bool
        var error: GoogleCalendarProblem?
    }

    /// The same event shape as `/v1/calendar/events`; `calendar` is the index
    /// of the calendar id in the request.
    var events: [CalendarAnswer.Event]
    var calendars: [Status]
}

extension GoogleEventsAnswer {
    init(_ body: Components.Schemas.GoogleEvents) {
        events = body.events.map { event in
            CalendarAnswer.Event(
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
                error: status.error.flatMap { GoogleCalendarProblem(rawValue: $0.rawValue) }
            )
        }
    }
}

/// One event to add with `POST /v1/google/events/create` (task 171).
struct GoogleNewEvent: Sendable, Equatable {
    /// Google's calendar id.
    var calendarID: String
    /// 32 lowercase hex digits, made once per confirmed event and sent
    /// again on a retry of the same event (`GoogleNewEvent.makeID`).
    var id: String
    var title: String
    /// `UTC` or an IANA Area/Location name (`GoogleNewEvent.zoneName`).
    var timezone: String
    var timing: EventDraft.Timing

    /// A random UUID without its dashes, in lower case.
    static func makeID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The name the API takes for `zone`: its IANA name, or `UTC` for a
    /// zone that has none (`GMT-0500`). The times are sent as instants with
    /// an offset, so they stay exact either way; only the zone Google keeps
    /// with the event differs.
    static func zoneName(_ zone: TimeZone) -> String {
        SearchDay.ianaName(zone) ?? "UTC"
    }

    /// RFC 3339 to the second, in UTC (`2026-11-22T21:00:00Z`).
    static func rfc3339(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }
}

/// A `POST /v1/google/events/create` answer: `created` false means Google
/// already had this id (most likely an earlier try that did succeed).
struct GoogleCreateAnswer: Sendable, Equatable {
    var id: String
    var created: Bool
}

/// A `POST /v1/google/watch` response in the app's own types. Calendars are
/// named by their index in the request.
struct GoogleWatchAnswer: Sendable, Equatable {
    struct Status: Sendable, Equatable {
        var index: Int
        var ok: Bool
        /// The API's code (`forbidden`, `not_found`, `rate_limited`,
        /// `fetch_failed`, `timeout`, `too_large`, `webhook_refused`); nil when ok.
        var error: String?
    }

    var calendars: [Status]
    /// When the first new channel ends; nil when none was made (or the
    /// answer's time could not be read).
    var expiresAt: Date?
}

extension GoogleWatchAnswer {
    init(_ body: Components.Schemas.GoogleWatch) {
        calendars = body.calendars.map { status in
            Status(index: status.index, ok: status.ok, error: status.ok ? nil : (status.error?.rawValue ?? "fetch_failed"))
        }
        expiresAt = body.expiresAt.flatMap { try? Date($0, strategy: .iso8601) }
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
