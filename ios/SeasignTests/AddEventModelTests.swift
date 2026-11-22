import Foundation
import HTTPTypes
import SwiftData
import Testing

@testable import Seasign

// Task 171: the confirm popup's model and the create call, with Google's
// token endpoint and the API mocked (`FakeGoogleEndpoint`, `GoogleAPIStub`).
// Nothing here reaches Google, and no event is ever created anywhere.

/// Event ids handed out in order: 000…001, 000…002, …
private final class IDSource: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> String {
        lock.withLock {
            count += 1
            return String(format: "%032x", count)
        }
    }

    static func id(_ number: Int) -> String {
        String(format: "%032x", number)
    }
}

@Suite @MainActor struct AddEventModelTests {
    private let endpoint = FakeGoogleEndpoint()
    private let stub = GoogleAPIStub()
    /// Noon on Thursday 19 November 2026 in Chicago.
    private let clock = TestClock(instant("2026-11-19T18:00:00Z"))
    private let zone = TimeZone(identifier: "America/Chicago")!
    private let ids = IDSource()
    /// The user's example: Sunday 22 November at 3 pm in Chicago.
    private let line = "add a meeting to my calendar sunday at 3pm with Rahaf"

    // MARK: Set-up

    private func googleModel(_ context: ModelContext) -> GoogleCalendarModel {
        let clock = clock
        let zone = zone
        return GoogleCalendarModel(
            api: SeasignAPI(serverURL: URL(string: "https://example.test")!, transport: stub),
            context: context,
            config: FakeGoogle.config,
            tokens: InMemoryGoogleTokenStore(),
            http: endpoint.http,
            timeZone: { zone },
            now: { clock.now }
        )
    }

