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
}
