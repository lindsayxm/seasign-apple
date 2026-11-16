import Foundation
import Observation
import SwiftData

/// Owns the zip and the sky for the Today screen: shows the cached sky at once,
/// then refreshes it from `GET /v1/sky`.
@MainActor
@Observable
final class TodayModel {
    /// Why a zip typed in Settings was not saved.
    enum ZipProblem: Error, Equatable {
        case notFiveDigits
        case unknown
        case unavailable
        /// The API's per-network limit refused the check.
        case rateLimited

        var message: String {
            switch self {
            case .notFiveDigits:
                "Enter a 5-digit US zip code."
            case .unknown:
                "We couldn't find that zip code. Try a nearby one."
            case .unavailable:
                "We couldn't check that zip code. Check your connection and try again."
            case .rateLimited:
                ServerRateLimit.message
            }
        }
    }

    /// The saved zip, nil until the user sets one.
    private(set) var zip: String?
    /// The latest sky for `zip`, from the cache or the network.
    private(set) var snapshot: SkySnapshot?
    /// The API's rate limit asked to wait until then: refreshes are not
    /// sent before it (the zip check in Settings still is).
    @ObservationIgnored private(set) var retryNotBefore: Date?

    private let api: SeasignAPI
    private let store: SkyStore
    private let now: @Sendable () -> Date

    /// A response younger than this is not fetched again. The API caches
    /// forecasts for 15 minutes, so asking more often returns the same data.
    static let refreshInterval: TimeInterval = 10 * 60

    init(
        api: SeasignAPI = SeasignAPI(),
        context: ModelContext,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.store = SkyStore(context: context)
        self.now = now
        zip = store.zip
        if let zip {
            snapshot = store.cachedSky(for: zip)
        }
    }

    /// "New York, New York", for Settings.
    var placeDescription: String? {
        guard let snapshot, snapshot.zip == zip else { return nil }
        if let region = snapshot.region, !region.isEmpty {
            return "\(snapshot.placeName), \(region)"
        }
        return snapshot.placeName
    }

    /// Fetches the sky for the saved zip unless the current one is fresh. On
    /// failure the cached sky stays on screen; after the API's rate limit
    /// (429) nothing is asked again until its delay has passed.
    func refresh(force: Bool = false) async {
        guard let zip else { return }
        if !force, let snapshot, now().timeIntervalSince(snapshot.fetchedAt) < Self.refreshInterval {
            return
        }
        if let retryNotBefore, now() < retryNotBefore { return }
        let sky: Components.Schemas.Sky
        do {
            sky = try await api.sky(zip: zip)
        } catch {
            holdIfRateLimited(error)
            return
        }
        retryNotBefore = nil
        // The zip may have changed while the request was in flight.
        guard zip == self.zip else { return }
        let fresh = SkySnapshot(sky, fetchedAt: now())
        snapshot = fresh
        store.cache(fresh)
    }

    /// Checks a zip typed in Settings against the API and saves it. Throws a
    /// `ZipProblem`, leaving the previous zip and sky in place.
    func saveZip(_ text: String) async throws {
        let candidate = text.trimmingCharacters(in: .whitespaces)
        guard Self.isValidZip(candidate) else { throw ZipProblem.notFiveDigits }
        let sky: Components.Schemas.Sky
        do {
            sky = try await api.sky(zip: candidate)
        } catch SeasignAPI.SkyFailure.unknownZip {
            throw ZipProblem.unknown
        } catch SeasignAPI.SkyFailure.invalidZip {
            throw ZipProblem.notFiveDigits
        } catch SeasignAPI.SkyFailure.rateLimited(let seconds) {
            hold(seconds)
            throw ZipProblem.rateLimited
        } catch {
            throw ZipProblem.unavailable
        }
        retryNotBefore = nil
        let fresh = SkySnapshot(sky, fetchedAt: now())
        store.setZip(candidate)
        store.cache(fresh)
        zip = candidate
        snapshot = fresh
    }

    /// Forgets the zip; Today goes back to the neutral scene.
    func clearZip() {
        store.setZip(nil)
        zip = nil
        snapshot = nil
    }

    private func holdIfRateLimited(_ error: any Error) {
        if case .rateLimited(let seconds)? = error as? SeasignAPI.SkyFailure { hold(seconds) }
    }

    private func hold(_ seconds: Int) {
        retryNotBefore = now().addingTimeInterval(TimeInterval(seconds))
    }

    static func isValidZip(_ text: String) -> Bool {
        text.utf8.count == 5 && text.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }
}
