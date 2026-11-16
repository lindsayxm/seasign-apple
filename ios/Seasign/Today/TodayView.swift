import SwiftUI

/// The Today screen: the date, day name and temperature over a living sky and
/// water, with the headlines in the water. It fills the screen and never scrolls.
///
/// Positions are measured from `ref-img/02-midday.png` (393 pt wide) and scale
/// with the screen width; see `SceneLayout`.
struct TodayView: View {
    @Environment(TodayModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var destination: Destination?
    /// Width of the day name as laid out, which positions the vertical rule.
    @State private var dayNameWidth: CGFloat = 90

    #if DEBUG
    @AppStorage(SceneDebugOverride.timeKey) private var debugTime = ""
    @AppStorage(SceneDebugOverride.moonKey) private var debugMoon = ""
    @AppStorage(SceneDebugOverride.weatherKey) private var debugWeather = ""
    #endif

    enum Destination: String, Identifiable {
        case settings, doGet, saved, history
        var id: String { rawValue }
    }

    var body: some View {
        // The clock: re-reads the time often enough for the sun to creep along
        // its arc. The scene's own animation is separate (see `SceneView`).
        TimelineView(.periodic(from: .now, by: 20)) { timeline in
            content(clock: timeline.date)
        }
        .preferredColorScheme(.dark)
        .task {
            // Refresh at launch, then whenever the sky has gone stale.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.refresh() }
            }
        }
        .fullScreenCover(item: $destination) { destination in
            switch destination {
            case .settings:
                SettingsView()
            case .doGet:
                DoGetView()
            case .saved:
                PlaceholderScreen(title: "Saved", note: "Saved publications will live here.")
            case .history:
                PlaceholderScreen(title: "Last 7 days", note: "Everything that has been in your feed will live here.")
            }
        }
    }

    /// The sky and clock to draw: the real ones, or the debug override's.
    private func inputs(clock: Date) -> (snapshot: SkySnapshot?, now: Date) {
        #if DEBUG
        let override = SceneDebugOverride(time: debugTime, moon: debugMoon, weather: debugWeather)
        return override.apply(to: model.snapshot, now: clock, deviceTimeZone: .current)
        #else
        return (model.snapshot, clock)
        #endif
    }

