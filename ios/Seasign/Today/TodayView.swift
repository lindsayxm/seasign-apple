import SwiftUI

/// Placeholder for the Today screen (task 4). It proves the app reaches the API
/// through the generated client by showing the result of `GET /v1/health`.
struct TodayView: View {
    @State private var model: HealthModel

    init(model: HealthModel = HealthModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Seasign")
                .font(.largeTitle.weight(.semibold))

            switch model.state {
            case .loading:
                ProgressView("Checking the API")
            case .reachable(let service):
                Label("API reachable", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(service)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            case .unreachable(let message):
                Label("API not reachable", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") {
                    Task { await model.load() }
                }
            }
        }
        .padding()
        .task { await model.load() }
    }
}

#Preview {
    TodayView()
}