    /// Connected with `scope`; the calendar list has roles unless `roles` is false.
    private func connected(_ context: ModelContext, scope: String = FakeGoogle.allScopes, roles: Bool = true) async -> GoogleCalendarModel {
        endpoint.answer("authorization_code", FakeGoogleEndpoint.tokens(scope: scope))
        endpoint.answer("refresh_token", FakeGoogleEndpoint.tokens(access: FakeGoogle.access2, refresh: nil, scope: scope))
        stub.answer(GoogleAPIStub.getCalendars, GoogleAPIStub.calendars(roles: [
            ("me@example.test", "Me", true, roles ? "owner" : nil),
            ("family-id", "Family", false, roles ? "owner" : nil),
            ("holidays-id", "Holidays", false, roles ? "reader" : nil),
        ]))
        stub.answer(GoogleAPIStub.postEvents, GoogleAPIStub.events([], statuses: [nil]))
        let model = googleModel(context)
        await model.connect { url, scheme in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "\(scheme):/oauth2redirect?state=\(state)&code=\(FakeGoogle.code)")!
        }
        #expect(model.connection == .connected)
        return model
    }

    private func adder(
        _ google: GoogleCalendarModel,
        pending: AddEventPending = AddEventPending(),
        deadline: Duration = .seconds(20)
    ) -> AddEventModel {
        let clock = clock
        let zone = zone
        let ids = ids
        return AddEventModel(
            google: google,
            parser: EventPhraseParser(detector: FakeDateDetector()),
            timeZone: { zone },
            now: { clock.now },
            clock: { .twelveHour },
            makeID: { ids.next() },
            pending: pending,
            sendDeadline: deadline
        )
    }

    /// After a `confirm()` that must send nothing: nothing was started and
    /// the popup did not move, so a send could not be still on its way.
    private func sentNothing(_ adder: AddEventModel, stage: AddEventModel.Stage, _ comment: Comment? = nil) async {
        #expect(adder.sending == nil, comment)
        #expect(adder.stage == stage, comment)
        await settle(adder)
    }

    /// Opens the field with `text` and shows the popup.
    private func review(_ adder: AddEventModel, _ text: String) {
        adder.open(line: text)
        adder.submit()
    }

    /// Waits for the send that is out, at most five seconds.
    private func settle(_ adder: AddEventModel) async {
        guard let task = adder.sending else { return }
        _ = await PushDeadline.race(task, deadline: .seconds(5), fallback: ())
    }

    private func creates() -> [GoogleAPIStub.Seen] {
        stub.seen.filter { $0.operationID == GoogleAPIStub.postCreate }
    }

    private var meeting: EventDraft {
        EventDraft(
            title: "Meeting with Rahaf",
            timing: .timed(start: instant("2026-11-22T21:00:00Z"), end: instant("2026-11-22T22:00:00Z")),
            timeZone: zone
        )
    }

    /// Waits up to five seconds for `condition`.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: Success

    @Test func confirmAddsTheDraftToTheNewEventsCalendarAndSaysSo() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let adder = adder(google)
        var shown: [UpcomingEvent] = []
        adder.onAdded = { shown.append($0) }
        stub.answer(GoogleAPIStub.postCreate, GoogleAPIStub.created(id: IDSource.id(1)))
        let eventsBefore = stub.count(GoogleAPIStub.postEvents)

        review(adder, line)
        #expect(adder.stage == .reviewing(meeting))
        #expect(adder.calendarName == "Me")
        let summary = DraftSummary(meeting, now: clock.now, clock: .twelveHour)
        #expect(summary.day == "Sunday, November 22")
        #expect(summary.time == "3:00 PM – 4:00 PM")
        #expect(summary.length == "1 hour")
        #expect(summary.spoken == "Meeting with Rahaf, Sunday at 3 PM, one hour.")
        #expect(creates().isEmpty)

        adder.confirm()
        #expect(adder.stage == .sending(meeting))
        await settle(adder)

        #expect(adder.stage == .closed)
        #expect(adder.addedNote?.text == "Added · Sun 3:00 PM · Meeting with Rahaf")
        let sent = try #require(creates().first)
        #expect(creates().count == 1)
        #expect(sent.token == FakeGoogle.access)
        #expect(sent.body == [
            "calendar": "me@example.test", "id": IDSource.id(1), "title": "Meeting with Rahaf",
            "timezone": "America/Chicago", "start": "2026-11-22T21:00:00Z", "end": "2026-11-22T22:00:00Z",
        ])
        let primary = try #require(google.newEventsCalendar)
        #expect(shown == [UpcomingEvent(
            link: primary.id, title: "Meeting with Rahaf",
            start: instant("2026-11-22T21:00:00Z"), end: instant("2026-11-22T22:00:00Z"), allDay: false
        )])
        // Today's calendars are read again at once, so Today shows it on return.
        #expect(await eventually { stub.count(GoogleAPIStub.postEvents) > eventsBefore })
        #expect(google.statusProblem == nil)
    }

    @Test func anAllDayDraftIsSentAsADate() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let adder = adder(google)
        stub.answer(GoogleAPIStub.postCreate, GoogleAPIStub.created(id: IDSource.id(1)))
        review(adder, "farmers market saturday")
        adder.confirm()
        await settle(adder)
        #expect(creates().first?.body == [
            "calendar": "me@example.test", "id": IDSource.id(1), "title": "Farmers market",
            "timezone": "America/Chicago", "date": "2026-11-21",
        ])
        #expect(adder.addedNote?.text == "Added · Sat all day · Farmers market")
    }

    @Test func googleAlreadyHavingTheIdShowsTheDraftAsAdded() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let adder = adder(google)
        stub.answer(GoogleAPIStub.postCreate, GoogleAPIStub.created(id: IDSource.id(1), created: false))
        review(adder, line)
        adder.confirm()
        await settle(adder)
        #expect(adder.stage == .closed)
        #expect(adder.addedNote?.text == "Added · Sun 3:00 PM · Meeting with Rahaf")
    }

    @Test func theSampleAccountAddsNothingAndAnswersSuccess() async throws {
        let google = try GoogleCalendarModel.sample(now: clock.now, timeZone: zone)
        let adder = adder(google)
        review(adder, line)
        #expect(adder.calendarName == "Personal")
        adder.confirm()
        await settle(adder)
        #expect(adder.stage == .closed)
        #expect(adder.addedNote?.text == "Added · Sun 3:00 PM · Meeting with Rahaf")
    }

    // MARK: Single flight and the id

    @Test func confirmIsSingleFlight() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let adder = adder(google)
        stub.answer(GoogleAPIStub.postCreate, GoogleAPIStub.created(id: IDSource.id(1)))
        stub.hold(GoogleAPIStub.postCreate)
        review(adder, line)

        adder.confirm()
        adder.confirm()
        await stub.waitUntilParked(GoogleAPIStub.postCreate, count: 1)
        adder.confirm()
        // Cancel and a new entry are ignored while it is out.
        adder.cancel()
        adder.open(line: "something else")
        #expect(adder.stage == .sending(meeting))

        stub.release()
        await settle(adder)
        #expect(creates().count == 1)
        #expect(adder.stage == .closed)
        // Nothing is shown to confirm any more: a late tap sends nothing.
        adder.confirm()
        await sentNothing(adder, stage: .closed)
        #expect(creates().count == 1)
    }

    @Test func aRetryAfterATimeoutSendsTheSameId() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let adder = adder(google)
        stub.answer(
            GoogleAPIStub.postCreate,
            GoogleAPIStub.error(.badGateway, "timeout"),
            GoogleAPIStub.error(.badGateway, "fetch_failed"),
            GoogleAPIStub.created(id: IDSource.id(1), created: false)
        )
        review(adder, line)

        adder.confirm()
        await settle(adder)
        guard case .failed(meeting, let note) = adder.stage else {
            Issue.record("expected a failure, got \(adder.stage)")
            return
        }
        #expect(note.canRetry && !note.opensSettings)
        #expect(note.text.contains("may not have been added"))

        adder.confirm()
        await settle(adder)
        adder.confirm()
        await settle(adder)
        #expect(adder.stage == .closed)
        #expect(creates().map { $0.body["id"] } == Array(repeating: IDSource.id(1), count: 3))
        // Google's failures put nothing on Today's poll.
        #expect(google.statusProblem == nil)
        #expect(google.retryNotBefore == nil)
    }

    @Test func aChangedDraftOrCalendarGetsANewId() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let adder = adder(google)
        stub.answer(GoogleAPIStub.postCreate, GoogleAPIStub.error(.badGateway, "timeout"))
        review(adder, line)
        adder.confirm()
        await settle(adder)

        // The line changed: a new draft, a new id.
        adder.tryAgain()
        #expect(adder.stage == .entering)
        #expect(adder.line == line)
        review(adder, line + " for 2 hours")
        adder.confirm()
        await settle(adder)

        // The same draft to another calendar: a new id.
        let family = try #require(google.newEventsCalendars.first { $0.calendarID == "family-id" })
        google.setNewEventsCalendar(family)
        adder.confirm()
        await settle(adder)

        // The same draft again to that calendar: the same id.
        adder.confirm()
        await settle(adder)

        #expect(creates().map { $0.body["id"] } == [IDSource.id(1), IDSource.id(2), IDSource.id(3), IDSource.id(3)])
        #expect(creates().map { $0.body["calendar"] } == ["me@example.test", "me@example.test", "family-id", "family-id"])
    }

    @Test func anAddedEventsNextDraftGetsANewIdEvenIfTheSame() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let adder = adder(google)
        stub.answer(GoogleAPIStub.postCreate, GoogleAPIStub.created(id: "x"))
        review(adder, line)
        adder.confirm()
        await settle(adder)
        review(adder, line)
        adder.confirm()
        await settle(adder)
        #expect(creates().map { $0.body["id"] } == [IDSource.id(1), IDSource.id(2)])
    }

    // MARK: Errors

    @Test(arguments: [
        (HTTPResponse.Status.forbidden, "insufficient_scope", "Connect again to add events", false, true, "Not added"),
        (.forbidden, "forbidden", "won't take new events in “Me”", false, true, "Not added"),
        (.notFound, "not_found", "couldn't find “Me”", false, true, "Not added"),
        (.badGateway, "rejected", "Google refused this event", false, false, "Not added"),
        (.badRequest, "invalid_request", "couldn't send this event", false, false, "Not added"),
        (.badGateway, "timeout", "may not have been added", true, false, "May not have been added"),
        (.badGateway, "fetch_failed", "may not have been added", true, false, "May not have been added"),
        (.internalServerError, "internal_error", "may not have been added", true, false, "May not have been added"),
        (.tooManyRequests, "rate_limited", "Too many requests", true, false, "Not added"),
    ])
    func eachErrorIsWordedPlainly(_ status: HTTPResponse.Status, _ code: String, _ words: String, _ retry: Bool, _ settings: Bool, _ header: String) async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let adder = adder(google)
        stub.answer(GoogleAPIStub.postCreate, GoogleAPIStub.error(status, code))
        review(adder, line)
        adder.confirm()
        await settle(adder)
        guard case .failed(meeting, let note) = adder.stage else {
            Issue.record("\(code): expected a failure, got \(adder.stage)")
            return
        }
        #expect(note.text.contains(words), "\(code)")
        #expect(note.canRetry == retry, "\(code)")
        #expect(note.opensSettings == settings, "\(code)")
        #expect(note.header == header, "\(code)")
        // A failure that cannot be tried again cannot be confirmed again.
        if !retry {
            let shown = adder.stage
            adder.confirm()
            await sentNothing(adder, stage: shown, "\(code)")
            #expect(creates().count == 1, "\(code)")
        }
        #expect(google.statusProblem == nil, "\(code)")
        #expect(creates().count == 1, "\(code)")
    }

    @Test func ourRateLimitIsHonouredHereAndOnToday() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let adder = adder(google)
        stub.answer(
            GoogleAPIStub.postCreate,
            GoogleAPIStub.error(.tooManyRequests, "rate_limited", retryAfter: "30"),
            GoogleAPIStub.created(id: IDSource.id(1))
        )
        review(adder, line)
        adder.confirm()
        await settle(adder)
        guard case .failed(_, let note) = adder.stage else {
            Issue.record("expected a failure, got \(adder.stage)")
            return
        }
        #expect(note.retryAt == clock.now.addingTimeInterval(30))
        #expect(google.retryNotBefore == clock.now.addingTimeInterval(30))

        // Before the wait is over Try again does nothing.
        clock.advance(29)
        let shown = adder.stage
        adder.confirm()
        await sentNothing(adder, stage: shown)
        #expect(creates().count == 1)

        clock.advance(1)
        adder.confirm()
        await settle(adder)
        #expect(adder.stage == .closed)
        #expect(creates().map { $0.body["id"] } == [IDSource.id(1), IDSource.id(1)])
    }

    @Test func aRefusedTokenIsRenewedOnceAndTheSameIdSent() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let adder = adder(google)
        stub.answer(
            GoogleAPIStub.postCreate,
            GoogleAPIStub.error(.unauthorized, "google_auth"),
            GoogleAPIStub.created(id: IDSource.id(1))
        )
        review(adder, line)
        adder.confirm()
        await settle(adder)
        #expect(adder.stage == .closed)
        #expect(creates().map(\.token) == [FakeGoogle.access, FakeGoogle.access2])
        #expect(creates().map { $0.body["id"] } == [IDSource.id(1), IDSource.id(1)])
    }

    @Test func aTokenRefusedTwiceCanBeTriedAgainLater() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let adder = adder(google)
        stub.answer(GoogleAPIStub.postCreate, GoogleAPIStub.error(.unauthorized, "google_auth"))
        review(adder, line)
        adder.confirm()
        await settle(adder)
        guard case .failed(_, let note) = adder.stage else {
            Issue.record("expected a failure, got \(adder.stage)")
            return
        }
        #expect(note.canRetry)
        #expect(note.text.contains("didn't accept the sign-in"))
        #expect(creates().count == 2)
    }

    @Test func anEndedSignInLeadsToSettings() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let adder = adder(google)
        stub.answer(GoogleAPIStub.postCreate, GoogleAPIStub.error(.unauthorized, "google_auth"))
        endpoint.answer("refresh_token", FakeGoogleEndpoint.error("invalid_grant"))
        review(adder, line)
        adder.confirm()
        await settle(adder)
        guard case .failed(_, let note) = adder.stage else {
            Issue.record("expected a failure, got \(adder.stage)")
            return
        }
        #expect(note.opensSettings && !note.canRetry)
        #expect(google.connection == .expired)
    }

    // MARK: Before Google can take it

    @Test func withoutAConnectionThePopupLeadsToSettings() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let adder = adder(googleModel(context))
        review(adder, line)
        #expect(adder.stage == .blocked(meeting, .connect))
        adder.confirm()
        await sentNothing(adder, stage: .blocked(meeting, .connect))
        #expect(creates().isEmpty)
    }

    @Test func aReadOnlyConnectionAsksToConnectAgain() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context, scope: FakeGoogle.readOnlyScopes)
        let adder = adder(google)
        review(adder, line)
        #expect(adder.stage == .blocked(meeting, .connectAgain))
        #expect(AddEventModel.Block.connectAgain.message.contains("Connect again to add events"))
        adder.confirm()
        await sentNothing(adder, stage: .blocked(meeting, .connectAgain))
        #expect(creates().isEmpty)
    }

    @Test func noKnownCalendarForNewEventsAsksToChooseOne() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context, roles: false)
        #expect(google.canAddEvents && google.newEventsCalendar == nil)
        let adder = adder(google)
        review(adder, line)
        #expect(adder.stage == .blocked(meeting, .chooseCalendar))
        adder.confirm()
        await sentNothing(adder, stage: .blocked(meeting, .chooseCalendar))
        #expect(creates().isEmpty)
    }

    @Test func aLineNotUnderstoodSaysWhyAndKeepsItForTryAgain() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let adder = adder(google)
        review(adder, "tomorrow at 3pm")
        #expect(adder.stage == .problem(.noTitle))
        adder.confirm()
        await sentNothing(adder, stage: .problem(.noTitle))
        #expect(creates().isEmpty)
        adder.tryAgain()
        #expect(adder.stage == .entering)
        #expect(adder.line == "tomorrow at 3pm")
        adder.cancel()
        #expect(adder.stage == .closed)
        #expect(adder.line.isEmpty)
    }

    // MARK: Words

    @Test func theAddedNoteNamesTheDayAndTime() {
        let now = clock.now
        func draft(_ timing: EventDraft.Timing) -> EventDraft {
            EventDraft(title: "Dentist", timing: timing, timeZone: zone)
        }
        let soon = draft(.timed(start: instant("2026-11-20T15:30:00Z"), end: instant("2026-11-20T16:30:00Z")))
        #expect(AddEventModel.addedText(soon, now: now, clock: .twelveHour) == "Added · Fri 9:30 AM · Dentist")
        #expect(AddEventModel.addedText(soon, now: now, clock: .twentyFourHour) == "Added · Fri 09:30 · Dentist")
        let later = draft(.timed(start: instant("2026-12-03T22:00:00Z"), end: instant("2026-12-03T23:00:00Z")))
        #expect(AddEventModel.addedText(later, now: now, clock: .twelveHour) == "Added · Dec 3 4:00 PM · Dentist")
        #expect(AddEventModel.addedText(draft(.allDay(date: "2026-11-19")), now: now, clock: .twelveHour) == "Added · Thu all day · Dentist")
        #expect(DraftSummary.length(minutes: 90) == "1 hour 30 minutes")
        #expect(DraftSummary.length(minutes: 30) == "30 minutes")
        #expect(DraftSummary.length(minutes: 120, words: true) == "2 hours")
        let past = DraftSummary(draft(.timed(start: instant("2026-11-19T15:00:00Z"), end: instant("2026-11-19T16:00:00Z"))), now: now, clock: .twelveHour)
        #expect(past.pastNote == "This time has already passed today.")
        let yesterday = DraftSummary(draft(.allDay(date: "2026-11-18")), now: now, clock: .twelveHour)
        #expect(yesterday.pastNote == "This day has already passed.")
        #expect(DraftSummary(draft(.allDay(date: "2026-11-19")), now: now, clock: .twelveHour).pastNote == nil)
        #expect(DraftSummary(soon, now: now, clock: .twelveHour).pastNote == nil)
    }

    // MARK: Review fixes (task 171, second pass)

    #if DEBUG
    private func debugDefaults(confirm: Bool) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "AddEventDebug-\(UUID().uuidString)"))
        defaults.set(line, forKey: "debugAddEventLine")
        defaults.set(true, forKey: "debugAddEventSubmit")
        defaults.set(confirm, forKey: "debugAddEventConfirm")
        return defaults
    }

    /// B1: the debug launch arguments never reach a real connection.
    @Test func theDebugEntryNeverSendsWithARealConnection() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        #expect(!google.isSample && google.canAddEvents && google.newEventsCalendar != nil)
        let adder = adder(google)
        stub.answer(GoogleAPIStub.postCreate, GoogleAPIStub.created(id: IDSource.id(1)))

        adder.openDebugEntry(defaults: try debugDefaults(confirm: true), confirmDelay: .milliseconds(20))
        #expect(adder.stage == .closed)
        // Well past the confirm delay, with anything it started settled.
        try? await Task.sleep(for: .milliseconds(300))
        await settle(adder)
        #expect(adder.sending == nil)
        #expect(creates().isEmpty)

        // The delayed confirm itself does nothing without the sample, even
        // with a draft on show.
        review(adder, line)
        adder.debugConfirm()
        await sentNothing(adder, stage: .reviewing(meeting))
        #expect(creates().isEmpty)
    }

    @Test func theDebugEntryConfirmsWithTheSample() async throws {
        let google = try GoogleCalendarModel.sample(now: clock.now, timeZone: zone)
        let adder = adder(google)
        adder.openDebugEntry(defaults: try debugDefaults(confirm: true), confirmDelay: .milliseconds(20))
        #expect(adder.stage == .reviewing(meeting))
        #expect(await eventually { adder.addedNote != nil })
        #expect(adder.stage == .closed)
    }
    #endif

    /// B2: the year shows whenever it is not this year in the events' zone.
    @Test func theYearIsShownWhenItIsNotThisYearInTheEventsZone() throws {
        // Sunday 22 November 2026, 1:30 PM in Chicago.
        let now = instant("2026-11-22T19:30:00Z")
        let parser = EventPhraseParser(detector: FakeDateDetector(dates: [("nov 21", 2026, 11, 21), ("12/3/2028", 2028, 12, 3)]))

        // A date without a year that has passed this year rolls to next year.
        guard case .draft(let rolled) = parser.parse("nov 21 dentist", now: now, timeZone: zone) else {
            Issue.record("expected a draft")
            return
        }
        #expect(rolled.timing == .allDay(date: "2027-11-21"))
        let summary = DraftSummary(rolled, now: now, clock: .twelveHour)
        #expect(summary.day == "Sunday, November 21, 2027")
        #expect(summary.spoken == "Dentist, Sunday, November 21, 2027, all day.")
        #expect(AddEventModel.addedText(rolled, now: now, clock: .twelveHour) == "Added · Nov 21, 2027 all day · Dentist")

        // An explicit later year.
        guard case .draft(let later) = parser.parse("dentist 12/3/2028 at 4pm", now: now, timeZone: zone) else {
            Issue.record("expected a draft")
            return
        }
        let laterSummary = DraftSummary(later, now: now, clock: .twelveHour)
        #expect(laterSummary.day == "Sunday, December 3, 2028")
        #expect(laterSummary.time == "4:00 PM – 5:00 PM")
        #expect(laterSummary.spoken == "Dentist, Sunday, December 3, 2028 at 4 PM, one hour.")
        #expect(AddEventModel.addedText(later, now: now, clock: .twelveHour) == "Added · Dec 3, 2028 4:00 PM · Dentist")

        // Across New Year, within six days: still with the year.
        let december = instant("2026-12-29T18:00:00Z")
        let brunch = EventDraft(title: "Brunch", timing: .allDay(date: "2027-01-02"), timeZone: zone)
        #expect(DraftSummary(brunch, now: december, clock: .twelveHour).day == "Saturday, January 2, 2027")
        #expect(AddEventModel.addedText(brunch, now: december, clock: .twelveHour) == "Added · Jan 2, 2027 all day · Brunch")

        // The year is the events' zone's: at 9 PM on 31 December in Chicago
        // it is already 2027 in UTC, and 10 PM that night is still this year.
        let eve = instant("2027-01-01T03:00:00Z")
        let party = EventDraft(title: "Party", timing: .timed(start: instant("2027-01-01T04:00:00Z"), end: instant("2027-01-01T05:00:00Z")), timeZone: zone)
        #expect(DraftSummary(party, now: eve, clock: .twelveHour).day == "Thursday, December 31")
        #expect(DraftSummary(party, now: eve, clock: .twelveHour).spoken == "Party, Thursday at 10 PM, one hour.")
        #expect(AddEventModel.addedText(party, now: eve, clock: .twelveHour) == "Added · Thu 10:00 PM · Party")
        let brunchJan1 = EventDraft(title: "Brunch", timing: .timed(start: instant("2027-01-01T16:00:00Z"), end: instant("2027-01-01T17:00:00Z")), timeZone: zone)
        #expect(DraftSummary(brunchJan1, now: eve, clock: .twelveHour).day == "Friday, January 1, 2027")
        #expect(AddEventModel.addedText(brunchJan1, now: eve, clock: .twelveHour) == "Added · Jan 1, 2027 10:00 AM · Brunch")
    }

    /// (5): a start at midnight says which night it is. Task 172 (b): "friday
    /// 12am" is now the start of Friday, so it is no longer in this list.
    @Test func aMidnightStartSaysWhichNightItIs() {
        let now = instant("2026-11-22T19:30:00Z")
        let parser = EventPhraseParser(detector: FakeDateDetector())
        for line in ["flight friday at midnight", "flight at 12 friday night"] {
            guard case .draft(let draft) = parser.parse(line, now: now, timeZone: zone) else {
                Issue.record("\(line): expected a draft")
                continue
            }
            let summary = DraftSummary(draft, now: now, clock: .twelveHour)
            #expect(summary.day == "Saturday, November 28", "\(line)")
            #expect(summary.time == "12:00 AM – 1:00 AM", "\(line)")
            #expect(summary.midnightNote == "Starts at midnight at the end of Friday, November 27.", "\(line)")
            #expect(summary.spoken == "Flight, Friday at midnight, one hour.", "\(line)")
        }
        #expect(DraftSummary(meeting, now: now, clock: .twelveHour).midnightNote == nil)
    }

    /// Task 172 (b): "12am" with a day named is the start of that day, with
    /// no note; a start after 00:00 put on the next day says so on screen
    /// and aloud; 00:00 without the mark (as typed "00:00") has no note.
    @Test func startsAroundMidnightFollowTheLeadsRuling() {
        let now = instant("2026-11-22T19:30:00Z")
        let parser = EventPhraseParser(detector: FakeDateDetector())
        func summary(_ line: String) -> DraftSummary? {
            guard case .draft(let draft) = parser.parse(line, now: now, timeZone: zone) else { return nil }
            return DraftSummary(draft, now: now, clock: .twelveHour)
        }
        let start = summary("flight friday 12am")
        #expect(start?.day == "Friday, November 27")
        #expect(start?.time == "12:00 AM – 1:00 AM")
        #expect(start?.midnightNote == nil)
        #expect(start?.spoken == "Flight, Friday at 12 AM, one hour.")

        let late = summary("flight friday at 12:30am")
        #expect(late?.day == "Friday, November 27")
        #expect(late?.midnightNote == nil)

        let tonight = summary("party at 12:30am tonight")
        #expect(tonight?.day == "Monday, November 23")
        #expect(tonight?.time == "12:30 AM – 1:30 AM")
        #expect(tonight?.midnightNote == "Starts at 12:30 AM on Monday, November 23, just after Sunday, November 22 ends.")
        #expect(tonight?.spoken == "Party, Monday at 12:30 AM, just after Sunday ends, one hour.")

        let typed = summary("flight 00:00 friday")
        #expect(typed?.day == "Friday, November 27")
        #expect(typed?.midnightNote == nil)
    }

    /// Task 172 (c): the spoken sentence names the date, not only the
    /// weekday, for a day more than six days away (and for a past day).
    @Test func theSpokenSentenceNamesTheDateMoreThanSixDaysAway() {
        // Sunday 22 November 2026, 1:30 PM in Chicago.
        let now = instant("2026-11-22T19:30:00Z")
        let parser = EventPhraseParser(detector: FakeDateDetector(dates: [("Dec 17", 2026, 12, 17), ("Nov 28", 2026, 11, 28), ("Nov 29", 2026, 11, 29)]))
        func spoken(_ line: String) -> String? {
            guard case .draft(let draft) = parser.parse(line, now: now, timeZone: zone) else { return nil }
            return DraftSummary(draft, now: now, clock: .twelveHour).spoken
        }
        #expect(spoken("dentist Dec 17 at 4pm") == "Dentist, Thursday, December 17 at 4 PM, one hour.")
        #expect(spoken("dentist Dec 17") == "Dentist, Thursday, December 17, all day.")
        // Six days away: the weekday; seven: the date.
        #expect(spoken("dentist Nov 28 at 4pm") == "Dentist, Saturday at 4 PM, one hour.")
        #expect(spoken("dentist Nov 29 at 4pm") == "Dentist, Sunday, November 29 at 4 PM, one hour.")
        #expect(spoken("dentist next sunday at 4pm") == "Dentist, Sunday, November 29 at 4 PM, one hour.")
        #expect(spoken("dentist tomorrow at 4pm") == "Dentist, Monday at 4 PM, one hour.")
        // Earlier today and a day past.
        let past = EventDraft(title: "Dentist", timing: .allDay(date: "2026-11-20"), timeZone: zone)
        #expect(DraftSummary(past, now: now, clock: .twelveHour).spoken == "Dentist, Friday, November 20, all day.")
    }

    /// (4): Google saying the sign-in cannot add events drops write access
    /// from the stored scopes; the connection keeps reading, and Settings
    /// (which offers "Connect again to add events" while `canAddEvents` is
    /// false) is no dead end.
    @Test func insufficientScopeDropsWriteAccessSoSettingsOffersConnectAgain() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        #expect(google.canAddEvents)
        let adder = adder(google)
        stub.answer(GoogleAPIStub.postCreate, GoogleAPIStub.error(.forbidden, "insufficient_scope"))
        review(adder, line)
        adder.confirm()
        await settle(adder)

        #expect(google.connection == .connected)
        #expect(!google.canAddEvents)
        let readOnly = GoogleOAuthConfig.split(FakeGoogle.allScopes)?.subtracting([GoogleOAuthConfig.writeScope])
        #expect(google.grantedScopes == readOnly)
        // As stored: the next launch reads the same.
        let relaunched = googleModel(context)
        #expect(relaunched.connection == .connected)
        #expect(!relaunched.canAddEvents)
        // The calendars are still read.
        let before = stub.count(GoogleAPIStub.postEvents)
        await google.refresh(force: true)
        #expect(stub.count(GoogleAPIStub.postEvents) > before)
        #expect(google.statusProblem == nil)
        // The next line asks to connect again instead of sending.
        adder.cancel()
        review(adder, line)
        #expect(adder.stage == .blocked(meeting, .connectAgain))
        #expect(creates().count == 1)
    }

    /// (9): the retry id outlives the day screen within the app run.
    @Test func theRetryIdOutlivesTheDayScreen() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let pending = AddEventPending()
        stub.answer(
            GoogleAPIStub.postCreate,
            GoogleAPIStub.error(.badGateway, "timeout"),
            GoogleAPIStub.created(id: IDSource.id(1), created: false),
            GoogleAPIStub.created(id: IDSource.id(2))
        )
        let first = adder(google, pending: pending)
        review(first, line)
        first.confirm()
        await settle(first)
        guard case .failed = first.stage else {
            Issue.record("expected a failure, got \(first.stage)")
            return
        }
        // The day screen closes and opens again: a new model, the same holder.
        let second = adder(google, pending: pending)
        review(second, line)
        second.confirm()
        await settle(second)
        #expect(second.stage == .closed)
        // Once added, the same line again is a new event.
        let third = adder(google, pending: pending)
        review(third, line)
        third.confirm()
        await settle(third)
        #expect(creates().map { $0.body["id"] } == [IDSource.id(1), IDSource.id(1), IDSource.id(2)])
    }

    @Test func afterReopeningADifferentDraftGetsANewIdAndARefusalClearsIt() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let pending = AddEventPending()
        stub.answer(
            GoogleAPIStub.postCreate,
            GoogleAPIStub.error(.badGateway, "timeout"),
            GoogleAPIStub.error(.badGateway, "rejected"),
            GoogleAPIStub.created(id: "x")
        )
        let first = adder(google, pending: pending)
        review(first, line)
        first.confirm()
        await settle(first)
        // Reopened with another line: a new id; Google refuses it.
        let second = adder(google, pending: pending)
        review(second, line + " for 2 hours")
        second.confirm()
        await settle(second)
        // Reopened with that line again: the refusal cleared it, a new id.
        let third = adder(google, pending: pending)
        review(third, line + " for 2 hours")
        third.confirm()
        await settle(third)
        #expect(creates().map { $0.body["id"] } == [IDSource.id(1), IDSource.id(2), IDSource.id(3)])
    }

    /// (10): no answer by the deadline shows the uncertain state; the late
    /// answer moves nothing, and Try again sends the same id.
    @Test func noAnswerByTheDeadlineSaysItMayNotHaveBeenAdded() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let pending = AddEventPending()
        let adder = adder(google, pending: pending, deadline: .milliseconds(300))
        stub.answer(
            GoogleAPIStub.postCreate,
            GoogleAPIStub.created(id: IDSource.id(1)),
            GoogleAPIStub.created(id: IDSource.id(1), created: false)
        )
        stub.hold(GoogleAPIStub.postCreate)
        review(adder, line)
        adder.confirm()
        await stub.waitUntilParked(GoogleAPIStub.postCreate, count: 1)
        await settle(adder)
        guard case .failed(meeting, let note) = adder.stage else {
            Issue.record("expected the uncertain state, got \(adder.stage)")
            return
        }
        #expect(note.canRetry && !note.opensSettings)
        #expect(note.header == "May not have been added")
        #expect(note.text.contains("may not have been added"))

        // Task 172 (e): the late success, with the uncertain popup still
        // showing this draft, turns it into Added (before task 172 it moved
        // nothing).
        var shown: [UpcomingEvent] = []
        adder.onAdded = { shown.append($0) }
        stub.release()
        #expect(await eventually { adder.stage == .closed })
        #expect(adder.addedNote?.text == "Added · Sun 3:00 PM · Meeting with Rahaf")
        #expect(shown.map(\.title) == ["Meeting with Rahaf"])
        #expect(pending.entry == nil)
        #expect(creates().map { $0.body["id"] } == [IDSource.id(1)])
    }

    /// Task 172 (e): a late failure moves nothing, and Try again sends the
    /// same id.
    @Test func aLateFailureLeavesTheUncertainPopupAndTryAgainSendsTheSameID() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let pending = AddEventPending()
        let adder = adder(google, pending: pending, deadline: .milliseconds(300))
        stub.answer(
            GoogleAPIStub.postCreate,
            GoogleAPIStub.error(.badGateway, "fetch_failed"),
            GoogleAPIStub.created(id: IDSource.id(1), created: false)
        )
        stub.hold(GoogleAPIStub.postCreate)
        review(adder, line)
        adder.confirm()
        await stub.waitUntilParked(GoogleAPIStub.postCreate, count: 1)
        await settle(adder)
        guard case .failed(meeting, let note) = adder.stage, note.uncertain else {
            Issue.record("expected the uncertain state, got \(adder.stage)")
            return
        }
        stub.release()
        #expect(await eventually { !pending.isRequestOut })
        #expect(adder.stage == .failed(meeting, note))
        #expect(adder.addedNote == nil)

        adder.confirm()
        await settle(adder)
        #expect(adder.stage == .closed)
        #expect(creates().map { $0.body["id"] } == [IDSource.id(1), IDSource.id(1)])
    }

    /// Task 172 (e): a late success after the popup was closed shows nothing.
    @Test func aLateSuccessAfterThePopupClosedShowsNothing() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let pending = AddEventPending()
        let adder = adder(google, pending: pending, deadline: .milliseconds(300))
        stub.answer(GoogleAPIStub.postCreate, GoogleAPIStub.created(id: IDSource.id(1)))
        stub.hold(GoogleAPIStub.postCreate)
        review(adder, line)
        adder.confirm()
        await stub.waitUntilParked(GoogleAPIStub.postCreate, count: 1)
        await settle(adder)
        guard case .failed = adder.stage else {
            Issue.record("expected the uncertain state, got \(adder.stage)")
            return
        }
        adder.cancel()
        stub.release()
        #expect(await eventually { !pending.isRequestOut })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(adder.stage == .closed)
        #expect(adder.addedNote == nil)
    }

    @Test func tryAgainWhileTheFirstSendIsStillOutWaitsForItInsteadOfSendingAgain() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let pending = AddEventPending()
        let adder = adder(google, pending: pending, deadline: .milliseconds(500))
        stub.answer(GoogleAPIStub.postCreate, GoogleAPIStub.created(id: IDSource.id(1)))
        stub.hold(GoogleAPIStub.postCreate)
        review(adder, line)
        adder.confirm()
        await stub.waitUntilParked(GoogleAPIStub.postCreate, count: 1)
        await settle(adder)
        guard case .failed = adder.stage else {
            Issue.record("expected the uncertain state, got \(adder.stage)")
            return
        }
        #expect(pending.isRequestOut)
        adder.confirm()
        #expect(adder.stage == .sending(meeting))
        stub.release()
        await settle(adder)
        #expect(adder.stage == .closed)
        #expect(creates().count == 1)
    }
}


/// Task 172 (a): a task that has answered always wins the race, however
/// the timer's cancellation and the answer interleave. Before the fix the
/// cancelled timer could hand over the fallback first; with 2,000 tries
/// that showed up on every run tried.
@Suite struct PushDeadlineTests {
    @Test func anAnswerThatComesFirstAlwaysWins() async {
        var fallbacks = 0
        for round in 0..<2_000 {
            let task = Task { round }
            if round.isMultiple(of: 2) { _ = await task.value }
            let value = await PushDeadline.race(task, deadline: .seconds(30), fallback: -1)
            if value != round { fallbacks += 1 }
        }
        #expect(fallbacks == 0)
    }

    @Test func theFallbackComesAtTheDeadline() async {
        let task = Task<Int, Never> {
            try? await Task.sleep(for: .seconds(5))
            return 1
        }
        let started = ContinuousClock.now
        let value = await PushDeadline.race(task, deadline: .milliseconds(100), fallback: -1)
        #expect(value == -1)
        #expect(ContinuousClock.now - started < .seconds(3))
        task.cancel()
    }
}
