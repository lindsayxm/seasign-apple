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
}
