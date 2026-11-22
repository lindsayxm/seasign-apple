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

    private func adder(_ google: GoogleCalendarModel) -> AddEventModel {
        let clock = clock
        let zone = zone
        let ids = ids
        return AddEventModel(
            google: google,
            parser: EventPhraseParser(detector: FakeDateDetector()),
            timeZone: { zone },
            now: { clock.now },
            clock: { .twelveHour },
            makeID: { ids.next() }
        )
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
        (HTTPResponse.Status.forbidden, "insufficient_scope", "Connect again to add events", false, true),
        (.forbidden, "forbidden", "won't take new events in “Me”", false, true),
        (.notFound, "not_found", "couldn't find “Me”", false, true),
        (.badGateway, "rejected", "Google refused this event", false, false),
        (.badRequest, "invalid_request", "couldn't send this event", false, false),
        (.badGateway, "timeout", "may not have been added", true, false),
        (.badGateway, "fetch_failed", "may not have been added", true, false),
        (.internalServerError, "internal_error", "may not have been added", true, false),
        (.tooManyRequests, "rate_limited", "Too many requests", true, false),
    ])
    func eachErrorIsWordedPlainly(_ status: HTTPResponse.Status, _ code: String, _ words: String, _ retry: Bool, _ settings: Bool) async throws {
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
        // A failure that cannot be tried again cannot be confirmed again.
        if !retry {
            adder.confirm()
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
        adder.confirm()
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
        #expect(creates().isEmpty)
    }

    @Test func aLineNotUnderstoodSaysWhyAndKeepsItForTryAgain() async throws {
        let context = ModelContext(try SeasignSchema.inMemoryContainer())
        let google = await connected(context)
        let adder = adder(google)
        review(adder, "tomorrow at 3pm")
        #expect(adder.stage == .problem(.noTitle))
        adder.confirm()
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
}
