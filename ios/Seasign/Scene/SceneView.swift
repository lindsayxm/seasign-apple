import SwiftUI

/// The living sky and sea, filling whatever space it is given.
///
/// Something always moves in the v11 scene (the sun's face, the stars, the
/// glints and the grain), so it redraws 30 times a second. With Reduce Motion
/// on it draws one still frame. The sun and moon move along their path
/// because the parent passes a new `SceneState` as the clock advances, not
/// because of this animation.
struct SceneView: View {
    var state: SceneState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The phone's 12- or 24-hour setting, for the rise and set times.
    @Environment(\.clockStyle) private var clockStyle
    /// Animation time counts from when the scene first appeared.
    @State private var start = Date()

    static let frameInterval: TimeInterval = 1.0 / 30

    var body: some View {
        Group {
            if reduceMotion {
                canvas(time: SceneRenderer.stillTime)
            } else {
                TimelineView(.animation(minimumInterval: Self.frameInterval)) { timeline in
                    canvas(time: SceneRenderer.stillTime + timeline.date.timeIntervalSince(start))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(state.accessibilityDescription)
        .accessibilityAddTraits(.isImage)
    }

    private func canvas(time: Double) -> some View {
        let renderer = SceneRenderer(
            state: state,
            clock: clockStyle,
            time: time,
            grain: SceneImages.grain,
            moonFace: state.body?.kind == .moon ? SceneImages.moonFace(phase: state.moonPhase) : nil
        )
        return Canvas(rendersAsynchronously: false) { context, size in
            renderer.draw(in: &context, size: size)
        }
    }
}
