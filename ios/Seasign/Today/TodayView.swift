import SwiftData
import SwiftUI

/// The Today screen: the date, day name and temperature over a living sky and
/// water, with the headlines in the water. It fills the screen and never scrolls.
///
/// Design v12 (`design-ideas/v12-imago/`): v11's scene from `SceneView`,
/// and over it the HUD placed by `TodayOverlayLayout`: the mark, the place
/// and settings, the date tile and events box, the frame round the view,
/// the titles on their plate, the four tiles and the rim. Accent parts read
/// `\.hudAccent`; the mark, date tile, temperature and wind, brackets and
/// the scene's rise and set times stay white.
///
/// Today is one of the four main pages (`MainTabs`). `MainTabsView` keeps
/// it mounted while another page shows; it then pauses its scene, clock,
/// minute loop and Google poll (`TodayActivity`) and resumes them on return.
struct TodayView: View {
    @Environment(TodayModel.self) private var model
    @Environment(EventsModel.self) private var events
    @Environment(GoogleCalendarModel.self) private var google
    @Environment(FeedModel.self) private var feed
    @Environment(SavedModel.self) private var saved
    @Environment(AISearchModel.self) private var ai
    @Environment(\.scenePhase) private var scenePhase
    /// The user's store, for the read-aloud voice (task 172).
    @Environment(\.modelContext) private var modelContext
    /// The phone's 12- or 24-hour setting, for the event times.
    @Environment(\.clockStyle) private var clockStyle
    @Environment(\.hudAccent) private var accent
    /// The page showing; Today pauses while it is another one.
    @Environment(MainTabs.self) private var tabs

    @State private var destination: Destination?
    /// The headline open in the reading view.
    @State private var reading: FeedEntry?
    /// A calendar pull (events and sky) is running; another one does
    /// nothing until it ends. Independent of the headline pull.
    @State private var isPullingCalendar = false
    /// A headline pull is running; another one does nothing until it ends.
    @State private var isPullingHeadlines = false
    /// The day screen's confirmed draft and its event id, kept while the app
    /// runs so a Try again from a reopened day screen sends the same id.
    @State private var addPending = AddEventPending()
    /// The star dragged from the SAVE tile, while it is out.
    @State private var starFlight = StarFlight()
    /// Counts titles saved from the star, for the success haptic.
    @State private var starSaves = 0

    #if DEBUG
    @AppStorage(SceneDebugOverride.timeKey) private var debugTime = ""
    @AppStorage(SceneDebugOverride.moonKey) private var debugMoon = ""
    @AppStorage(SceneDebugOverride.weatherKey) private var debugWeather = ""
    /// `-debugMockupEvents YES`: the v12 mockup's four events, for
    /// screenshots to set beside its stills.
    @AppStorage("debugMockupEvents") private var debugMockupEvents = false
    /// `-debugEventTitles "Dentist|A long title…"`: other titles for those
    /// events, one to four, separated by `|`; `none` for none.
    @AppStorage("debugEventTitles") private var debugEventTitles = ""
    /// `-debugPlace Chicago`: this place name in the top row, and no zip
    /// prompt, for screenshots on a simulator with no zip saved.
    @AppStorage("debugPlace") private var debugPlace = ""
    /// `-debugPullSpinner 5`: each pull's spinner stays up at least this
    /// many seconds, for screenshots.
    @AppStorage("debugPullSpinner") private var debugPullSpinner = 0.0
    /// `-debugOpenSettings YES`: Settings opens over Today at launch, for
    /// screenshots when UI automation cannot reach the always-moving scene.
    @AppStorage("debugOpenSettings") private var debugOpenSettings = false
    /// `-debugOpenDay YES`: the day screen opens over Today at launch.
    @AppStorage("debugOpenDay") private var debugOpenDay = false
    #endif

    /// The covers Today opens. List, Saved and Listen are pages beside it
    /// (`MainTabs`), and History opens from Saved.
    enum Destination: String, Identifiable {
        case settings, day
        var id: String { rawValue }
    }

