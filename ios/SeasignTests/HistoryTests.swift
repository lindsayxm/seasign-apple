import Foundation
import Testing

@testable import Seasign

@Suite struct ArticleQueryTests {
    private func matches(_ text: String, title: String, source: String = "Example News") -> Bool {
        ArticleQuery(text: text).matches(title: title, source: source, category: "Sci")
    }

    @Test func emptyOrBlankSearchMatchesEverything() {
        #expect(matches("", title: "Anything"))
        #expect(matches("   \n", title: "Anything"))
    }

    @Test func ignoresCaseAccentsAndWidth() {
        #expect(matches("nino", title: "A short explainer on how El Niño works"))
        #expect(matches("NIÑO", title: "el nino"))
        #expect(matches("cafe", title: "The CAFÉ on the pier"))
        #expect(matches("ｍａｐ", title: "The paper map"))
    }

    @Test func curlyAndStraightQuotesAreTheSame() {
        #expect(matches("it's", title: "It’s getting too dry"))
        #expect(matches("it’s", title: "It's getting too dry"))
    }

    @Test func searchesTheSourceToo() {
        #expect(matches("lakes review", title: "Winter", source: "The Lakes Review"))
    }

    @Test func everyWordMustAppearInTitleOrSource() {
        #expect(matches("crows review", title: "Crows decide fast", source: "The Lakes Review"))
        #expect(!matches("crows ravens", title: "Crows decide fast"))
    }

    /// Text is matched as text: characters that mean something to patterns,
    /// predicates or format strings are ordinary here.
    @Test func searchTextIsPlainText() {
        #expect(matches("[video]", title: "How El Niño works [video]"))
        #expect(!matches(".*", title: "Anything"))
        #expect(!matches("%@", title: "Anything"))
        #expect(matches("%@", title: "Format %@ strings"))
        #expect(!matches("ANY title", title: "Something else"))
    }

    @Test func categoryMatchesIgnoringCaseAndNilIsAll() {
        let item = (title: "Telescope", source: "Example", category: "Sci")
        #expect(ArticleQuery().matches(title: item.title, source: item.source, category: item.category))
        #expect(ArticleQuery(category: "sci").matches(title: item.title, source: item.source, category: item.category))
        #expect(!ArticleQuery(category: "News").matches(title: item.title, source: item.source, category: item.category))
        #expect(!ArticleQuery(text: "crows", category: "Sci").matches(title: item.title, source: item.source, category: item.category))
    }

    @Test func aCategoryNoLongerListedFallsBackToAll() {
        #expect(ArticleQuery.choice("Sci", among: ["Local", "Sci"]) == "Sci")
        #expect(ArticleQuery.choice("sci", among: ["Local", "Sci"]) == "Sci")
        #expect(ArticleQuery.choice("Gone", among: ["Local"]) == nil)
        #expect(ArticleQuery.choice(nil, among: ["Local"]) == nil)
    }
}

@Suite @MainActor struct HistoryListTests {
    private let now = instant("2026-11-15T23:05:00Z")

    private func entry(_ title: String, ago seconds: TimeInterval, category: String = "Sci") -> FeedEntry {
        FeedEntry(
            link: "https://news.example.com/" + title,
            title: title,
            source: "Example News",
            published: now.addingTimeInterval(-seconds),
            dateSource: .published,
            excerpt: nil,
            siteID: UUID(),
            category: category,
            firstFetchedAt: now
        )
    }

    @Test func newestFirstAndNothingOlderThanSevenDays() {
        let entries = [
            entry("two-days", ago: 2 * 86_400),
            entry("just-expired", ago: 7 * 86_400 + 1),
            entry("an-hour", ago: 3600),
            entry("exactly-seven-days", ago: 7 * 86_400),
            entry("a-month", ago: 30 * 86_400),
        ]
        let shown = HistoryList.visible(entries, now: now, query: ArticleQuery())
        #expect(shown.map(\.title) == ["an-hour", "two-days", "exactly-seven-days"])
    }

    @Test func categoriesComeFromWhatCanBeShown() {
        let entries = [
            entry("a", ago: 3600, category: "Sci"),
            entry("b", ago: 7200, category: "sci"),
            entry("c", ago: 3600, category: "Local"),
            entry("d", ago: 8 * 86_400, category: "Old"),
        ]
        #expect(HistoryList.categories(entries, now: now) == ["Local", "Sci"])
        #expect(HistoryList.visible(entries, now: now, query: ArticleQuery(category: "Sci")).map(\.title) == ["a", "b"])
    }

    @Test func sourceAndDateLine() {
        let newYork = TimeZone(identifier: "America/New_York")!
        var item = ReadingItem(entry("Telescope", ago: 3600))
        #expect(SourceDateLine.text(item, timeZone: newYork) == "Example News · Nov 15, 2026")
        item.source = ""
        #expect(SourceDateLine.text(item, timeZone: newYork) == "Nov 15, 2026")
        // The day follows the zone.
        #expect(ReadingDate.day(instant("2026-11-16T03:00:00Z"), timeZone: newYork) == "Nov 15, 2026")
        #expect(ReadingDate.day(instant("2026-11-16T03:00:00Z"), timeZone: TimeZone(identifier: "UTC")!) == "Nov 16, 2026")
    }

    @Test func aFeedEntryAndItsReadingItemShowTheSameDate() {
        let newYork = TimeZone(identifier: "America/New_York")!
        let feedEntry = entry("Telescope", ago: 3600)
        #expect(ReadingDate(item: ReadingItem(feedEntry), timeZone: newYork, clock: .twelveHour) == ReadingDate(entry: feedEntry, timeZone: newYork, clock: .twelveHour))
    }

    @Test func saveLabelsNameTheArticle() {
        #expect(SaveMark.label(isSaved: false, title: "Telescope **now**") == "Save Telescope **now**")
        #expect(SaveMark.label(isSaved: true, title: "Telescope") == "Remove Telescope from Saved")
    }
}
