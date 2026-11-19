import SwiftUI

/// The Today screen: the date, day name and temperature over a living sky and
/// water, with the headlines in the water. It fills the screen and never scrolls.
///
/// Design v11 (`design-ideas/v11-artemis/`): the scene from `SceneView`, and
/// over it the fixed overlay placed by `TodayOverlayLayout` (393 pt wide
/// mockup, scaled with the screen width).
struct TodayView: View {
    @Environment(TodayModel.self) private var model
    @Environment(EventsModel.self) private var events
    @Environment(FeedModel.self) private var feed
    @Environment(SavedModel.self) private var saved
    @Environment(AISearchModel.self) private var ai
    @Environment(\.scenePhase) private var scenePhase
    /// The phone's 12- or 24-hour setting, for the event times.
    @Environment(\.clockStyle) private var clockStyle

    @State private var destination: Destination?
    /// The headline open in the reading view.
    @State private var reading: FeedEntry?

    #if DEBUG
    @AppStorage(SceneDebugOverride.timeKey) private var debugTime = ""
    @AppStorage(SceneDebugOverride.moonKey) private var debugMoon = ""
    @AppStorage(SceneDebugOverride.weatherKey) private var debugWeather = ""
    /// `-debugMockupEvents YES`: the v11 mockup's three events, for
    /// screenshots to set beside its stills.
    @AppStorage("debugMockupEvents") private var debugMockupEvents = false
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
            // Headlines at launch and on return to the foreground only (at
            // most every 15 minutes, see `FeedModel.refreshInterval`), not on
            // the minute loop below.
            Task { await feed.refresh() }
            // AI search on the same cadence, in its own task: a slow or
            // failing search never holds up or blanks the followed sites.
            // It sends nothing unless AI search is on and a search is due.
            Task { await ai.refreshIfDue() }
            // Refresh at launch, then whenever the sky has gone stale.
            while !Task.isCancelled {
                await model.refresh()
                await events.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Notes typed in Saved are written before the app leaves the
            // foreground (Saved does this too; this covers it from the root).
            if phase != .active {
                saved.flushNotes()
            }
            if phase == .active {
                Task {
                    await model.refresh()
                    await events.refresh()
                }
                Task { await feed.refresh() }
                // The Keychain is asked again first: one that could not be
                // read at launch (before the first unlock) may be readable now.
                ai.refreshKeyStatus()
                Task { await ai.refreshIfDue() }
            }
        }
        // Events are asked for in the zip's time zone; when that changes (a
        // zip saved or removed, the first sky after a cache rebuild) they are
        // fetched again.
        .onChange(of: eventZoneID) {
            Task { await events.refresh() }
        }
        .fullScreenCover(item: $destination) { destination in
            switch destination {
            case .settings:
                SettingsView()
            case .doGet:
                DoGetView()
            case .saved:
                SavedView(timeZone: headlineZone)
            case .history:
                HistoryView(timeZone: headlineZone)
            }
        }
        .fullScreenCover(item: $reading) { entry in
            ReadingView(item: ReadingItem(entry), timeZone: headlineZone)
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
        let labels = eventLabels(now: inputs.now)

        return GeometryReader { proxy in
            let layout = TodayOverlayLayout(
                size: proxy.size,
                labels: labels,
                showsZipPrompt: model.zip == nil,
                date: "\(date.month) \(date.day)",
                weekday: date.weekday
            )
            let ink = state.inkColor

            ZStack(alignment: .topLeading) {
                SceneView(state: state)

                header(layout: layout, state: state)
                headerAccessibility(date: date, state: state, layout: layout)

                EventsColumn(
                    layout: layout,
                    ink: ink,
                    zipPrompt: model.zip == nil ? { destination = .settings } : nil
                )

                // The hairline that closes the header.
                Rectangle()
                    .fill(Palette.todayHairline)
                    .frame(width: layout.hairlineX.upperBound - layout.hairlineX.lowerBound, height: 0.5)
                    .placed(x: layout.hairlineX.lowerBound, y: layout.hairlineY - 0.25)
                    .accessibilityHidden(true)

                // The wind, while the sun or moon has no tag to carry it.
                if !state.showsTag, let wind = state.windLabel {
                    Text(today: wind, font: layout.fonts.wind, tracking: TodayOverlayLayout.Fonts.windTracking)
                        .foregroundStyle(Palette.todayWind)
                        .shadow(color: .black, radius: 2.5)
                        .shadow(color: .black, radius: 1)
                        .fixedSize()
                        .accessibilityLabel(Text(verbatim: "Wind \(Int((state.windMph ?? 0).rounded())) miles per hour"))
                        .placed(x: layout.leftX, baseline: layout.windBaseline)
                }

                iconButton(.settings, label: "Settings", opens: .settings, layout: layout, ink: ink, at: 0)
                iconButton(.doGet, label: "Do and get lists", opens: .doGet, layout: layout, ink: ink, at: 1)
                iconButton(.saved, label: "Saved", opens: .saved, layout: layout, ink: ink, at: 2)

                HeadlinesColumn(
                    candidates: feed.headlines(now: clock, timeZone: headlineZone),
                    layout: layout,
                    followsNoSites: feed.sites.isEmpty,
                    ink: ink,
                    open: { reading = $0 },
                    openSettings: { destination = .settings }
                )

                // ∀, for all publications: the 7-day history.
                Button {
                    destination = .history
                } label: {
                    LineIconView(icon: .allPublications, size: layout.allRect.width, lineWidth: 0.13 * layout.allRect.width)
                        .foregroundStyle(ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Last 7 days")
                .placed(x: layout.allRect.midX - 22, y: layout.allRect.midY - 22)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Header

    /// The left column: date, day name and temperature, all white.
    private func header(layout: TodayOverlayLayout, state: SceneState) -> some View {
        typealias F = TodayOverlayLayout.Fonts
        return Group {
            Text(today: layout.dateText, font: layout.fonts.date, tracking: F.dateTracking)
                .foregroundStyle(Palette.todayText)
                .fixedSize()
                .placed(x: layout.leftX, baseline: layout.dateBaseline)
            Text(today: layout.dayText, font: layout.dayFont, tracking: F.dayTracking)
                .foregroundStyle(Palette.todayText)
                .fixedSize()
                // The mockup's soft white glow.
                .shadow(color: Palette.todayText.opacity(0.45), radius: 5 * layout.scale)
                .shadow(color: Palette.todayText.opacity(0.35), radius: 1 * layout.scale)
                .placed(x: layout.leftX, baseline: layout.dayBaseline)
            if let temperature = state.temperatureF {
                Text(today: "\(Int(temperature.rounded()))°F", font: layout.fonts.temperature, tracking: F.temperatureTracking)
                    .foregroundStyle(Palette.todayText)
                    .fixedSize()
                    .placed(x: layout.leftX, baseline: layout.temperatureBaseline)
            }
        }
        // A Group passes modifiers to each child, so the texts are hidden
        // and one clear element over them carries the spoken date.
        .accessibilityHidden(true)
    }

    private func headerAccessibility(date: HeaderDate, state: SceneState, layout: TodayOverlayLayout) -> some View {
        let top = layout.dateBaseline - layout.fonts.date.capHeight
        return Color.clear
            .frame(width: 56 * layout.scale, height: layout.temperatureBaseline - top + 4 * layout.scale)
            .accessibilityElement()
            .accessibilityLabel(headerLabel(date: date, state: state))
            .accessibilityAddTraits(.isHeader)
            .placed(x: layout.leftX, y: top)
    }

    private func headerLabel(date: HeaderDate, state: SceneState) -> String {
        if let temperature = state.temperatureF {
            return "\(date.spoken), \(Int(temperature.rounded())) degrees Fahrenheit"
        }
        return date.spoken
    }

    /// The next three calendar events, or the DEBUG mockup's three.
    private func eventLabels(now: Date) -> [EventLabel] {
        #if DEBUG
        if debugMockupEvents {
            return EventLabel.mockupSamples(now: now, timeZone: eventZone, clock: clockStyle)
        }
        #endif
        return events.labels(now: now, clock: clockStyle)
    }

    /// The time zone events are asked for and shown in.
    private var eventZone: TimeZone {
        EventZone.resolve(zip: model.zip, snapshot: model.snapshot, device: .current)
    }

    /// The time zone events are asked for, as an identifier to watch for changes.
    private var eventZoneID: String {
        eventZone.identifier
    }

    /// One of the three buttons hung from the hairline: a 19-point line icon
    /// at 38 % of the ink colour, in a 44-point target.
    private func iconButton(
        _ icon: LineIcon, label: String, opens target: Destination,
        layout: TodayOverlayLayout, ink: Color, at index: Int
    ) -> some View {
        let center = layout.buttonCenters[index]
        return Button {
            destination = target
        } label: {
            LineIconView(icon: icon, size: layout.iconSize, lineWidth: 0.09 * layout.iconSize)
                .foregroundStyle(ink.opacity(0.38))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .placed(x: center.x - 22, y: center.y - 22)
    }

    // MARK: Headlines

    /// The day "since yesterday" is counted in: the zip's time zone when a zip
    /// is set and its sky is known, otherwise the phone's.
    private var headlineZone: TimeZone {
        EventZone.resolve(zip: model.zip, snapshot: model.snapshot, device: .autoupdatingCurrent)
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
