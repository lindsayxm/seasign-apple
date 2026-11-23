import Foundation

/// The words inside the corners of Today's frame (design v12): at the left
/// the temperature over the wind (`55°F`, `wind 8/`), in white; at the right
/// how long the sun or moon is up (`Daylight`, `9h 50m/`; `Moon up` at
/// night), in the accent. Pure, from the scene's state.
struct FrameText: Equatable {
    /// Lines shown, top to bottom; empty when there is nothing to show.
    var lines: [String]
    /// What VoiceOver says; nil when nothing is shown.
    var spoken: String?

    /// `55°F` over `wind 8/`, whichever is known. Both come from a fresh
    /// reading, so without one there is nothing.
    static func weather(_ state: SceneState) -> FrameText {
        var lines: [String] = []
        var spoken: [String] = []
        if let temperature = state.temperatureF {
            let degrees = Int(temperature.rounded())
            lines.append("\(degrees)°F")
            spoken.append("\(degrees) degrees Fahrenheit")
        }
        if let wind = state.windMph {
            let mph = Int(wind.rounded())
            lines.append("wind \(mph)/")
            spoken.append("wind \(mph) miles per hour")
        }
        return FrameText(lines: lines, spoken: spoken.isEmpty ? nil : spoken.joined(separator: ", "))
    }

    /// `Daylight` or `Moon up` over the time from rise to set of the pass
    /// the horizon marks (the drawn body's). Nothing when neither is drawn,
    /// in the neutral scene, or while either end is unknown.
    static func span(_ state: SceneState) -> FrameText {
        guard let body = state.body else { return FrameText(lines: [], spoken: nil) }
        let pass = state.markedPass
        guard let rise = pass.rise, let set = pass.set, set > rise else { return FrameText(lines: [], spoken: nil) }
        let minutes = Int((set.timeIntervalSince(rise) / 60).rounded(.down))
        let (hours, rest) = (minutes / 60, minutes % 60)
        let name = body.kind == .sun ? "Daylight" : "Moon up"
        return FrameText(
            lines: [name, "\(hours)h " + String(format: "%02d", rest) + "m/"],
            spoken: "\(name), \(hours) hours \(rest) minutes"
        )
    }
}
