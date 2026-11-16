import CoreGraphics
import Foundation
import Testing

@testable import Seasign

private func entry(
    _ title: String,
    published: String,
    link: String? = nil,
    dateSource: FeedDateSource = .published
) -> FeedEntry {
    FeedEntry(
        link: link ?? "https://news.example.com/\(title.lowercased().replacingOccurrences(of: " ", with: "-"))",
        title: title,
        source: "Example News",
        published: instant(published),
        dateSource: dateSource,
        excerpt: nil,
        siteID: UUID(),
        category: "Sci",
        firstFetchedAt: instant(published)
    )
}

@Suite struct SiteAddressTests {
    @Test(arguments: [
        ("wired.com/category/science/", "https://wired.com/category/science/"),
        ("  www.example.com  ", "https://www.example.com"),
        ("https://news.example.com/science/", "https://news.example.com/science/"),
        ("HTTPS://News.Example.com/Sci", "https://News.Example.com/Sci"),
        ("http://example.com/feed", "https://example.com/feed"),
        ("example.com:443/x", "https://example.com:443/x"),
    ])
    func addsOrUpgradesTheScheme(typed: String, expected: String) {
        #expect(SiteAddress.normalize(typed) == expected)
    }

    @Test(arguments: ["", "   ", "ftp://example.com/", "webcal://example.com/", "javascript://alert(1)", "example .com", "https://"])
    func refusesWhatIsNotAWebAddress(typed: String) {
        #expect(SiteAddress.normalize(typed) == nil)
    }

    @Test func lengthLimitCountsBothAddresses() {
        let url = "https://" + String(repeating: "a", count: 300)
        #expect(SiteAddress.fits(url: url, feedUrl: nil))
        #expect(!SiteAddress.fits(url: url, feedUrl: url))
    }
}

@Suite struct SiteTextTests {
    @Test func collapsesWhiteSpaceAndNewlines() {
        #expect(SiteText.clean("  A\n\tnew \r\n telescope  ", limit: 100) == "A new telescope")
    }

    @Test func dropsControlAndDirectionCharacters() {
        let text = "Safe\u{0007} \u{202E}txt.exe\u{202C} \u{200B}title\u{200F}\u{FEFF}"
        #expect(SiteText.clean(text, limit: 100) == "Safe txt.exe title")
    }

    @Test func keepsEmojiSequencesWhole() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let england = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        #expect(SiteText.clean("\(family) and \(england)", limit: 100) == "\(family) and \(england)")
    }

    @Test func markupIsKeptAsLiteralText() {
        // Shown verbatim, so it reads as written and is never interpreted.
        let text = "**Bold** [link](https://evil.example) <b>tag</b>"
        #expect(SiteText.clean(text, limit: 100) == text)
    }

    @Test func capsLongTextAtACharacterBoundary() {
        let long = String(repeating: "\u{1F600}", count: 20)
        let cut = SiteText.clean(long, limit: 10)
        #expect(cut.count == 10)
        #expect(cut.hasSuffix("…"))
        #expect(cut.dropLast().allSatisfy { $0 == "\u{1F600}" })
        #expect(SiteText.clean("exactly ten", limit: 11) == "exactly ten")
    }
}

@Suite struct ArticleLinkTests {
    @Test func acceptsHTTPSWithAHost() {
        #expect(ArticleLink.url("https://news.example.com/a?b=c#d")?.absoluteString == "https://news.example.com/a?b=c#d")
    }

    @Test(arguments: [
        "http://news.example.com/a",
        "javascript:alert(1)",
        "file:///etc/passwd",
        "data:text/html,hi",
        "tel:5551234",
        "/relative/path",
        "https://",
        "https://user:pass@news.example.com/",
        "seasign://open",
    ])
    func refusesEverythingElse(link: String) {
        #expect(ArticleLink.url(link) == nil)
    }

    @Test func refusesAbsurdlyLongLinks() {
        #expect(ArticleLink.url("https://a.example/" + String(repeating: "x", count: 3000)) == nil)
    }
}

@Suite struct CategoryNameTests {
    @Test func trimsCollapsesAndCaps() {
        #expect(CategoryName.clean("  Science \n news ") == "Science news")
        #expect(CategoryName.clean(String(repeating: "x", count: 40)).count == CategoryName.maxLength)
    }

    @Test func reusesAnExistingSpellingIgnoringCase() {
        #expect(CategoryName.clean("sci", existing: ["News", "Sci"]) == "Sci")
        #expect(CategoryName.clean("Local", existing: ["News", "Sci"]) == "Local")
    }

    @Test func distinctCategoriesAreSortedAndUnique() {
        #expect(CategoryName.distinct(["Sci", "news", "sci", "Art", "", "News"]) == ["Art", "news", "Sci"])
    }
}

@Suite struct HeadlinePickerTests {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    @Test func keepsItemsSinceTheStartOfYesterdayNewestFirst() {
        // 18:05 Sunday 15 November in New York; yesterday began at 05:00Z on the 14th.
        let now = instant("2026-11-15T23:05:00Z")
        let items = [
            entry("Old", published: "2026-11-14T04:59:59Z"),
            entry("Yesterday morning", published: "2026-11-14T05:00:00Z"),
            entry("Today", published: "2026-11-15T21:00:00Z"),
            entry("Last night", published: "2026-11-15T03:00:00Z"),
        ]
        let picked = HeadlinePicker.sinceYesterday(items, now: now, timeZone: newYork)
        #expect(picked.map(\.title) == ["Today", "Last night", "Yesterday morning"])
    }

