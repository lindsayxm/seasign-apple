import Foundation
import SwiftData
import Testing

@testable import Seasign

@Suite @MainActor struct ListsModelTests {
    /// A clock that moves one second forward each time it is read, so every
    /// item gets its own timestamp.
    final class SteppingClock {
        private var current = instant("2026-11-15T12:00:00Z")
        func next() -> Date {
            current = current.addingTimeInterval(1)
            return current
        }
    }

    private func model(context: ModelContext, clock: SteppingClock = SteppingClock()) -> ListsModel {
        ListsModel(context: context, now: { clock.next() })
    }

    @Test func startsEmpty() throws {
        let model = model(context: try inMemoryContext())
        #expect(model.items(.todo).isEmpty)
        #expect(model.items(.get).isEmpty)
    }

    @Test func addsToTheChosenListOnly() throws {
        let model = model(context: try inMemoryContext())
        model.add("Wash car", to: .todo)
        model.add("Coffee", to: .get)
        #expect(model.items(.todo).map(\.title) == ["Wash car"])
        #expect(model.items(.get).map(\.title) == ["Coffee"])
    }

    @Test func keepsTheTextAsTypedWithoutSurroundingSpace() throws {
        let model = model(context: try inMemoryContext())
        let item = try #require(model.add("  Almond milk \n", to: .get))
        #expect(item.title == "Almond milk")
        #expect(item.kind == .get)
        #expect(item.kindRaw == "get")
        #expect(!item.isDone)
        #expect(item.updatedAt == item.createdAt)
    }

    @Test(arguments: ["", " ", "   \n\t "])
    func emptyInputAddsNothing(input: String) throws {
        let model = model(context: try inMemoryContext())
        #expect(model.add(input, to: .todo) == nil)
        #expect(model.items.isEmpty)
        #expect(ListsModel.validTitle(input) == nil)
    }

    @Test func itemsStayInTheOrderTheyWereAdded() throws {
        let model = model(context: try inMemoryContext())
        for title in ["One", "Two", "Three", "Four"] {
            model.add(title, to: .todo)
        }
        let second = model.items(.todo)[1]
        model.toggle(second)
        // A done item keeps its place.
        #expect(model.items(.todo).map(\.title) == ["One", "Two", "Three", "Four"])
        #expect(model.items(.todo).map(\.isDone) == [false, true, false, false])
    }

    @Test func toggleMarksDoneAndBackAndStampsTheChange() throws {
        let model = model(context: try inMemoryContext())
        let item = try #require(model.add("Get groceries", to: .todo))
        model.toggle(item)
        #expect(item.isDone)
        #expect(item.updatedAt > item.createdAt)
        let firstChange = item.updatedAt
        model.toggle(item)
        #expect(!item.isDone)
        #expect(item.updatedAt > firstChange)
    }

    @Test func deleteRemovesOnlyThatItem() throws {
        let model = model(context: try inMemoryContext())
        model.add("Coffee", to: .get)
        let milk = try #require(model.add("Almond milk", to: .get))
        model.add("Wash car", to: .todo)
        model.delete(milk)
        #expect(model.items(.get).map(\.title) == ["Coffee"])
        #expect(model.items(.todo).map(\.title) == ["Wash car"])
    }

    @Test func itemsHaveDistinctSyncIDs() throws {
        let model = model(context: try inMemoryContext())
        let first = try #require(model.add("Coffee", to: .get))
        let second = try #require(model.add("Coffee", to: .get))
        #expect(first.id != second.id)
    }

    @Test func changesAreThereInAFreshContext() throws {
        let container = try SeasignSchema.inMemoryContainer()
        let clock = SteppingClock()
        let first = model(context: ModelContext(container), clock: clock)
        first.add("Get groceries", to: .todo)
        let car = try #require(first.add("Wash car", to: .todo))
        first.add("Coffee", to: .get)
        let gone = try #require(first.add("Tea", to: .get))
        first.toggle(car)
        first.delete(gone)
        let carID = car.id

        // What a relaunch sees: a new context on the same store.
        let relaunched = model(context: ModelContext(container), clock: clock)
        #expect(relaunched.items(.todo).map(\.title) == ["Get groceries", "Wash car"])
        #expect(relaunched.items(.todo).map(\.isDone) == [false, true])
        #expect(relaunched.items(.get).map(\.title) == ["Coffee"])
        #expect(relaunched.items(.todo).last?.id == carID)
    }
}
