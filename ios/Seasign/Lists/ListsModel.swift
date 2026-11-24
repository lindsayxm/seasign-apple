import Foundation
import Observation
import SwiftData

/// The Do and Get lists: adds, checks off and deletes items in SwiftData and
/// keeps them in memory for the view. Every change is saved straight away, so
/// nothing is lost if the app is closed right after.
@MainActor
@Observable
final class ListsModel {
    /// Every item of both lists, oldest first.
    private(set) var items: [ListItem] = []

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let now: () -> Date

    init(context: ModelContext, now: @escaping () -> Date = { Date() }) {
        self.context = context
        self.now = now
        reload()
    }

    /// The items of one list in the order they were added. Done items keep
    /// their place.
    func items(_ kind: ListKind) -> [ListItem] {
        items.filter { $0.kind == kind }
    }

    /// The title an input would be stored under: the text without surrounding
    /// spaces and line breaks, or nil when nothing is left.
    static func validTitle(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Adds an item to the end of a list. Empty or whitespace-only input adds
    /// nothing and returns nil.
    @discardableResult
    func add(_ input: String, to kind: ListKind) -> ListItem? {
        guard let title = Self.validTitle(input) else { return nil }
        let item = ListItem(kind: kind, title: title, createdAt: now())
        context.insert(item)
        save()
        return item
    }

    /// Marks an item done, or not done if it already was.
    func toggle(_ item: ListItem) {
        item.isDone.toggle()
        item.updatedAt = now()
        save()
    }

    func delete(_ item: ListItem) {
        context.delete(item)
        save()
    }

    /// Whether a list has at least one checked item (the CLEAR CHECKED
    /// button shows only then).
    func hasChecked(_ kind: ListKind) -> Bool {
        items.contains { $0.kind == kind && $0.isDone }
    }

    /// Deletes every checked item of one list. The other list and the
    /// unchecked items are left alone. One save, so it is all or nothing.
    func clearChecked(_ kind: ListKind) {
        let checked = items.filter { $0.kind == kind && $0.isDone }
        guard !checked.isEmpty else { return }
        for item in checked { context.delete(item) }
        save()
    }

    private func save() {
        do {
            try context.save()
        } catch {
            // Keep memory and the store in step: drop what could not be written.
            context.rollback()
        }
        reload()
    }

    private func reload() {
        let all = (try? context.fetch(FetchDescriptor<ListItem>())) ?? []
        // Sorted here rather than in the fetch so that items created in the
        // same instant still have one fixed order.
        items = all.sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
    }
}

#if DEBUG
extension ListsModel {
    /// Debug-only (`-debugLists YES`): a few Do and Get items, one of each
    /// checked off, written into `context`, which is an in-memory store (see
    /// `SeasignApp`). Nothing reaches the user's own store.
    static func sample(context: ModelContext, now: Date = Date()) throws -> ListsModel {
        let items: [(ListKind, String, Bool)] = [
            (.todo, "Call the dentist about Thursday", false),
            (.todo, "Return the library books", true),
            (.todo, "Book the ferry for Saturday", false),
            (.get, "Oat milk", false),
            (.get, "Batteries, AA", true),
            (.get, "Birthday card for Sam", false),
        ]
        for (index, (kind, title, done)) in items.enumerated() {
            context.insert(ListItem(kind: kind, title: title, isDone: done, createdAt: now.addingTimeInterval(Double(index - items.count) * 60)))
        }
        try context.save()
        return ListsModel(context: context, now: { now })
    }
}
#endif
