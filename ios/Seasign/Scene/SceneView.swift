import SwiftUI

/// The living sky and water, filling whatever space it is given.
///
/// It redraws only as often as what moves in the scene needs (`SceneMotion`):
/// 30 frames a second for rain, snow and wind, 10 for drifting clouds, and one
/// redraw every few seconds on a clear night, when only the stars change. With
/// nothing moving, or with Reduce Motion on, it draws one still frame.
/// The sun and moon move because the parent passes a new `SceneState` as the
/// clock advances, not because of this animation.
struct SceneView: View {
    var state: SceneState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Animation time counts from when the scene first appeared.
    @State private var start = Date()

    var body: some View {
        Group {
            switch reduceMotion ? .still : state.motion {
            case .still:
                canvas(phase: 0)
            case .twinkle:
                // A plain timer, not an animation: nothing runs between ticks.
                TimelineView(.periodic(from: start, by: SceneMotion.twinkle.interval ?? 3)) { timeline in
                    canvas(phase: max(0.001, timeline.date.timeIntervalSince(start)))
                }
            case .slow, .fast:
                TimelineView(.animation(minimumInterval: state.motion.interval)) { timeline in
                    canvas(phase: max(0.001, timeline.date.timeIntervalSince(start)))
                }
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
