import CryptoKit
import Foundation
import Observation
import SwiftData

/// Which APNs a device token belongs to: sandbox for Debug builds (the
/// `aps-environment` development entitlement), production for Release
/// (TestFlight and the App Store).
enum APNsEnvironment: String, Sendable, Equatable {
    case sandbox
    case production

    static var current: APNsEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}

/// This app's APNs device token, as lowercase hex. It is the address the
/// Worker sends background pushes to, so it never prints, is never logged,
/// and is kept in memory only (the store keeps a hash, `GoogleWatchRecord`).
struct APNsDeviceToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Read only where the request body is built.
    let hex: String

    /// The bytes from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    init(_ data: Data) {
        hex = data.map { String(format: "%02x", $0) }.joined()
    }

    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The last channels the API made for this device, so a relaunch does not
/// ask Google again while they still have time left. One row at most, in the
/// cache store: losing it only means watching once more. It holds no device
/// token and no calendar id, only a hash of both (`GoogleWatchKeeper.fingerprint`).
@Model
final class GoogleWatchRecord {
    var fingerprint: String
    /// When the first of the channels ends.
    var expiresAt: Date
    /// Every calendar asked for got a channel.
    var complete: Bool

    init(fingerprint: String, expiresAt: Date, complete: Bool) {
        self.fingerprint = fingerprint
        self.expiresAt = expiresAt
        self.complete = complete
    }
}

/// What `GoogleWatchKeeper` needs from the Google connection.
@MainActor
protocol GoogleWatchHost: AnyObject {
    /// The Google ids of the calendars that are on, in the order shown; nil
    /// when nothing is connected (or the model is a frozen sample).
    var watchCalendars: [String]? { get }
    /// An access token, renewed if needed.
    func watchToken() async throws -> GoogleSecret
    /// Google did not take the token: the next `watchToken()` renews it.
    func watchTokenRejected()
}

/// Keeps this device's Google push channels in step with the chosen
/// calendars (plan plans/2026-11-19-google-calendar-push.md, task E).
///
/// - It asks for remote notifications once Google is connected, and sends
///   `POST /v1/google/watch` with the calendars that are on, the device
///   token and the APNs environment: when the token arrives or changes,
///   when the calendars change, and when the app opens and the channels have
///   less than `renewalWindow` left (Google's channels cannot be renewed,
///   only replaced).
/// - One watch or unwatch runs at a time, and the latest wanted state wins:
///   the API keeps the channels of whichever request commits last, so a
///   request is never cancelled to make way for a newer one; the newer one
///   waits for it, and states wanted meanwhile collapse into the last.
/// - Its failures never touch the events' holds or status: polling goes on
///   as before. Our 429 and calendars Google would not watch show in
///   Settings; anything else (no server, a server without a webhook) is
///   retried when the app next opens, after `failureHold`.
///
/// Nothing here logs; the device token and the Google token never leave
/// memory except in the request.
@MainActor
@Observable
final class GoogleWatchKeeper {
    /// Re-register when the channels have less than this left.
    static let renewalWindow: TimeInterval = 2 * 24 * 60 * 60
    /// After a failure other than our 429, opening the app does not try again before this.
    static let failureHold: TimeInterval = 15 * 60

    /// Why the last watch did not happen, when Settings should say so.
    enum Problem: Equatable {
        /// The API's own per-network limit (429).
        case rateLimited

        var message: String {
            switch self {
            case .rateLimited:
                "Too many requests from this network, so instant updates aren't set up yet. Today keeps checking every few seconds."
            }
        }
    }

    private(set) var problem: Problem?
    /// The API's code for each calendar (Google id) that could not be watched.
    private(set) var calendarProblems: [String: String] = [:]
    /// The channels cover every calendar that is on and have not ended:
    /// Today then polls slowly (`GooglePoll.interval`).
    private(set) var isLive = false

    /// Asks the system for a device token (`registerForRemoteNotifications`).
    /// Set by the app; a no-op in tests unless they set one.
    @ObservationIgnored var register: @MainActor () -> Void = {}
    @ObservationIgnored weak var host: (any GoogleWatchHost)?

    @ObservationIgnored private let api: SeasignAPI
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let environment: APNsEnvironment
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Memory only.
    @ObservationIgnored private(set) var deviceToken: APNsDeviceToken?
    @ObservationIgnored private var registered = false
    @ObservationIgnored private var holdUntil: Date?
    @ObservationIgnored private var holdIsRateLimit = false
    /// The set a failure hold is about (other than our 429, which holds everything).
    @ObservationIgnored private var heldFingerprint: String?
    /// A watch made this launch may have left channels at the API.
    @ObservationIgnored private var mayHaveChannels = false
    /// Moves when the connection ends, so a watch answering afterwards changes nothing.
    @ObservationIgnored private var generation = 0

    private enum Operation {
        case watch(calendars: [String], device: APNsDeviceToken, fingerprint: String)
        /// `token` nil: ask the host for one when it runs.
        case unwatch(device: APNsDeviceToken, token: GoogleSecret?)
    }

