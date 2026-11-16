import Foundation
import HTTPTypes
import OpenAPIRuntime
import SwiftData

@testable import Seasign

/// A `GET /v1/sky?zip=10001` response as the API sends it (built from the
/// Open-Meteo fixture in `api/test/fixtures/forecast-10001.json`): observed at
/// 18:00 EST on 15 November 2026, after sunset, with the moon up until 21:49.
let skyJSON10001 = """
{
  "zip": "10001",
  "place": { "name": "New York", "region": "New York", "latitude": 40.71427, "longitude": -74.00597 },
  "timezone": "America/New_York",
  "utcOffsetSeconds": -18000,
  "current": {
    "observedAt": "2026-11-15T23:00:00Z",
    "temperatureF": 43.4,
    "weatherCode": 0,
    "cloudCoverPercent": 4,
    "windSpeedMph": 9.3,
    "windGustsMph": 25.1,
    "isDay": false
  },
  "days": [
    {
      "date": "2026-11-15",
      "sunrise": "2026-11-15T11:42:55Z",
      "sunset": "2026-11-15T21:37:53Z",
      "moonrise": "2026-11-15T17:01:14Z",
      "moonset": "2026-11-16T02:49:21Z",
      "moonPhase": 0.196
    },
    {
      "date": "2026-11-16",
      "sunrise": "2026-11-16T11:44:04Z",
      "sunset": "2026-11-16T21:37:05Z",
      "moonrise": "2026-11-16T17:28:05Z",
      "moonset": "2026-11-17T03:52:11Z",
      "moonPhase": 0.226
    }
  ]
}
"""

/// The same shape with every sun and moon time null, as on a polar day.
let skyJSONPolar = """
{
  "zip": "99723",
  "place": { "name": "Utqiagvik", "region": null, "latitude": 71.29, "longitude": -156.79 },
  "timezone": "America/Anchorage",
  "utcOffsetSeconds": -28800,
  "current": {
    "observedAt": "2026-06-21T20:00:00Z",
    "temperatureF": 36.1,
    "weatherCode": 3,
    "cloudCoverPercent": 100,
    "windSpeedMph": 12,
    "windGustsMph": 18,
    "isDay": true
  },
  "days": [
    { "date": "2026-06-21", "sunrise": null, "sunset": null, "moonrise": null, "moonset": null, "moonPhase": 0.24 },
    { "date": "2026-06-22", "sunrise": null, "sunset": null, "moonrise": null, "moonset": null, "moonPhase": 0.27 }
  ]
}
"""

/// The first day of the polar day: the sun rises at 02:40 local (AKDT, UTC-8)
/// on 10 May and does not set again. Observed at noon.
let skyJSONSunriseWithoutSunset = """
{
  "zip": "99723",
  "place": { "name": "Utqiagvik", "region": null, "latitude": 71.29, "longitude": -156.79 },
  "timezone": "America/Anchorage",
  "utcOffsetSeconds": -28800,
  "current": {
    "observedAt": "2026-05-10T20:00:00Z",
    "temperatureF": 21.4,
    "weatherCode": 0,
    "cloudCoverPercent": 10,
    "windSpeedMph": 8,
    "windGustsMph": 12,
    "isDay": true
  },
  "days": [
    { "date": "2026-05-10", "sunrise": "2026-05-10T10:40:00Z", "sunset": null, "moonrise": null, "moonset": null, "moonPhase": 0.8 },
    { "date": "2026-05-11", "sunrise": null, "sunset": null, "moonrise": null, "moonset": null, "moonPhase": 0.83 }
  ]
}
"""

/// The last day of the polar day: no sunrise on 2 August (the sun has been up
/// for weeks) and the first sunset at 23:40 local. Observed at noon.
let skyJSONSunsetWithoutSunrise = """
{
  "zip": "99723",
  "place": { "name": "Utqiagvik", "region": null, "latitude": 71.29, "longitude": -156.79 },
  "timezone": "America/Anchorage",
  "utcOffsetSeconds": -28800,
  "current": {
    "observedAt": "2026-08-02T20:00:00Z",
    "temperatureF": 41.0,
    "weatherCode": 0,
    "cloudCoverPercent": 10,
    "windSpeedMph": 8,
    "windGustsMph": 12,
    "isDay": true
  },
  "days": [
    { "date": "2026-08-02", "sunrise": null, "sunset": "2026-08-03T07:40:00Z", "moonrise": null, "moonset": null, "moonPhase": 0.63 },
    { "date": "2026-08-03", "sunrise": "2026-08-03T10:10:00Z", "sunset": "2026-08-04T07:20:00Z", "moonrise": null, "moonset": null, "moonPhase": 0.66 }
  ]
}
"""

/// Answers `/v1/sky` by zip, so the tests need no server. A zip with no entry
/// gets the API's 404.
struct SkyStubTransport: ClientTransport {
    var responses: [String: String] = ["10001": skyJSON10001]
    /// When set, every request fails as if the server were unreachable.
    var offline = false

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        if offline { throw URLError(.cannotConnectToHost) }
        let path = request.path ?? ""
        let zip = path.components(separatedBy: "zip=").last ?? ""
        var response: HTTPResponse
        let json: String
        if let known = responses[zip] {
            response = HTTPResponse(status: .ok)
            json = known
        } else {
            response = HTTPResponse(status: .notFound)
            json = #"{"error":"unknown_zip","message":"No US place found for zip \#(zip)"}"#
        }
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(json))
    }
}

func stubbedSkyAPI(_ transport: SkyStubTransport = SkyStubTransport()) -> SeasignAPI {
    SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: transport)
}

/// Decodes one of the JSON fixtures the way the app does: through the generated
/// client, then into the app's snapshot.
func snapshot(zip: String = "10001", json: String = skyJSON10001, fetchedAt: Date) async throws -> SkySnapshot {
    let api = stubbedSkyAPI(SkyStubTransport(responses: [zip: json]))
    return SkySnapshot(try await api.sky(zip: zip), fetchedAt: fetchedAt)
}

@MainActor
func inMemoryContext() throws -> ModelContext {
    ModelContext(try SeasignSchema.inMemoryContainer())
}
