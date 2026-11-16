import Foundation
import HTTPTypes
import OpenAPIRuntime

@testable import Seasign

/// The API's fixed body past its own rate limit (`RATE_LIMITED` in
/// `api/src/lib/rate-limit.ts`).
let rateLimitedJSON = #"{"error":"rate_limited","message":"Too many requests from this network; try again in a minute"}"#

/// Wraps another stub transport. While limited, it answers the chosen
/// operations with the API's 429 (and `Retry-After` when one is given)
/// instead of passing them on, as the Worker's rate limiter does: before
/// the body is read. Counts every request it sees, by operation.
final class RateLimitTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let wrapped: any ClientTransport
    /// nil: pass everything on.
    private var limited: (operations: Set<String>?, retryAfter: String?)?
    private var seen: [String] = []

    init(_ wrapped: any ClientTransport) {
        self.wrapped = wrapped
    }

    /// Answers 429 from now on, to `operations` (all when nil), with
    /// `Retry-After: retryAfter` (left out when nil).
    func limit(_ operations: Set<String>? = nil, retryAfter: String? = "60") {
        lock.withLock { limited = (operations, retryAfter) }
    }

    func lift() {
        lock.withLock { limited = nil }
    }

    /// Requests seen for `operationID`, answered or not.
    func count(_ operationID: String) -> Int {
        lock.withLock { seen.filter { $0 == operationID }.count }
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let limited = lock.withLock {
            seen.append(operationID)
            return self.limited
        }
        if let limited, limited.operations?.contains(operationID) ?? true {
            var response = HTTPResponse(status: .tooManyRequests)
            response.headerFields[.contentType] = "application/json"
            response.headerFields[.cacheControl] = "no-store"
            if let retryAfter = limited.retryAfter {
                response.headerFields[HTTPField.Name("Retry-After")!] = retryAfter
            }
            return (response, HTTPBody(rateLimitedJSON))
        }
        return try await wrapped.send(request, body: body, baseURL: baseURL, operationID: operationID)
    }
}

func stubbedAPI(_ transport: RateLimitTransport) -> SeasignAPI {
    SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: transport)
}
