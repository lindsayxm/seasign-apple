import Combine
import Foundation
import SwiftUI

/// How the app writes a time of day: the phone's 12- or 24-hour setting.
///
/// The pure formatters (`EventLabel`, `ReadingDate`) take one of these, so
/// tests choose the form; the app reads it from the phone with `system` and
/// hands it down through the environment (`\.clockStyle`).
enum ClockStyle: Sendable, Equatable {
    /// `9:00PM`, `12:30AM`.
    case twelveHour
    /// `21:00`, `00:30`.
    case twentyFourHour

    /// The two 12-hour cycles (h11, h12) read as 12-hour and the two 24-hour
    /// cycles (h23, h24) as 24-hour. The app always writes 1-12 and 00-23, as
    /// iOS does for its own clock, never `0:30PM` or `24:00`.
    init(hourCycle: Locale.HourCycle) {
        switch hourCycle {
        case .zeroToEleven, .oneToTwelve:
            self = .twelveHour
        case .zeroToTwentyThree, .oneToTwentyFour:
            self = .twentyFourHour
        @unknown default:
            self = .twelveHour
        }
    }

    /// What the phone uses now. `Locale.hourCycle` on the autoupdating
    /// current locale gives the user's preference when they have overridden
    /// the region's default, which is what the 24-Hour Time switch in
    /// Settings › General › Date & Time does. Read afresh each time.
    static var system: ClockStyle {
        ClockStyle(hourCycle: Locale.autoupdatingCurrent.hourCycle)
    }

    /// One time of day split for Today's two time columns: the clock
    /// (`9:05`, `21:05`) and the half of the day (`PM`), which is nil on
    /// a 24-hour phone. `hour` is 0 to 23.
    func columns(hour: Int, minute: Int) -> (clock: String, half: String?) {
        let minutes = String(format: "%02d", minute)
        switch self {
        case .twelveHour:
            let hour12 = hour % 12 == 0 ? 12 : hour % 12
            return ("\(hour12):\(minutes)", hour < 12 ? "AM" : "PM")
        case .twentyFourHour:
            return (String(format: "%02d", hour) + ":" + minutes, nil)
        }
    }

    /// One time of day, as shown (`9:05PM`, `21:05`) and as spoken by
    /// VoiceOver (`9:05 PM`, `21:05`). `hour` is 0 to 23.
    func clock(hour: Int, minute: Int) -> (shown: String, spoken: String) {
        let minutes = String(format: "%02d", minute)
        switch self {
        case .twelveHour:
            let hour12 = hour % 12 == 0 ? 12 : hour % 12
            let half = hour < 12 ? "AM" : "PM"
            return ("\(hour12):\(minutes)\(half)", "\(hour12):\(minutes) \(half)")
        case .twentyFourHour:
            let text = String(format: "%02d", hour) + ":" + minutes
            return (text, text)
        }
    }
}

extension EnvironmentValues {
    /// The phone's 12- or 24-hour setting, kept current by `followsSystemClockStyle()`.
    @Entry var clockStyle: ClockStyle = .system
}

extension View {
    /// Reads the phone's 12- or 24-hour setting into `\.clockStyle` and keeps
    /// it current: again when the system says the current locale changed
    /// (`NSLocale.currentLocaleDidChangeNotification`, posted when the user
    /// changes region or time settings) and whenever the app comes back to
    /// the foreground, since the switch is changed in the Settings app.
    /// Applied once at the root, so every sheet and full-screen cover gets it.
    func followsSystemClockStyle() -> some View {
        modifier(SystemClockStyle())
    }
}

private struct SystemClockStyle: ViewModifier {
    @State private var style = ClockStyle.system
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(\.clockStyle, style)
            // The notification may be posted on any thread; the state is set on the main one.
            .onReceive(
                NotificationCenter.default
                    .publisher(for: NSLocale.currentLocaleDidChangeNotification)
                    .receive(on: DispatchQueue.main)
            ) { _ in
                reread()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { reread() }
            }
    }

    private func reread() {
        let current = ClockStyle.system
        if current != style { style = current }
    }
}