    /// The latest state wanted and not yet sent.
    @ObservationIgnored private var wanted: Operation?
    @ObservationIgnored private var running: Task<Void, Never>?
    /// The fingerprint of the watch being sent, if one is.
    @ObservationIgnored private var sendingFingerprint: String?

    init(api: SeasignAPI, context: ModelContext, environment: APNsEnvironment = .current, now: @escaping @Sendable () -> Date) {
        self.api = api
        self.context = context
        self.environment = environment
        self.now = now
        mayHaveChannels = record != nil
    }

    // MARK: Triggers

    /// Why `sync` runs.
    enum Reason: Equatable {
        case launch, opened, token, calendars
        /// A request has just ended: what is wanted now is decided again.
        case afterRequest
    }

    /// The system gave a device token (every launch; it may differ from last time).
    func registered(_ token: APNsDeviceToken) {
        deviceToken = token
        sync(.token)
    }

    /// The system could not give a device token: asked again next time.
    func registrationFailed() {
        registered = false
    }

    /// Brings the channels in line with what is wanted now (see the type's
    /// notes). While a request is out, this only replaces what is queued
    /// behind it; when it ends, the decision is made again against the
    /// calendars on then (`Reason.afterRequest`).
    func sync(_ reason: Reason) {
        guard let calendars = host?.watchCalendars else { return }
        if !registered {
            registered = true
            register()
        }
        updateLive()
        let next = nextOperation(calendars: calendars, reason: reason)
        if running == nil {
            if let next { want(next) }
        } else {
            wanted = next
        }
    }

    /// What to send for `calendars`, or nil when nothing needs sending.
    private func nextOperation(calendars: [String], reason: Reason) -> Operation? {
        guard let device = deviceToken else { return nil }
        if calendars.isEmpty {
            // Nothing to be woken for: an empty watch is refused, so the
            // channels are stopped instead.
            return mayHaveChannels ? .unwatch(device: device, token: nil) : nil
        }
        let fingerprint = Self.fingerprint(calendars: calendars, device: device, environment: environment)
        if isFresh(fingerprint) { return nil }
        // Already on its way: whatever it leaves is looked at when it ends.
        if sendingFingerprint == fingerprint { return nil }
        // Our 429 holds everything. Another failure holds only retries of
        // the same set that nobody asked for (opening the app, the check
        // after a request); a set chosen since then goes ahead.
        if let holdUntil, now() < holdUntil {
            if holdIsRateLimit { return nil }
            let unasked = reason == .opened || reason == .launch || reason == .afterRequest
            if unasked, heldFingerprint == fingerprint { return nil }
        }
        return .watch(calendars: calendars, device: device, fingerprint: fingerprint)
    }

    /// The connection ended (Disconnect, or the sign-in expired): forgets the
    /// channels here and asks the API to stop them with `token`, after any
    /// request already out. Without a device token or a Google token nothing
    /// can be sent; the channels then end by themselves within 7 days and
    /// their pushes find nothing connected.
    func stop(using token: GoogleSecret?) async {
        forget()
        guard let device = deviceToken, let token else {
            wanted = nil
            return
        }
        want(.unwatch(device: device, token: token))
        await idle()
    }

    /// Forgets the channels here at once (no request): no status, not live,
    /// and an answer still out changes nothing. `stop` does this first.
    func forget() {
        generation += 1
        wanted = nil
        registered = false
        holdUntil = nil
        holdIsRateLimit = false
        heldFingerprint = nil
        problem = nil
        calendarProblems = [:]
        mayHaveChannels = false
        store(nil)
        updateLive()
    }

    /// Whether `stop` could send anything (a device token is known).
    var canUnwatch: Bool {
        deviceToken != nil
    }

    /// Returns when no request is out or queued.
    func idle() async {
        while let running {
            await running.value
        }
    }

    // MARK: State

