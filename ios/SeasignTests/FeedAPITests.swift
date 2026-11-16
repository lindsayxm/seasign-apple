import Foundation
import HTTPTypes
import Testing

@testable import Seasign

/// `SeasignAPI.resolveSite` and `SeasignAPI.feed` against realistic payloads,
/// through the generated client.
@Suite struct FeedAPITests {
    private func api(_ json: String, status: Int = 200) -> SeasignAPI {
        stubbedFeedAPI(FeedStub(status: .init(code: status), json: json))
    }

    // MARK: Resolve

    @Test func resolveReadsAFeedModeSite() async throws {
        let result = try await api(resolveJSONFeed).resolveSite(url: "https://news.example.com/science")
        #expect(result == .resolved(.init(
            title: "Science | Example News",
            url: "https://news.example.com/science/",
            mode: .feed,
            feedUrl: "https://news.example.com/science/feed/",
            linkCount: 24
        )))
    }

    @Test func resolveReadsALinksModeSiteWithNoLinks() async throws {
        let result = try await api(resolveJSONNoLinks).resolveSite(url: "https://shop.example.com/")
        #expect(result == .resolved(.init(
            title: "Example Shop", url: "https://shop.example.com/", mode: .links, feedUrl: nil, linkCount: 0
        )))
    }

    @Test(arguments: SiteProblem.allCases)
    func resolveFailuresKeepTheirCode(problem: SiteProblem) async throws {
        let json = #"{"ok":false,"error":"\#(problem.rawValue)"}"#
        let result = try await api(json).resolveSite(url: "https://example.com/")
        #expect(result == .failed(problem))
    }

    /// An answer that claims success but lacks what following needs is not
    /// taken as a success.
    @Test(arguments: [
        #"{"ok":true,"title":"x","mode":"links","linkCount":3}"#,
        #"{"ok":true,"title":"x","url":"https://a.example/","linkCount":3}"#,
        #"{"ok":true,"title":"x","url":"https://a.example/","mode":"feed"}"#,
    ])
    func resolveSuccessWithoutWhatIsNeededIsUnavailable(json: String) async {
        await #expect(throws: SeasignAPI.SitesFailure.unavailable) {
            try await api(json).resolveSite(url: "https://a.example/")
        }
    }

    @Test func resolveBadRequestAndServerErrors() async {
        await #expect(throws: SeasignAPI.SitesFailure.invalidRequest) {
            try await api(#"{"error":"invalid_request","message":"bad"}"#, status: 400).resolveSite(url: "x")
        }
        await #expect(throws: SeasignAPI.SitesFailure.unavailable) {
            try await api(#"{"error":"internal_error","message":"oops"}"#, status: 500).resolveSite(url: "x")
        }
        let offline = FeedStub()
        offline.setOffline(true)
        await #expect(throws: SeasignAPI.SitesFailure.unavailable) {
            try await stubbedFeedAPI(offline).resolveSite(url: "https://example.com/")
        }
    }

    // MARK: Feed

    @Test func feedDecodesFeedLinksAndFailedSites() async throws {
        let answer = try await api(feedJSONThreeSites).feed(sites: [
            .init(url: "https://news.example.com/science/", mode: .feed, feedUrl: "https://news.example.com/science/feed/"),
            .init(url: "https://lakes.example.org/", mode: .links, feedUrl: nil),
            .init(url: "https://wire.example.net/world", mode: .links, feedUrl: nil),
        ])
        #expect(answer.items.count == 4)
        let first = try #require(answer.items.first)
        #expect(first.site == 0)
        #expect(first.title == "A new telescope sees first light")
        #expect(first.published == instant("2026-11-15T21:42:55Z"))
        #expect(first.dateSource == .published)
        #expect(first.excerpt == "The observatory released its first images on Friday\u{2026}")

        let links = answer.items[1]
        #expect(links.site == 1)
        #expect(links.dateSource == .firstSeen)
        #expect(links.excerpt == nil)

        #expect(answer.sites == [
            .init(index: 0, ok: true, error: nil),
            .init(index: 1, ok: true, error: nil),
            .init(index: 2, ok: false, error: .timeout),
        ])
    }

    @Test func feedRequestCarriesModeAndFeedAddressOnly() async throws {
        let stub = FeedStub()
        _ = try await stubbedFeedAPI(stub).feed(sites: [
            .init(url: "https://news.example.com/science/", mode: .feed, feedUrl: "https://news.example.com/science/feed/"),
            .init(url: "https://lakes.example.org/", mode: .links, feedUrl: nil),
        ])
        #expect(stub.feedRequests == [.init(
            urls: ["https://news.example.com/science/", "https://lakes.example.org/"],
            modes: ["feed", "links"],
            feedUrls: ["https://news.example.com/science/feed/", nil]
        )])
    }

    @Test func feedBadRequestAndServerErrors() async {
        let site = FeedAnswer.Request(url: "https://a.example/", mode: .links, feedUrl: nil)
        await #expect(throws: SeasignAPI.SitesFailure.invalidRequest) {
            try await api(#"{"error":"invalid_request","message":"The request body is too large"}"#, status: 400).feed(sites: [site])
        }
        await #expect(throws: SeasignAPI.SitesFailure.unavailable) {
            try await api(#"{"error":"internal_error","message":"oops"}"#, status: 500).feed(sites: [site])
        }
        await #expect(throws: SeasignAPI.SitesFailure.unavailable) {
            try await api(#"{"items":[{"site":0}],"sites":[]}"#, status: 200).feed(sites: [site])
        }
    }

    /// The API refuses bodies over 64 KB. Fifty sites at the longest the app
    /// accepts, made of the character JSON escapes most, must still fit.
    @Test func fiftyLongestSitesFitTheBodyLimit() async throws {
        let stub = FeedStub()
        let half = SiteAddress.maxBytes / 2
        let url = "https://" + String(repeating: "/", count: half - 8)
        let feedUrl = "https://" + String(repeating: "\"", count: SiteAddress.maxBytes - half - 8)
        #expect(SiteAddress.fits(url: url, feedUrl: feedUrl))
        let sites = (0..<FeedModel.maxSites).map { _ in FeedAnswer.Request(url: url, mode: .feed, feedUrl: feedUrl) }
        _ = try await stubbedFeedAPI(stub).feed(sites: sites)
        let body = try #require(stub.requestBodies.first)
        #expect(body.count < 64 * 1024, "body was \(body.count) bytes")
    }
}
