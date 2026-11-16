import Foundation
import SwiftData

/// A calendar link the user pasted in Settings: Google's "Secret address in
/// iCal format", an iCloud public calendar link (`webcal://`), or an Outlook
/// published ICS link.
///
/// `url` is a credential: anyone who has it can read the calendar. It lives in
/// the user store only, is sent only to `POST /v1/calendar/events`, and must
/// never be logged, put in an error or an accessibility label, or shown in
/// full. Show `LinkMask.host(of:)` instead, and never interpolate a
/// `CalendarLink` or its `url` into a string.
@Model
final class CalendarLink {
    /// Stable across devices once settings sync; not the SwiftData row identifier.
    var id: UUID
    /// What the user calls this calendar ("Family").
    var name: String
    /// The link as pasted, trimmed.
    var url: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, url: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.url = url
        self.createdAt = createdAt
    }
}

/// What may be shown of a calendar link: a shortened host and nothing else.
enum LinkMask {
    private static let secondLevelSuffixes: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"]

    /// "google.com" for a Google secret address, "icloud.com" for an iCloud
    /// link. Only the last labels of the host are kept, so neither the path,
    /// the query nor a subdomain can leak a secret. Nil when the text has no
    /// host to show.
    static func host(of link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URLComponents(string: trimmed)?.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        let labels = host.split(separator: ".").map(String.init)
        // An IP address or a single-label host says nothing useful.
        guard labels.count >= 2, labels.contains(where: { $0.contains(where: \.isLetter) }) else {
            return nil
        }
        let top = labels[labels.count - 1]
        let second = labels[labels.count - 2]
        // "example.co.uk", "example.com.au": the suffix takes two labels.
        let keep = labels.count >= 3 && top.count == 2 && secondLevelSuffixes.contains(second) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }
}