    var body: some View {
        // The clock: re-reads the time often enough for the sun to creep along
        // its arc. The scene's own animation is separate (see `SceneView`).
        TimelineView(TodayClockSchedule(paused: !activity.animates)) { timeline in
            content(clock: timeline.date)
        }
        .preferredColorScheme(.dark)
        // Behind another page no tap, pull or star drag reaches Today.
        .allowsHitTesting(activity.takesTouches)
        // The scene's phase as Today appears, before the minute loop's
        // first turn; later changes are passed on below.
        .onAppear { events.setAppActive(scenePhase == .active) }
        #if DEBUG
        .onAppear {
            if debugOpenSettings { destination = .settings }
            if debugOpenDay { destination = .day }
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
        }
        // Refresh at launch, then whenever the sky (10 minutes) or the
        // pasted-link events (5 minutes, `EventsModel.refreshInterval`)
        // have gone stale. These scheduled checks never send `fresh`, so
        // the API may answer events from its 5-minute cache. The loop stops
        // while another page shows and starts again, checking at once, when
        // Today comes back (`TodayActivity.refreshLoopRuns`).
        .task(id: activity.refreshLoopRuns) {
            guard activity.refreshLoopRuns else { return }
            while !Task.isCancelled {
                await model.refresh()
                await events.refresh(force: EventsRefreshTrigger.minuteLoop.force)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        // Google events: while the app is active and Today itself is on
        // screen (its page showing, no cover over it), one request for all chosen calendars every 5 seconds, or
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
        // A star left out by a drag the system cancelled goes back when the
        // app leaves the foreground or a cover opens.
        .onChange(of: destination) { _, opened in if opened != nil { starFlight.cancel() } }
        .onChange(of: reading) { _, opened in if opened != nil { starFlight.cancel() } }
        .onChange(of: tabs.showing) { starFlight.cancel() }
        .onChange(of: scenePhase) { _, phase in
            // First: while the scene is not active the minute loop's turn
            // sends no events request (`EventsModel.isAppActive`).
            events.setAppActive(phase == .active)
            if phase != .active { starFlight.cancel() }
            // Notes typed in Saved are written before the app leaves the
            // foreground (Saved does this too; this covers it from the root).
            if phase != .active {
                saved.flushNotes()
            }
            if phase == .active {
                // Pasted-link events 5 minutes old or more are asked for with
                // `force` (read again by the API, not from its cache). Read
                // now, before the sky's request, so an answer to a minute
                // loop turn that runs meanwhile does not hide it. A turn that
                // ran before the scene went active (the process resumes
                // first, and an expired sleep runs then; task 164) sent
                // nothing, as the app was not active.
                let eventsForce = EventsRefreshTrigger.returnToForeground(isDue: events.isDue).force
                Task {
                    await model.refresh()
                    await events.refresh(force: eventsForce)
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
            Task { await events.refresh(force: EventsRefreshTrigger.zoneChange.force) }
            Task { await google.refresh(force: true) }
        }
        .fullScreenCover(item: $destination) { destination in
            switch destination {
            case .settings:
                SettingsView()
            case .day:
                dayView
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
            async let calendar: Void = events.refresh(force: EventsRefreshTrigger.pull.force)
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
            .tint(accent)
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
        let candidates = feed.headlines(now: clock, timeZone: headlineZone)

        return GeometryReader { proxy in
            let layout = TodayOverlayLayout(
                size: proxy.size,
                labels: labels,
                showsZipPrompt: showsZipPrompt,
                cornerRadius: Self.screenCornerRadius(proxy)
            )
            let shown = HeadlinesColumn.shown(candidates, layout: layout)

            ZStack(alignment: .topLeading) {
                SceneView(state: state, paused: !activity.animates)

                topRow(layout: layout)
                dateTile(date, layout: layout)
                EventsColumn(
                    layout: layout,
                    zipPrompt: showsZipPrompt ? { destination = .settings } : nil,
                    openDay: { destination = .day }
                )
                frame(layout: layout, state: state)

                plate(layout: layout)
                HeadlinesColumn(
                    candidates: candidates,
                    layout: layout,
                    followsNoSites: feed.sites.isEmpty,
                    starTarget: starFlight.row(bands: bands(shown, layout: layout)),
                    open: { reading = $0 },
                    openSettings: { destination = .settings },
                    save: { saveFromStar($0) },
                    refresh: { startPull(.headlines) }
                )

                let bar = TodayOverlayLayout.tileBar(screen: proxy.size)
                HUDTileBar(
                    filled: .day,
                    action: { tabs.select($0) },
                    starDrag: HUDTileBar.StarDrag(
                        space: Self.space,
                        changed: { starFlight.move(finger: $0) },
                        ended: { finger in starDropped(finger: finger, shown: shown, layout: layout) },
                        cancelled: { starFlight.cancel() }
                    ),
                    // The headline pull, for VoiceOver, also when the plate
                    // is empty (the titles carry it too).
                    pageActions: [.init(name: TodayPull.headlinesActionName) { startPull(.headlines) }]
                )
                .frame(width: bar.width)
                .placed(x: bar.minX, y: bar.minY)

                layout.rimPath
                    .stroke(accent.opacity(0.85), style: StrokeStyle(lineWidth: TodayOverlayLayout.Mockup.rimLine, lineCap: .round))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                // The star on its way from the SAVE tile to a title.
                if let starPoint = starFlight.star {
                    HUDGlyphView(glyph: .save, color: accent)
                        .scaleEffect(1.3)
                        .shadow(color: .black, radius: 3)
                        .allowsHitTesting(false)
                        .placed(x: starPoint.x - 10, y: starPoint.y - 10)
                }

                // The pulls' spinners, one for each; nothing at rest.
                if isPullingCalendar {
                    spinner(layout.calendarSpinnerCenter, label: "Refreshing calendar and weather")
                }
                if isPullingHeadlines {
                    spinner(layout.headlineSpinnerCenter, label: "Refreshing headlines")
                }
            }
            .coordinateSpace(name: Self.space)
            .simultaneousGesture(pullGesture(horizonY: layout.horizonY))
            .sensoryFeedback(.success, trigger: starSaves)
        }
        .ignoresSafeArea()
    }

    /// The coordinate space of Today's overlay, which fills the screen.
    private static let space = "today"

    /// The radius of the screen's own corners less the rim's inset, where
    /// the system reports it (iOS 27); nil otherwise, and the layout uses
    /// the mockup's 39.
    private static func screenCornerRadius(_ proxy: GeometryProxy) -> CGFloat? {
        if #available(iOS 27.0, *) {
            let inset = TodayOverlayLayout.Mockup.rimInset
            let rect = CGRect(origin: .zero, size: proxy.size).insetBy(dx: inset, dy: inset)
            guard let radii = proxy.concentricCornerRadii(in: rect) else { return nil }
            let radius = min(radii.topLeading, radii.topTrailing, radii.bottomLeading, radii.bottomTrailing)
            return radius > 1 ? radius : nil
        }
        return nil
    }

    /// The zip's place for the top row, or the DEBUG stand-in.
    private var placeName: String? {
        #if DEBUG
        if !debugPlace.isEmpty { return debugPlace }
        #endif
        return model.placeName
    }

    /// No zip is saved (and no DEBUG place stands in for one).
    private var showsZipPrompt: Bool {
        #if DEBUG
        if !debugPlace.isEmpty { return false }
        #endif
        return model.zip == nil
    }

    // MARK: The star

    private func bands(_ shown: [FeedEntry], layout: TodayOverlayLayout) -> [CGRect] {
        shown.indices.map { layout.titleBand($0) }
    }

    /// The finger lifted at `finger`: saves the title under the star,
    /// unless it is saved already.
    private func starDropped(finger: CGPoint, shown: [FeedEntry], layout: TodayOverlayLayout) {
        let outcome = starFlight.land(finger: finger, bands: bands(shown, layout: layout), activity: activity) {
            saved.isSaved(shown[$0].link)
        }
        if case .save(let index) = outcome {
            saveFromStar(shown[index])
        }
    }

    /// Saves `entry` if it is not saved yet (a drop or VoiceOver's Save
    /// never removes one).
    private func saveFromStar(_ entry: FeedEntry) {
        guard !saved.isSaved(entry.link) else {
            AccessibilityNotification.Announcement("Already saved").post()
            return
        }
        if saved.save(ReadingItem(entry)) {
            starSaves += 1
            AccessibilityNotification.Announcement("Saved").post()
        }
    }

    // MARK: Top row, date tile, frame

    /// The mark (white, plain) at the left; the place name and settings in
    /// the accent at the right. (History opens from Saved.)
    private func topRow(layout: TodayOverlayLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: layout.size.width, height: layout.markRect.maxY)
                .allowsHitTesting(false)
            HUDGlyphView(glyph: .mark, color: Palette.white)
                .frame(width: 44, height: 44)
                .allowsHitTesting(false)
                // Decorative: HUDGlyphView is hidden from VoiceOver.
                .placed(x: layout.markRect.midX - 22, y: layout.markRect.midY - 22)

            if let place = placeName {
                Text(hud: place.uppercased(), style: HUDType.place)
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: layout.placeMaxWidth, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: HUDType.place.lineHeight)
                    .accessibilityLabel(Text(verbatim: place))
                    .alignmentGuide(.leading) { $0[.trailing] - layout.placeRight }
                    .alignmentGuide(.top) { _ in -layout.markRect.minY }
            }

            Button {
                destination = .settings
            } label: {
                HUDGlyphView(glyph: .settings, color: accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .placed(x: layout.settingsRect.midX - 22, y: layout.settingsRect.midY - 22)
        }
    }

    /// The white date tile: the weekday at the top, a slash and the date at
    /// the foot. It opens the day screen, like the events box beside it.
    private func dateTile(_ date: HeaderDate, layout: TodayOverlayLayout) -> some View {
        typealias M = TodayOverlayLayout.Mockup
        let tile = layout.dateTile
        let inset = M.tileBorder + M.tilePadding
        let ink = Palette.onAccent
        return Button {
            destination = .day
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: M.tileRadius)
                    .fill(Palette.dateTile)
                Text(hud: date.weekday, style: HUDType.tileLabel)
                    .foregroundStyle(ink)
                    .fixedSize()
                    .frame(height: HUDType.tileLabel.lineHeight)
                    .padding(.leading, inset)
                    .padding(.top, inset)
                HStack(alignment: .bottom, spacing: 0) {
                    Text(hud: "/", style: HUDType.tileFoot)
                    Spacer(minLength: 4)
                    Text(hud: "\(date.month.capitalized) \(date.day)", style: HUDType.tileFoot)
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundStyle(ink)
                .frame(height: HUDType.tileFoot.lineHeight)
                .padding(.horizontal, inset)
                .padding(.bottom, M.tileBorder + M.tileFootBottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(width: tile.width, height: tile.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapOnlyButtonStyle())
        .accessibilityLabel(Text(verbatim: date.spoken))
        .accessibilityHint("Shows all of today's events")
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction { destination = .day }
        // The calendar pull, for VoiceOver, which keeps drags for itself.
        .accessibilityAction(named: Text(TodayPull.calendarActionName)) { startPull(.calendar) }
        .placed(x: tile.minX, y: tile.minY)
    }

    /// The four white corner brackets round the view, the temperature and
    /// wind inside the top left (white) and how long the sun or moon is up
    /// inside the top right (accent). Both labels keep the mockup's dark
    /// shadow: they sit on the sky.
    private func frame(layout: TodayOverlayLayout, state: SceneState) -> some View {
        typealias M = TodayOverlayLayout.Mockup
        let weather = FrameText.weather(state)
        let span = FrameText.span(state)
        let box = layout.frame
        return ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: layout.size.width, height: box.maxY)
            FrameBrackets(arm: M.bracket, line: M.bracketLine)
                .stroke(Color.white.opacity(0.78), lineWidth: M.bracketLine)
                .frame(width: box.width, height: box.height)
                .placed(x: box.minX, y: box.minY)
                .accessibilityHidden(true)
            if let spoken = weather.spoken {
                frameLabel(weather.lines, color: Palette.white, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: spoken))
                    .placed(x: layout.frameLabelLeft, y: layout.frameLabelTop)
            }
            if let spoken = span.spoken {
                frameLabel(span.lines, color: accent, alignment: .trailing)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: spoken))
                    .alignmentGuide(.leading) { $0[.trailing] - layout.frameLabelRight }
                    .alignmentGuide(.top) { _ in -layout.frameLabelTop }
            }
        }
        .allowsHitTesting(false)
    }

    private func frameLabel(_ lines: [String], color: Color, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(hud: line, style: HUDType.frameLabel)
                    .fixedSize()
                    .frame(height: HUDType.frameLabel.lineHeight)
            }
        }
        .foregroundStyle(color)
        // The mockup's `text-shadow: 0 0 6px #000, 0 0 2px #000`.
        .shadow(color: .black, radius: 3)
        .shadow(color: .black, radius: 1)
    }

    /// The dark plate under the titles: rim to rim, from 42 under the
    /// horizon to the rim's bottom, following its corners; its top fades in
    /// over 36 points so the water runs into it.
    private func plate(layout: TodayOverlayLayout) -> some View {
        let plate = layout.plate
        let fade = TodayOverlayLayout.Mockup.plateFade
        let plateColor = Palette.hudPlate
        // The CSS stops: 0 at 0, .22 at 9, .62 at 20, .86 at 29, .93 at 36.
        let stops: [Gradient.Stop] = [(0, 0), (0.22, 9), (0.62, 20), (0.86, 29), (0.93, 36)].map { opacity, y in
            Gradient.Stop(color: plateColor.opacity(opacity), location: y / plate.height)
        }
        return UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: layout.rimRadius,
            bottomTrailingRadius: layout.rimRadius, topTrailingRadius: 0
        )
        .fill(LinearGradient(stops: stops + [Gradient.Stop(color: plateColor.opacity(0.93), location: 1)], startPoint: .top, endPoint: .bottom))
        .frame(width: plate.width, height: max(plate.height, fade))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .placed(x: plate.minX, y: plate.minY)
    }

    /// The next four calendar events, or the DEBUG mockup's four.
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
            clock: clockStyle,
            limit: TodayOverlayLayout.Mockup.eventRows
        )
    }

    /// The day screen, reading in the same zone as Today's events; its +
    /// adds an event in that zone (task 171), and so does its mic (task 172).
    private var dayView: some View {
        let today = model
        let zone: @MainActor () -> TimeZone = {
            EventZone.resolve(zip: today.zip, snapshot: today.snapshot, device: .autoupdatingCurrent)
        }
        let day = DayModel(events: events, google: google, timeZone: zone)
        let adder = AddEventModel(google: google, timeZone: zone, pending: addPending)
        return DayView(model: day, adder: adder, voice: Self.voice(adder: adder, day: day, context: modelContext))
    }

    /// The mic's model: recognition on the phone and the system speaker,
    /// reading in the voice chosen in Settings; today's event titles help
    /// the recognizer with names. In DEBUG, with the Google sample only, the
    /// `-debugVoice…` arguments swap in scripted ones (`VoiceDebug`).
    private static func voice(adder: AddEventModel, day: DayModel, context: ModelContext) -> VoiceEntryModel {
        let voiceIdentifier: @MainActor () -> String? = { SkyStore(context: context).voiceIdentifier }
        let names: @MainActor () -> [String] = { [weak day] in day?.rows(now: Date(), clock: .twelveHour).map(\.label.title) ?? [] }
        #if DEBUG
        if let fakes = VoiceDebug.fakes(adder: adder) {
            return VoiceEntryModel(
                adder: adder, listener: fakes.0, speaker: fakes.1,
                voiceIdentifier: voiceIdentifier, names: names, timing: fakes.2
            )
        }
        #endif
        // Made only when the mic is first tapped (the day screen is built
        // again on every redraw, and only its first models are kept).
        return VoiceEntryModel(
            adder: adder,
            listener: SystemSpeechListener(),
            speaker: SystemSpeechSpeaker(),
            voiceIdentifier: voiceIdentifier,
            names: names
        )
    }

    /// What Today runs now: its page showing or not, a cover over it or
    /// not (`TodayActivity`).
    private var activity: TodayActivity {
        tabs.today(coverOpen: destination != nil || reading != nil, appActive: scenePhase == .active)
    }

    /// How often Today polls Google now, or nil when it does not
    /// (`TodayActivity.pollsGoogle`, `GoogleCalendarModel.pollInterval`).
    private var googlePoll: Duration? {
        activity.pollsGoogle(canPoll: google.canPoll) ? google.pollInterval : nil
    }

    /// The time zone events are asked for and shown in.
    private var eventZone: TimeZone {
        EventZone.resolve(zip: model.zip, snapshot: model.snapshot, device: .current)
    }

    /// The time zone events are asked for, as an identifier to watch for changes.
    private var eventZoneID: String {
        eventZone.identifier
    }

    // MARK: Headlines

    /// The day "since yesterday" is counted in: the zip's time zone when a zip
    /// is set and its sky is known, otherwise the phone's.
    private var headlineZone: TimeZone {
        EventZone.resolve(zip: model.zip, snapshot: model.snapshot, device: .autoupdatingCurrent)
    }
}

/// The frame's four corner brackets, `arm` long, inside a rectangle; the
/// stroke is centred `line / 2` in from the edges so it lies inside.
struct FrameBrackets: Shape {
    var arm: CGFloat
    var line: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: line / 2, dy: line / 2)
        let a = arm - line / 2
        var path = Path()
        for (corner, dx, dy) in [
            (CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
            (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0),
        ] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * a))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * a, y: corner.y))
        }
        return path
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
