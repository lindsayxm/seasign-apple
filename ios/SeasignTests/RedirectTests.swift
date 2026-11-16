import Foundation
import Testing

@testable import Seasign

/// The API's own routes never redirect. URLSession follows redirects by
/// default and sends the request's headers again to the new address, which
/// for `POST /v1/discover` would hand the user's key to whoever the
/// redirect names. These tests go through the app's real transport and two
/// local servers: the first answers with a redirect to the second, and the
/// second must never see a request.
@Suite(.serialized) struct RedirectTests {
    private func servers(status: Int) async throws -> (first: LocalHTTPServer, target: LocalHTTPServer) {
        let target = try await LocalHTTPServer(answering: .init(
            status: 200,
            reason: "OK",
            headers: [("Content-Type", "application/json")],
            body: Data(discoverJSONThreeItems.utf8)
        ))
        let first = try await LocalHTTPServer(answering: .init(
            status: status,
            reason: "Redirect",
            headers: [("Location", target.url.absoluteString + "/v1/discover")]
        ))
        return (first, target)
    }

    @Test(arguments: [301, 302, 303, 307, 308])
    func aRedirectOnDiscoverFailsAndTheKeyNeverReachesTheTarget(status: Int) async throws {
        let (first, target) = try await servers(status: status)
        defer {
            first.stop()
            target.stop()
        }
        // The real transport (no stub); plain http to the local servers, so the
        // Release-only https rule is switched off here explicitly.
        let api = SeasignAPI(serverURL: first.url, keyNeedsHTTPS: false)
        do {
            _ = try await api.discover(
                key: APIKey(typed: fakeKey)!, provider: .anthropic, interests: ["tide pools"], timezone: nil
            )
            Issue.record("a redirect must not succeed")
        } catch {
            #expect(error as? SeasignAPI.DiscoverFailure == .unavailable)
            #expect(!String(reflecting: error).contains(fakeKey))
        }
        // The first server did get the key (that is where the app sent it)...
        #expect(first.requests.count == 1)
        #expect(first.requests.first?.header("x-llm-key") == fakeKey)
        // ...and the redirect target got nothing at all.
        #expect(target.requests.isEmpty)
        #expect(!target.requests.contains { $0.header("x-llm-key") != nil })
    }

    /// Every route goes through the same session, not only discover.
    @Test func aRedirectOnAnyOtherRouteFailsToo() async throws {
        let (first, target) = try await servers(status: 307)
        defer {
            first.stop()
            target.stop()
        }
        // The real transport (no stub); plain http to the local servers, so the
        // Release-only https rule is switched off here explicitly.
        let api = SeasignAPI(serverURL: first.url, keyNeedsHTTPS: false)
        await #expect(throws: SeasignAPI.SkyFailure.unavailable) { try await api.sky(zip: "60601") }
        await #expect(throws: SeasignAPI.CalendarFailure.unavailable) {
            try await api.calendarEvents(links: ["https://calendar.example.test/a.ics"], timezone: nil)
        }
        await #expect(throws: SeasignAPI.SitesFailure.unavailable) {
            try await api.resolveSite(url: "https://news.example.test/")
        }
        await #expect(throws: SeasignAPI.SitesFailure.unavailable) {
            try await api.feed(sites: [.init(url: "https://news.example.test/", mode: .links, feedUrl: nil)])
        }
        await #expect(throws: (any Error).self) { try await api.health() }
        #expect(first.requests.count == 5)
        #expect(target.requests.isEmpty)
    }
}