    /// A hash of what one watch covers: the APNs environment, the device token
    /// and the calendar ids, in no particular order.
    nonisolated static func fingerprint(calendars: [String], device: APNsDeviceToken, environment: APNsEnvironment) -> String {
        let text = (["v1", environment.rawValue, device.hex] + Set(calendars).sorted()).joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var record: GoogleWatchRecord? {
        try? context.fetch(FetchDescriptor<GoogleWatchRecord>()).first
    }

    /// When the current channels end, if any are known.
    var expiresAt: Date? {
        record?.expiresAt
    }

    /// The stored channels cover `fingerprint` completely and have more than
    /// `renewalWindow` left.
    private func isFresh(_ fingerprint: String) -> Bool {
        guard let record, record.fingerprint == fingerprint, record.complete else { return false }
        return record.expiresAt.timeIntervalSince(now()) > Self.renewalWindow
    }

    private func updateLive() {
        let live: Bool
        if let device = deviceToken, let calendars = host?.watchCalendars, !calendars.isEmpty,
           let record, record.complete, record.expiresAt > now() {
            live = record.fingerprint == Self.fingerprint(calendars: calendars, device: device, environment: environment)
        } else {
            live = false
        }
        if live != isLive { isLive = live }
    }

    private func store(_ value: (fingerprint: String, expiresAt: Date, complete: Bool)?) {
        for row in (try? context.fetch(FetchDescriptor<GoogleWatchRecord>())) ?? [] {
            context.delete(row)
        }
        if let value {
            context.insert(GoogleWatchRecord(fingerprint: value.fingerprint, expiresAt: value.expiresAt, complete: value.complete))
        }
        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }

    private func hold(_ seconds: TimeInterval, rateLimit: Bool, fingerprint: String? = nil) {
        holdUntil = now().addingTimeInterval(seconds)
        holdIsRateLimit = rateLimit
        heldFingerprint = fingerprint
    }

    // MARK: One request at a time

    private func want(_ operation: Operation) {
        wanted = operation
        guard running == nil else { return }
        running = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let operation = wanted {
            wanted = nil
            await perform(operation)
            // An unwatch with its own token (the connection ended) stays
            // queued; anything else is decided again from the state now, so
            // an answer that landed after the calendars changed is put right.
            if case .unwatch(_, .some) = wanted { continue }
            if let calendars = host?.watchCalendars {
                updateLive()
                wanted = nextOperation(calendars: calendars, reason: .afterRequest)
            }
        }
        running = nil
    }

    private func perform(_ operation: Operation) async {
        switch operation {
        case .watch(let calendars, let device, let fingerprint):
            await watch(calendars: calendars, device: device, fingerprint: fingerprint)
        case .unwatch(let device, let token):
            let started = generation
            var token = token
            if token == nil { token = try? await host?.watchToken() }
            guard let token else { return }
            // Best effort: the API forgets the channels even when Google
            // will not stop them, and channels end by themselves.
            _ = try? await api.googleUnwatch(token: token, deviceToken: device)
            // Sent, so taken as done whatever came back (a failure is not retried).
            guard started == generation else { return }
            mayHaveChannels = false
            store(nil)
            updateLive()
        }
    }

    private func watch(calendars: [String], device: APNsDeviceToken, fingerprint: String) async {
        let started = generation
        sendingFingerprint = fingerprint
        defer { sendingFingerprint = nil }
        mayHaveChannels = true
        let answer: GoogleWatchAnswer
        do {
            answer = try await withToken { api, token in
                try await api.googleWatch(token: token, calendars: calendars, deviceToken: device, environment: self.environment)
            }
        } catch {
            guard started == generation else { return }
            if case SeasignAPI.GooglePushFailure.rateLimited(let seconds) = error {
                hold(TimeInterval(seconds), rateLimit: true)
                problem = .rateLimited
            } else {
                hold(Self.failureHold, rateLimit: false, fingerprint: fingerprint)
            }
            return
        }
        guard started == generation else { return }
        problem = nil
        var problems: [String: String] = [:]
        for status in answer.calendars where !status.ok && calendars.indices.contains(status.index) {
            problems[calendars[status.index]] = status.error ?? "fetch_failed"
        }
        let complete = calendars.indices.allSatisfy { index in
            answer.calendars.contains { $0.index == index && $0.ok }
        }
        calendarProblems = problems
        if let expiresAt = answer.expiresAt {
            store((fingerprint, expiresAt, complete))
            if complete {
                holdUntil = nil
                holdIsRateLimit = false
                heldFingerprint = nil
            } else {
                hold(Self.failureHold, rateLimit: false, fingerprint: fingerprint)
            }
        } else {
            // Nothing was made; the API kept the earlier channels, whose
            // calendars are no longer the ones wanted.
            store(nil)
            hold(Self.failureHold, rateLimit: false, fingerprint: fingerprint)
        }
        updateLive()
    }

    /// Runs `call` with an access token; on a 401 renews it and tries once more.
    private func withToken<T>(_ call: (SeasignAPI, GoogleSecret) async throws -> T) async throws -> T {
        guard let host else { throw SeasignAPI.GooglePushFailure.unavailable }
        let token = try await host.watchToken()
        do {
            return try await call(api, token)
        } catch SeasignAPI.GooglePushFailure.googleAuth {
            host.watchTokenRejected()
            let renewed = try await host.watchToken()
            return try await call(api, renewed)
        }
    }

    #if DEBUG
    /// For the frozen `-debugGoogle` sample: a calendar Google would not watch.
    func showSampleProblem(calendar: String, code: String) {
        calendarProblems = [calendar: code]
    }
    #endif
}

/// What a background push did, for `UIBackgroundFetchResult`.
enum GooglePushOutcome: Equatable, Sendable {
    case newData, noData, failed
}

/// How a push from the Worker is handled.
enum GooglePushHandling {
    /// The only push the Worker sends: `{"aps":{"content-available":1},"type":"calendar-changed"}`.
    static let calendarChanged = "calendar-changed"
    /// The completion handler is called by then: the system allows 30 seconds.
    static let deadline: Duration = .seconds(25)
    /// Pushes arriving within this of the first share one fetch (Google often
    /// sends a few notifications for one change).
    static let coalescingWindow: Duration = .seconds(1)
}
