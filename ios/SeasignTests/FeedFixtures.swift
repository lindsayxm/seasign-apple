import Foundation
import HTTPTypes
import OpenAPIRuntime

@testable import Seasign

/// A `POST /v1/feed` response as the API sends it for three sites asked at
/// 18:05 EST on Sunday 15 November 2026: a feed-mode site with excerpts and
/// its own dates, a links-mode site whose items have no excerpt (a literal
/// `null`) and first-seen dates, and a site that timed out.
let feedJSONThreeSites = """
{
  "items": [
    {
      "site": 0,
      "title": "A new telescope sees first light",
      "link": "https://news.example.com/science/new-telescope-first-light/",
      "source": "Example News",
      "published": "2026-11-15T21:42:55Z",
      "dateSource": "published",
      "excerpt": "The observatory released its first images on Friday\\u2026"
    },
    {
      "site": 1,
      "title": "What the Great Lakes remember about last winter",
      "link": "https://lakes.example.org/2026/11/15/great-lakes-winter",
      "source": "The Lakes Review",
      "published": "2026-11-15T16:10:00Z",
      "dateSource": "first_seen",
      "excerpt": null
    },
    {
      "site": 0,
      "title": "Crows make decisions faster than we can",
      "link": "https://news.example.com/science/crows-decide/",
      "source": "Example News",
      "published": "2026-11-14T09:00:00Z",
      "dateSource": "published",
      "excerpt": "Researchers timed choices in the lab."
    },
    {
      "site": 1,
      "title": "The quiet return of the paper map",
      "link": "https://lakes.example.org/2026/11/10/paper-maps",
      "source": "The Lakes Review",
      "published": "2026-11-10T12:00:00Z",
      "dateSource": "first_seen",
      "excerpt": null
    }
  ],
  "sites": [
    { "index": 0, "ok": true },
    { "index": 1, "ok": true },
    { "index": 2, "ok": false, "error": "timeout" }
  ]
}
"""

let resolveJSONFeed = """
{ "ok": true, "title": "Science | Example News", "url": "https://news.example.com/science/", "mode": "feed", "feedUrl": "https://news.example.com/science/feed/", "linkCount": 24 }
"""

let resolveJSONLinks = """
{ "ok": true, "title": "The Lakes Review", "url": "https://lakes.example.org/", "mode": "links", "linkCount": 12 }
"""

let resolveJSONNoLinks = """
{ "ok": true, "title": "Example Shop", "url": "https://shop.example.com/", "mode": "links", "linkCount": 0 }
"""

/// One item of a stubbed feed answer.
struct StubItem {
    var title: String
    var link: String
    var published: String
    var source = "Example News"
    var dateSource = "published"
    var excerpt: String? = "A short summary."
}

/// What the stub answers for one site in `POST /v1/feed`.
enum StubSite {
    case items([StubItem])
    case failure(String)
}

/// Answers `POST /v1/sites/resolve` and `POST /v1/feed` from tables keyed by
/// address, the way the API would, and records every request. An address
/// that is not in the resolve table gets `fetch_failed`; a site that is not
/// in the feed table gets `fetch_failed` too.
final class FeedStub: ClientTransport, @unchecked Sendable {
    struct FeedRequest: Equatable {
        var urls: [String]
        var modes: [String]
        var feedUrls: [String?]
    }

    private let lock = NSLock()
    private var resolveTable: [String: String] = [:]
    private var siteTable: [String: StubSite] = [:]
    private var resolves: [String] = []
    private var feeds: [FeedRequest] = []
    private var bodies: [Data] = []
    private var isOffline = false
    private var fixed: (HTTPResponse.Status, String)?

    init() {}

    /// Answers every request with one fixed status and body.
    init(status: HTTPResponse.Status, json: String) {
        fixed = (status, json)
    }

    var resolveRequests: [String] { lock.withLock { resolves } }
    var feedRequests: [FeedRequest] { lock.withLock { feeds } }
    var requestBodies: [Data] { lock.withLock { bodies } }

    /// `json` is the whole resolve answer for `url`.
    func resolve(_ url: String, _ json: String) {
        lock.withLock { resolveTable[url] = json }
    }

    func site(_ url: String, _ answer: StubSite?) {
        lock.withLock { siteTable[url] = answer }
    }

    func setOffline(_ offline: Bool) {
        lock.withLock { isOffline = offline }
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var data = Data()
        if let body { data = try await Data(collecting: body, upTo: 1 << 20) }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let (offline, fixed, resolveTable, siteTable) = lock.withLock {
            bodies.append(data)
            if operationID == "postSitesResolve" {
                resolves.append(object["url"] as? String ?? "")
            } else {
                let sites = object["sites"] as? [[String: Any]] ?? []
                feeds.append(FeedRequest(
                    urls: sites.map { $0["url"] as? String ?? "" },
                    modes: sites.map { $0["mode"] as? String ?? "" },
                    feedUrls: sites.map { $0["feedUrl"] as? String }
                ))
            }
            return (isOffline, self.fixed, self.resolveTable, self.siteTable)
        }
        if offline { throw URLError(.cannotConnectToHost) }

        var response = HTTPResponse(status: fixed?.0 ?? .ok)
        response.headerFields[.contentType] = "application/json"
        if let fixed { return (response, HTTPBody(fixed.1)) }

        if operationID == "postSitesResolve" {
            let url = object["url"] as? String ?? ""
            return (response, HTTPBody(resolveTable[url] ?? #"{"ok":false,"error":"fetch_failed"}"#))
        }

        var items: [[String: Any]] = []
        var statuses: [[String: Any]] = []
        let sites = object["sites"] as? [[String: Any]] ?? []
        for (index, site) in sites.enumerated() {
            switch siteTable[site["url"] as? String ?? ""] ?? .failure("fetch_failed") {
            case .items(let list):
                statuses.append(["index": index, "ok": true])
                for item in list {
                    items.append([
                        "site": index, "title": item.title, "link": item.link, "source": item.source,
                        "published": item.published, "dateSource": item.dateSource,
                        "excerpt": item.excerpt.map { $0 as Any } ?? NSNull(),
                    ])
                }
            case .failure(let code):
                statuses.append(["index": index, "ok": false, "error": code])
            }
        }
        items.sort { ($0["published"] as? String ?? "") > ($1["published"] as? String ?? "") }
        let json = try JSONSerialization.data(withJSONObject: ["items": items, "sites": statuses])
        return (response, HTTPBody(json))
    }
}

func stubbedFeedAPI(_ stub: FeedStub) -> SeasignAPI {
    SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: stub)
}
