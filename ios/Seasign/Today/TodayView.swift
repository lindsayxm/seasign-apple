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
    @Environment(GoogleCalendarModel.self) private var google
    @Environment(FeedModel.self) private var feed
    @Environment(SavedModel.self) private var saved
    @Environment(AISearchModel.self) private var ai
    @Environment(\.scenePhase) private var scenePhase
    /// The phone's 12- or 24-hour setting, for the event times.
    @Environment(\.clockStyle) private var clockStyle

    @State private var destination: Destination?
    /// The headline open in the reading view.
    @State private var reading: FeedEntry?
    /// A calendar pull (events and sky) is running; another one does
    /// nothing until it ends. Independent of the headline pull.
    @State private var isPullingCalendar = false
    /// A headline pull is running; another one does nothing until it ends.
    @State private var isPullingHeadlines = false

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
    /// `-debugPullSpinner 5`: each pull's spinner stays up at least this
    /// many seconds, for screenshots.
    @AppStorage("debugPullSpinner") private var debugPullSpinner = 0.0
    /// `-debugOpenSettings YES`: Settings opens over Today at launch, for
    /// screenshots when UI automation cannot reach the always-moving scene.
    @AppStorage("debugOpenSettings") private var debugOpenSettings = false
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
        #if DEBUG
        .onAppear {
            if debugOpenSettings { destination = .settings }
        }
        #endif
        .task {
            // Headlines at launch and on return to the foreground only (at
            // most every 15 minutes, see `FeedModel.refreshInterval`), not on
            // the minute loop below.
            Task { await feed.refresh() }
            // AI search on the same cadence, in its own task: a slow or
            // failing search never holds up or blanks the followed sites.
            // It sends nothing unless AI search is on and a search is due.
            Task { await ai.refreshIfDue() }
            // Refresh at launch, then whenever the sky (10 minutes) or the
            // pasted-link events (5 minutes, `EventsModel.refreshInterval`)
            // have gone stale. These scheduled checks never send `fresh`, so
            // the API may answer events from its 5-minute cache.
            while !Task.isCancelled {
                await model.refresh()
                await events.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        // Google events: while the app is active and Today itself is on
        // screen, one request for all chosen calendars every 5 seconds, or
        // once a minute while push channels cover them (`GooglePoll`). The
        // task starts again, asking at once, whenever the gate opens (back
        // to the foreground, a sheet closed, a calendar turned on) or the
        // rate changes (each turn looks again at whether the channels are
        // live, so ones that ended speed it back up). No spinner.
        .task(id: googlePoll) {
            guard let interval = googlePoll else { return }
            while !Task.isCancelled {
                google.pollTurn()
                await google.refresh()
                try? await Task.sleep(for: interval)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Notes typed in Saved are written before the app leaves the
            // foreground (Saved does this too; this covers it from the root).
            if phase != .active {
                saved.flushNotes()
            }
            if phase == .active {
                // Pasted-link events 5 minutes old or more are asked for with
                // `force` (read again by the API, not from its cache). Read
                // now, before the sky's request, so an answer to the minute
                // loop's own check landing meanwhile does not hide it.
                let eventsDue = events.isDue
                Task {
                    await model.refresh()
                    await events.refresh(force: eventsDue)
                }
                Task { await feed.refresh() }
                // The Keychain is asked again first: one that could not be
                // read at launch (before the first unlock) may be readable now.
                ai.refreshKeyStatus()
                Task { await ai.refreshIfDue() }
                // Google push channels with under two days left are replaced.
                google.appOpened()
            }
        }
        // Events are asked for in the zip's time zone; when that changes (a
        // zip saved or removed, the first sky after a cache rebuild) they are
        // fetched again.
        .onChange(of: eventZoneID) {
            Task { await events.refresh() }
            Task { await google.refresh(force: true) }
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

    /// A pull on Today (see `TodayPull`). Neither ever starts an AI
    /// search, which spends the user's daily allowance and key.
    ///
    /// - Calendar: the events and the sky are asked for at once, even when
    ///   fresh; a 429's delay still holds either back. No headlines.
    /// - Headlines: the followed sites are asked for at once, even when
    ///   fresh, but not during a 429's delay (unlike "Refresh headlines
    ///   now" in Settings). No events or sky.
    private func pull(_ target: TodayPull.Target) async {
        switch target {
        case .calendar:
            async let calendar: Void = events.refresh(force: true)
            async let googleEvents: Void = google.refresh(force: true)
            async let sky: Void = model.refresh(force: true)
            _ = await (calendar, googleEvents, sky)
        case .headlines:
            await feed.refresh(force: true, waitsOutDelay: true)
        }
    }

    /// Starts `pull(target)` with its spinner up, unless that pull is
    /// already running. The other pull is not held up.
    private func startPull(_ target: TodayPull.Target) {
        switch target {
        case .calendar:
            guard !isPullingCalendar else { return }
            isPullingCalendar = true
        case .headlines:
            guard !isPullingHeadlines else { return }
            isPullingHeadlines = true
        }
        let minimum = spinnerMinimum
        Task {
            async let shown: Void = { try? await Task.sleep(for: minimum) }()
            await pull(target)
            await shown
            switch target {
            case .calendar: isPullingCalendar = false
            case .headlines: isPullingHeadlines = false
            }
        }
    }

    /// How long a pull's spinner stays up at least.
    private var spinnerMinimum: Duration {
        #if DEBUG
        if debugPullSpinner > 0 { return max(TodayPull.minimumSpinner, .seconds(debugPullSpinner)) }
        #endif
        return TodayPull.minimumSpinner
    }

    /// See `TodayPull`. Decided only when the finger lifts, so the screen is
    /// not redrawn during the drag; where the finger went down picks the pull.
    private func pullGesture(horizonY: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: TodayPull.minimumDistance)
            .onEnded { drag in
                if let target = TodayPull.target(start: drag.startLocation, translation: drag.translation, horizonY: horizonY) {
                    startPull(target)
                }
            }
    }

    /// A pull's spinner, centred on `center`; nothing is drawn at rest.
    private func spinner(_ center: CGPoint, label: String) -> some View {
        let side = TodayOverlayLayout.spinnerSide
        return ProgressView()
            .controlSize(.small)
            .tint(Palette.todayText)
            .frame(width: side, height: side)
            .allowsHitTesting(false)
            .accessibilityLabel(label)
            .placed(x: center.x - side / 2, y: center.y - side / 2)
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
                    openSettings: { destination = .settings },
                    refresh: { startPull(.headlines) }
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
                // The headline pull, for VoiceOver, also when the sea is empty.
                .accessibilityAction(named: Text(TodayPull.headlinesActionName)) { startPull(.headlines) }
                .placed(x: layout.allRect.midX - 22, y: layout.allRect.midY - 22)

                // The pulls' spinners, one for each; nothing at rest.
                if isPullingCalendar {
                    spinner(layout.calendarSpinnerCenter, label: "Refreshing calendar and weather")
                }
                if isPullingHeadlines {
                    spinner(layout.headlineSpinnerCenter, label: "Refreshing headlines")
                }
            }
            .simultaneousGesture(pullGesture(horizonY: SceneLayout(size: proxy.size).horizonY))
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
        // The calendar pull, for VoiceOver, which keeps drags for itself.
        .accessibilityAction(named: Text(TodayPull.calendarActionName)) { startPull(.calendar) }
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
        return TodayEvents.labels(
            links: events.upcoming(now: now),
            google: google.upcoming(now: now),
            now: now,
            timeZone: eventZone,
            clock: clockStyle
        )
    }

    /// How often Today polls Google now, or nil when it does not
    /// (`GooglePoll.isOn`, `GoogleCalendarModel.pollInterval`).
    private var googlePoll: Duration? {
        let on = GooglePoll.isOn(
            appActive: scenePhase == .active,
            todayOnScreen: destination == nil && reading == nil,
            canPoll: google.canPoll
        )
        return on ? google.pollInterval : nil
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
///
/// Where the finger went down picks what is refreshed (task 151): above the
/// horizon (the header, the events box, the sky) the calendar and the sky;
/// at or below it (the sea and the article titles) the headlines only.
enum TodayPull {
    enum Target: Equatable {
        /// Events and the sky (temperature, conditions).
        case calendar
        /// The followed sites' headlines.
        case headlines
    }

    /// A drag shorter than this is not watched at all, so taps are never held up.
    static let minimumDistance: CGFloat = 20
    /// How far down the finger must travel before letting go.
    static let distance: CGFloat = 100
    /// The spinner stays at least this long, so a quick answer does not flash.
    static let minimumSpinner: Duration = .milliseconds(600)

    /// The VoiceOver actions that stand in for the two pulls.
    static let calendarActionName = "Refresh calendar and weather"
    static let headlinesActionName = "Refresh headlines"

    /// Whether a drag that ended with this translation is a pull: at least
    /// `distance` down and more down than sideways (twice as much).
    static func isPull(_ translation: CGSize) -> Bool {
        translation.height >= distance && translation.height >= 2 * abs(translation.width)
    }

    /// Which pull a drag that started at `start` (screen points) and ended
    /// with `translation` is: nil when it is not a pull; `.calendar` when it
    /// started above `horizonY`; `.headlines` when at or below it.
    static func target(start: CGPoint, translation: CGSize, horizonY: CGFloat) -> Target? {
        guard isPull(translation) else { return nil }
        return start.y < horizonY ? .calendar : .headlines
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