    private func content(clock: Date) -> some View {
        let inputs = inputs(clock: clock)
        let state = SceneState.make(snapshot: inputs.snapshot, now: inputs.now, deviceTimeZone: .current)
        let date = HeaderDate(now: inputs.now, timeZone: state.timeZone)

        return GeometryReader { proxy in
            let layout = SceneLayout(size: proxy.size)
            let s = layout.scale
            let ruleX = 57.8 * s + dayNameWidth + 9.8 * s

            ZStack(alignment: .topLeading) {
                SceneView(state: state)

                header(date: date, state: state, s: s)
                headerAccessibility(date: date, state: state, s: s)

                // Vertical rule between the date and the events column.
                Rectangle()
                    .fill(Palette.rule)
                    .frame(width: 1, height: 99 * s)
                    .placed(x: ruleX, y: 67 * s)

                eventsColumn
                    .frame(width: max(0, 345 * s - ruleX - 14 * s), alignment: .leading)
                    .placed(x: ruleX + 14 * s, y: 72 * s)

                // Horizontal rule under the header.
                Rectangle()
                    .fill(Palette.rule)
                    .frame(width: 297 * s, height: 1)
                    .placed(x: 48 * s, y: 193 * s)

                iconButton(.settings, label: "Settings", opens: .settings, s: s)
                    .placed(x: 333 * s - 22, y: 217 * s - 22)
                iconButton(.doGet, label: "Do and get lists", opens: .doGet, s: s)
                    .placed(x: 333 * s - 22, y: 261 * s - 22)
                iconButton(.saved, label: "Saved", opens: .saved, s: s)
                    .placed(x: 333 * s - 22, y: 306 * s - 22)

                headlines(s: s)
                    .frame(
                        width: 326 * s,
                        height: max(0, proxy.size.height - 52 * s - (layout.horizonY + 57 * s)),
                        alignment: .topLeading
                    )
                    .placed(x: 35 * s, y: layout.horizonY + 57 * s)

                Button {
                    destination = .history
                } label: {
                    LineIconView(icon: .history, size: 13 * s, lineWidth: 1.5 * s)
                        .foregroundStyle(Palette.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Last 7 days")
                .placed(x: 35 * s - (44 - 13 * s) / 2, y: proxy.size.height - 29 * s - 22)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Header

    private func header(date: HeaderDate, state: SceneState, s: CGFloat) -> some View {
        Group {
            Text(caps: date.month)
                .caps(10.5 * s, medium: true, tracking: 0.1)
                .foregroundStyle(Palette.dimText)
                .placed(x: 61 * s, baseline: 66 * s)
            Text(caps: date.day)
                .caps(11.5 * s, medium: true, tracking: 0.03)
                .foregroundStyle(Palette.white)
                .placed(x: 102 * s, baseline: 66 * s)
            SoftenedText(text: date.weekday, font: .dayName(69.7 * s), softness: 1.15 * s)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { dayNameWidth = $0 }
                .placed(x: 57.8 * s, baseline: 130 * s)
            if let temperature = state.temperatureF {
                Text(caps: "\(Int(temperature.rounded()))°F")
                    .caps(14 * s, medium: true, tracking: 0.05)
                    .foregroundStyle(Palette.white)
                    .placed(x: 64 * s, baseline: 166 * s)
            }
        }
        // A Group passes modifiers to each child, so the four texts are hidden
        // and one clear element over them carries the spoken date.
        .accessibilityHidden(true)
    }

    private func headerAccessibility(date: HeaderDate, state: SceneState, s: CGFloat) -> some View {
        Color.clear
            .frame(width: 120 * s, height: 114 * s)
            .accessibilityElement()
            .accessibilityLabel(headerLabel(date: date, state: state))
            .accessibilityAddTraits(.isHeader)
            .placed(x: 57 * s, y: 56 * s)
    }

    private func headerLabel(date: HeaderDate, state: SceneState) -> String {
        if let temperature = state.temperatureF {
            return "\(date.spoken), \(Int(temperature.rounded())) degrees Fahrenheit"
        }
        return date.spoken
    }

    /// Task 6 puts the next three calendar events here. Until a zip is set it
    /// holds a quiet prompt.
    @ViewBuilder private var eventsColumn: some View {
        if model.zip == nil {
            Button {
                destination = .settings
            } label: {
                Text(caps: "Set your zip code in Settings")
                    .caps(9.5, tracking: 0.18)
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(Palette.dimText)
                    .frame(minHeight: 44, alignment: .topLeading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Settings")
        }
    }

    private func iconButton(_ icon: LineIcon, label: String, opens target: Destination, s: CGFloat) -> some View {
        Button {
            destination = target
        } label: {
            LineIconView(icon: icon, size: 19.5 * s, lineWidth: 1.7 * s)
                .foregroundStyle(Palette.rule)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Headlines

    /// As many of the newest headlines as fit above the `>>` button, most first.
    private func headlines(s: CGFloat) -> some View {
        let all = PlaceholderHeadlines.all
        return ViewThatFits(in: .vertical) {
            ForEach([5, 4, 3, 2, 1], id: \.self) { count in
                VStack(alignment: .leading, spacing: 28.5 * s) {
                    ForEach(all.prefix(count), id: \.self) { headline in
                        WrappedCaps(
                            text: headline,
                            size: 11.2 * s,
                            tracking: 0.185,
                            linePitch: 14.5 * s,
                            width: 326 * s
                        )
                        .foregroundStyle(Palette.ink)
                    }
                }
            }
        }
    }
}

extension View {
    /// Puts the view's top-left corner at (`x`, `y`) inside a top-leading `ZStack`.
    func placed(x: CGFloat, y: CGFloat) -> some View {
        alignmentGuide(.leading) { _ in -x }
            .alignmentGuide(.top) { _ in -y }
    }

    /// Puts the view's leading edge at `x` and its first text baseline at
    /// `baseline` inside a top-leading `ZStack`.
    func placed(x: CGFloat, baseline: CGFloat) -> some View {
        alignmentGuide(.leading) { _ in -x }
            .alignmentGuide(.top) { dimensions in dimensions[.firstTextBaseline] - baseline }
    }
}