    @Test func theSameInstantIsADifferentDayInAnotherZone() {
        // 23:05Z on the 15th is 08:05 on the 16th in Tokyo: yesterday there is
        // the 15th, which began at 15:00Z on the 14th.
        let now = instant("2026-11-15T23:05:00Z")
        let items = [
            entry("Morning of the 14th in New York", published: "2026-11-14T13:00:00Z"),
            entry("Evening of the 14th in New York", published: "2026-11-14T22:00:00Z"),
        ]
        #expect(HeadlinePicker.sinceYesterday(items, now: now, timeZone: newYork).count == 2)
        #expect(HeadlinePicker.sinceYesterday(items, now: now, timeZone: tokyo).map(\.title) == ["Evening of the 14th in New York"])
    }

    /// 1 November 2026 has 25 hours in New York: yesterday still starts at local midnight.
    @Test func daylightSavingDaysAreCalendarDays() {
        let afterFallBack = instant("2026-11-02T15:00:00Z")  // 10:00 EST on Monday the 2nd
        #expect(HeadlinePicker.startOfYesterday(now: afterFallBack, timeZone: newYork) == instant("2026-11-01T04:00:00Z"))
        let afterSpringForward = instant("2026-03-09T15:00:00Z")  // 11:00 EDT on Monday 9 March
        #expect(HeadlinePicker.startOfYesterday(now: afterSpringForward, timeZone: newYork) == instant("2026-03-08T05:00:00Z"))
    }

    @Test func sameTimeItemsKeepAFixedOrder() {
        let now = instant("2026-11-15T23:05:00Z")
        let items = [
            entry("B", published: "2026-11-15T20:00:00Z", link: "https://b.example/"),
            entry("A", published: "2026-11-15T20:00:00Z", link: "https://a.example/"),
        ]
        #expect(HeadlinePicker.sinceYesterday(items, now: now, timeZone: newYork).map(\.title) == ["A", "B"])
    }
}

@Suite struct HeadlineFitTests {
    @Test func takesTheLongestRunThatFits() {
        // One-line headlines of 14.5 with 28.5 between: 3 need 14.5*3 + 57 = 100.5.
        #expect(HeadlineFit.count(heights: [14.5, 14.5, 14.5, 14.5], spacing: 28.5, available: 100.5) == 3)
        #expect(HeadlineFit.count(heights: [14.5, 14.5, 14.5, 14.5], spacing: 28.5, available: 100) == 3)
        #expect(HeadlineFit.count(heights: [14.5, 14.5, 14.5, 14.5], spacing: 28.5, available: 99) == 2)
    }

    @Test func twoLineHeadlinesTakeMoreRoom() {
        #expect(HeadlineFit.count(heights: [29, 29, 29], spacing: 28.5, available: 120) == 2)
        // A long one never lets a later short one jump ahead: the run stops.
        #expect(HeadlineFit.count(heights: [14.5, 29, 14.5], spacing: 28.5, available: 60) == 1)
    }

    @Test func neverMoreThanTheLimitAndNothingInNoRoom() {
        let many = Array(repeating: CGFloat(14.5), count: 20)
        #expect(HeadlineFit.count(heights: many, spacing: 28.5, available: 10_000) == HeadlineFit.maxCount)
        #expect(HeadlineFit.count(heights: many, spacing: 28.5, available: 10) == 0)
        #expect(HeadlineFit.count(heights: [], spacing: 28.5, available: 500) == 0)
    }
}

@Suite struct FeedWordingTests {
    @Test func readingDateSaysWhereTheDateCameFrom() {
        let newYork = TimeZone(identifier: "America/New_York")!
        let published = ReadingDate(entry: entry("A", published: "2026-11-15T19:18:00Z"), timeZone: newYork)
        #expect(published.label == "Published")
        #expect(published.value == "Nov 15, 2026 2:18PM")
        let seen = ReadingDate(entry: entry("B", published: "2026-11-16T04:30:00Z", dateSource: .firstSeen), timeZone: newYork)
        #expect(seen.label == "First seen")
        #expect(seen.value == "Nov 15, 2026 11:30PM")
    }

    @Test func everyProblemHasItsOwnFixedMessage() {
        let messages = SiteProblem.allCases.map(\.message)
        #expect(Set(messages).count == messages.count)
        #expect(messages.allSatisfy { !$0.isEmpty && !$0.contains("http") })
        let adds: [FeedModel.AddProblem] = [
            .missingAddress, .missingCategory, .invalidAddress, .tooLong, .alreadyFollowed,
            .limitReached, .noArticles, .unavailable, .notSaved,
        ]
        #expect(Set(adds.map(\.message)).count == adds.count)
        #expect(FeedModel.AddProblem.site(.timeout).message == SiteProblem.timeout.message)
        #expect(FeedModel.AddProblem.limitReached.message.contains("50"))
    }

    @Test func statusLineReadsTheLastRead() {
        let site = UUID()
        let at = instant("2026-11-15T23:05:00Z")
        #expect(SiteStatusLine(status: nil, itemCount: 0).text == "Not read yet")
        #expect(!SiteStatusLine(status: nil, itemCount: 0).isProblem)
        #expect(SiteStatusLine(status: .init(site: site, problem: nil, checkedAt: at), itemCount: 0).text == "No articles in the last 7 days")
        #expect(SiteStatusLine(status: .init(site: site, problem: nil, checkedAt: at), itemCount: 1).text == "1 article in the last 7 days")
        #expect(SiteStatusLine(status: .init(site: site, problem: nil, checkedAt: at), itemCount: 12).text == "12 articles in the last 7 days")
        let failed = SiteStatusLine(status: .init(site: site, problem: .notHTML, checkedAt: at), itemCount: 3)
        #expect(failed.text == SiteProblem.notHTML.message)
        #expect(failed.isProblem)
    }
}
