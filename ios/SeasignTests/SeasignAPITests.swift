import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import Seasign

/// Answers every request with a fixed response, so the tests need no server.
private struct StubTransport: ClientTransport {
    var status: HTTPResponse.Status
    var json: String

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(json))
    }
}

private func stubbedAPI(status: HTTPResponse.Status, json: String) -> SeasignAPI {
    SeasignAPI(
        serverURL: URL(string: "https://example.test")!,
        transport: StubTransport(status: status, json: json)
    )
}

@Suite struct SeasignAPITests {
    @Test func healthDecodesTheGeneratedType() async throws {
        let api = stubbedAPI(status: .ok, json: #"{"status":"ok","service":"seasign-api"}"#)
        let health = try await api.health()
        #expect(health.status == .ok)
        #expect(health.service == "seasign-api")
    }

    @Test func healthThrowsOnAnUnexpectedStatus() async {
        let api = stubbedAPI(status: .internalServerError, json: "{}")
        await #expect(throws: (any Error).self) {
            try await api.health()
        }
    }

    @Test @MainActor func modelReportsReachable() async {
        let model = HealthModel(
            api: stubbedAPI(status: .ok, json: #"{"status":"ok","service":"seasign-api"}"#)
        )
        await model.load()
        #expect(model.state == .reachable(service: "seasign-api"))
    }

    @Test @MainActor func modelReportsUnreachable() async {
        let model = HealthModel(api: stubbedAPI(status: .internalServerError, json: "{}"))
        await model.load()
        guard case .unreachable = model.state else {
            Issue.record("expected .unreachable, got \(model.state)")
            return
        }
    }
}
