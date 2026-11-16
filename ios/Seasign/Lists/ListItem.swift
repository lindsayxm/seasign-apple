import Foundation
import SwiftData

/// Which of the two lists an item belongs to.
enum ListKind: String, CaseIterable, Sendable {
    /// Things to do.
    case todo = "do"
    /// Things to get.
    case get

    /// The section label ("DO", "GET"); shown in caps by the view.
    var label: String {
        switch self {
        case .todo: "Do"
        case .get: "Get"
        }
    }
}

/// One line of the Do or Get list. Stored on the device only for now; `id` and
/// `updatedAt` are there for the later sync with the API.
@Model
final class ListItem {
    /// Stable across devices once lists sync; not the SwiftData row identifier.
    var id: UUID
    /// A `ListKind` raw value ("do" or "get"). Kept as a string so the store
    /// and later the API see a plain value; read it through `kind`.
    var kindRaw: String
    /// The text as the user typed it (trimmed). The view shows it in caps.
    var title: String
    var isDone: Bool
    var createdAt: Date
    /// When the item was last added or changed.
    var updatedAt: Date

    var kind: ListKind {
        ListKind(rawValue: kindRaw) ?? .todo
    }

    init(id: UUID = UUID(), kind: ListKind, title: String, isDone: Bool = false, createdAt: Date) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.title = title
        self.isDone = isDone
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}
