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
    /// A pull to refresh is running; another pull does nothing until it ends.
    @State private var isPulling = false

    #if DEBUG
    @AppStorage(SceneDebugOverride.timeKey) private var debugTime = ""
    @AppStorage(SceneDebugOverride.moonKey) private var debugMoon = ""
    @AppStorage(SceneDebugOverride.weatherKey) private var debugWeather = ""
    /// `-debugMockupEvents YES`: the v11 mockup's three events, for
    /// screenshots to set beside its stills.
    @AppStorage("debugMockupEvents") private var debugMockupEvents = false
    /// `-debugEventTitles "Dentist|A long title…"`: other titles for those
    /// events, one to three, separated by `|`; `none` for none.
    @AppStorage("debugEventTitles") private var debugEventTitles = ""
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

    /// The pull on Today: the events are asked for at once, even when fresh
    /// (a 429's delay still holds them back); the sky and headlines refresh
    /// under their usual rules. It never starts an AI search, which spends
    /// the user's daily allowance and key.
    private func pull() async {
        async let calendar: Void = events.refresh(force: true)
        async let sky: Void = model.refresh()
        async let headlines: Void = feed.refresh()
        _ = await (calendar, sky, headlines)
    }

    /// Starts `pull()` with the spinner up, unless one is already running.
    private func startPull() {
        guard !isPulling else { return }
        isPulling = true
        Task {
            async let shown: Void = { try? await Task.sleep(for: TodayPull.minimumSpinner) }()
            await pull()
            await shown
            isPulling = false
        }
    }

    /// See `TodayPull`. Decided only when the finger lifts, so the screen is
    /// not redrawn during the drag.
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: TodayPull.minimumDistance)
            .onEnded { drag in
                if TodayPull.isPull(drag.translation) { startPull() }
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

                header(date: date, layout: layout, state: state)

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

                // The wind, whenever there is a fresh reading.
                if let wind = state.windLabel {
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

                // The pull's spinner, in the open sky between the wind line
                // and the buttons; nothing is drawn there at rest.
                if isPulling {
                    ProgressView()
                        .tint(Palette.todayText)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Refreshing")
                        .placed(x: proxy.size.width / 2 - 22, y: layout.windBaseline - 22)
                }
            }
            .simultaneousGesture(pullGesture)
        }
        .ignoresSafeArea()
    }

    // MARK: Header

    /// The left column: date, day name and temperature, all white. One
    /// VoiceOver element, a header, that says the date and temperature in
    /// words; the texts inside it are not read on their own.
    private func header(date: HeaderDate, layout: TodayOverlayLayout, state: SceneState) -> some View {
        typealias F = TodayOverlayLayout.Fonts
        // Local coordinates from the top of the date's line, so no text sits
        // above the container's origin.
        let top = layout.dateBaseline - layout.fonts.date.ascender
        let width = TodayOverlayLayout.Mockup.boxLeft * layout.scale - layout.leftX
        return ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: width, height: layout.temperatureBaseline - top - layout.fonts.temperature.descender)
            Text(today: layout.dateText, font: layout.fonts.date, tracking: F.dateTracking)
                .foregroundStyle(Palette.todayText)
                .fixedSize()
                .placed(x: 0, baseline: layout.dateBaseline - top)
            Text(today: layout.dayText, font: layout.dayFont, tracking: F.dayTracking)
                .foregroundStyle(Palette.todayText)
                .fixedSize()
                // The mockup's soft white glow.
                .shadow(color: Palette.todayText.opacity(0.45), radius: 5 * layout.scale)
                .shadow(color: Palette.todayText.opacity(0.35), radius: 1 * layout.scale)
                .placed(x: 0, baseline: layout.dayBaseline - top)
            if let temperature = state.temperatureF {
                Text(today: "\(Int(temperature.rounded()))°F", font: layout.fonts.temperature, tracking: F.temperatureTracking)
                    .foregroundStyle(Palette.todayText)
                    .fixedSize()
                    .placed(x: 0, baseline: layout.temperatureBaseline - top)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: headerLabel(date: date, state: state)))
        .accessibilityAddTraits(.isHeader)
        // The pull, for VoiceOver, which keeps drags for itself.
        .accessibilityAction(named: Text("Refresh")) { startPull() }
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
        if debugMockupEvents || !debugEventTitles.isEmpty {
            let titles = debugEventTitles.isEmpty
                ? EventLabel.mockupTitles
                : debugEventTitles.split(separator: "|").map(String.init).filter { $0 != "none" }
            return EventLabel.mockupSamples(now: now, timeZone: eventZone, clock: clockStyle, titles: titles)
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

/// Pull down on Today to refresh. Today never scrolls, so the pull is a drag
/// watched alongside the screen's own taps (`simultaneousGesture`): nothing
/// moves while the finger is down, a short drag or a tap does nothing, and
/// the refresh starts when a long, mostly downward drag is let go. (A
/// `.refreshable` scroll view laid under the overlay took the drag but never
/// refreshed; see task 150.)
enum TodayPull {
    /// A drag shorter than this is not watched at all, so taps are never held up.
    static let minimumDistance: CGFloat = 20
    /// How far down the finger must travel before letting go.
    static let distance: CGFloat = 100
    /// The spinner stays at least this long, so a quick answer does not flash.
    static let minimumSpinner: Duration = .milliseconds(600)

    /// Whether a drag that ended with this translation is a pull: at least
    /// `distance` down and more down than sideways (twice as much).
    static func isPull(_ translation: CGSize) -> Bool {
        translation.height >= distance && translation.height >= 2 * abs(translation.width)
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
