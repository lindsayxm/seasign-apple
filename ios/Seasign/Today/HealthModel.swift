import Observation

/// Loads the API health check for the placeholder screen.
@MainActor
@Observable
final class HealthModel {
    enum State: Equatable {
        case loading
        case reachable(service: String)
        case unreachable(message: String)
    }

    private(set) var state: State = .loading
    private let api: SeasignAPI

    init(api: SeasignAPI = SeasignAPI()) {
        self.api = api
    }

    func load() async {
        state = .loading
        do {
            let health = try await api.health()
            state = .reachable(service: health.service)
        } catch {
            state = .unreachable(message: error.localizedDescription)
        }
    }
}
