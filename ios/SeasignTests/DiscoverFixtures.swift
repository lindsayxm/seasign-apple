import Foundation
import HTTPTypes
import OpenAPIRuntime

@testable import Seasign

/// The obviously fake key every test uses. Never a real or realistic key.
let fakeKey = "test-key-not-real-0000"

/// A `POST /v1/discover` answer as the API sends it: a dated item, an undated
/// one with no excerpt or interest, and one whose link is not https.
let discoverJSONThreeItems = """
{
  "items": [
    {
      "title": "Tide pools are filling with warm-water visitors",
      "link": "https://coast.example.org/2026/tide-pool-visitors",
      "source": "Coast Notes",
      "published": "2026-11-15T20:00:00Z",
      "excerpt": "Volunteers found species usually seen far to the south.",
      "interest": "tide pools"
    },
    {
      "title": "A small telescope caught a comet's tail splitting",
      "link": "https://sky.example.net/comet-tail",
      "source": "",
      "published": null,
      "excerpt": null,
      "interest": null
    },
    {
      "title": "Not safe",
      "link": "http://plain.example.com/a",
      "source": "Plain",
      "published": "2026-11-15T20:00:00Z",
      "excerpt": null,
      "interest": "tide pools"
    }
  ],
  "provider": "anthropic",
  "searchedAt": "2026-11-15T23:00:00Z"
}
"""

/// The fixed error body the API sends for `code`.
func discoverErrorJSON(_ code: String) -> String {
    #"{"error":"\#(code)","message":"Fixed text for \#(code)"}"#
}

/// Answers `POST /v1/discover`, records every request, and can hold a
/// request until the test releases it, to make two searches overlap.
///
/// It reflects as nothing: it stands in for the network, and what it
/// records (the key header included) is not part of the app's state that the
/// leak test dumps.
final class DiscoverStub: ClientTransport, CustomReflectable, @unchecked Sendable {
    var customMirror: Mirror { Mirror(self, children: [:]) }

    struct Recorded {
        var request: HTTPRequest
        var body: Data
    }

    private let lock = NSLock()
    private var status: HTTPResponse.Status = .ok
    private var json = discoverJSONThreeItems
    private var thrown: (any Error)?
    private var recorded: [Recorded] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var holding = false

    init() {}

    var requests: [Recorded] { lock.withLock { recorded } }
    var count: Int { lock.withLock { recorded.count } }

    func answer(_ status: HTTPResponse.Status, _ json: String) {
        lock.withLock {
            self.status = status
            self.json = json
            thrown = nil
        }
    }

    /// Makes the transport throw `error`, as a network failure would.
    func fail(with error: any Error) {
        lock.withLock { thrown = error }
    }

    /// While on, every request waits for `release()`.
    func hold(_ on: Bool) {
        lock.withLock { holding = on }
    }

    func release() {
        let waiting = lock.withLock {
            let list = held
            held = []
            return list
        }
        for continuation in waiting { continuation.resume() }
    }

    var waitingCount: Int { lock.withLock { held.count } }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var data = Data()
        if let body { data = try await Data(collecting: body, upTo: 1 << 20) }
        let shouldHold = lock.withLock {
            recorded.append(Recorded(request: request, body: data))
            return holding
        }
        if shouldHold {
            await withCheckedContinuation { continuation in
                lock.withLock { held.append(continuation) }
            }
        }
        let (status, json, thrown) = lock.withLock { (self.status, self.json, self.thrown) }
        if let thrown { throw thrown }
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(json))
    }
}

func stubbedDiscoverAPI(_ stub: DiscoverStub) -> SeasignAPI {
    SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: stub)
}

/// An error whose description holds whatever it was given, standing in for a
/// network error that echoes the request.
struct EchoingError: Error, CustomStringConvertible {
    var text: String
    var description: String { "request failed: " + text }
}
