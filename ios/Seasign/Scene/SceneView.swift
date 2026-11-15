import SwiftUI

/// The living sky and water, filling whatever space it is given.
///
/// It animates only while something in the scene moves (clouds, stars, wind,
/// rain, snow) and Reduce Motion is off; otherwise it draws one still frame.
/// The sun and moon move because the parent passes a new `SceneState` as the
/// clock advances, not because of this animation.
struct SceneView: View {
    var state: SceneState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Animation time counts from when the scene first appeared.
    @State private var start = Date()

    var body: some View {
        Group {
            if state.hasMotion && !reduceMotion {
                TimelineView(.animation(minimumInterval: state.hasFastMotion ? 1.0 / 30 : 1.0 / 10)) { timeline in
                    canvas(phase: max(0.001, timeline.date.timeIntervalSince(start)))
                }
            } else {
                canvas(phase: 0)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(state.accessibilityDescription)
        .accessibilityAddTraits(.isImage)
    }

    private func canvas(phase: Double) -> some View {
        let renderer = SceneRenderer(state: state, phase: phase)
        return Canvas(rendersAsynchronously: false) { context, size in
            renderer.draw(in: &context, size: size)
        }
    }
}
