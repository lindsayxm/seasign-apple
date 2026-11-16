import Foundation
import Testing

@testable import Seasign

@Suite struct InterestListTests {
    @Test func splitsTrimsAndDropsEmptiesAndRepeats() {
        let parsed = InterestList.parse("  tide pools, ,New Telescopes,new telescopes ,, lake\n ice ,TIDE POOLS")
        #expect(parsed.interests == ["tide pools", "New Telescopes", "lake ice"])
        #expect(parsed.trim.isEmpty)
        #expect(parsed.trim.message == nil)
    }

    @Test func nothingTypedIsNoInterests() {
        #expect(InterestList.parse("").interests.isEmpty)
        #expect(InterestList.parse(" , ,\n,").interests.isEmpty)
    }

    @Test func invisibleCharactersAreDropped() {
        #expect(InterestList.parse("tide\u{200B} pools\u{202E}").interests == ["tide pools"])
    }

    @Test func atMostTwentyAndEightyCharactersWithAMessage() {
        let many = (1...25).map { "topic \($0)" }.joined(separator: ",")
        let parsed = InterestList.parse(many)
        #expect(parsed.interests.count == 20)
        #expect(parsed.interests.last == "topic 20")
        #expect(parsed.trim.dropped == 5)
        #expect(parsed.trim.message == "Only the first 20 interests are used.")

        let long = String(repeating: "a", count: 81) + ", short"
        let cut = InterestList.parse(long)
        #expect(cut.interests == [String(repeating: "a", count: 80), "short"])
        #expect(cut.trim.shortened == 1)
        #expect(cut.trim.message == "Interests are cut to 80 characters.")
    }

    /// Repeats do not use up the twenty.
    @Test func repeatsDoNotCountTowardTheLimit() {
        let text = (Array(repeating: "same", count: 30) + (1...20).map { "t\($0)" }).joined(separator: ",")
        let parsed = InterestList.parse(text)
        #expect(parsed.interests.count == 20)
        #expect(parsed.interests.first == "same")
        #expect(parsed.trim.dropped == 1)
    }
}

@Suite struct AIPreconditionTests {
    @Test func needsAKeyAndAnInterest() {
        #expect(AIPrecondition(hasKey: true, interests: ["x"]) == .ready)
        #expect(AIPrecondition(hasKey: false, interests: ["x"]) == .needsKey)
        #expect(AIPrecondition(hasKey: true, interests: []) == .needsInterests)
        #expect(AIPrecondition(hasKey: false, interests: []) == .needsKeyAndInterests)
        #expect(AIPrecondition.ready.message == nil)
        #expect(AIPrecondition.needsKey.message?.contains("API key") == true)
        #expect(AIPrecondition.needsInterests.message?.contains("interest") == true)
    }
}

@Suite struct APIKeyTests {
    @Test func shapeIsSixteenToFiveHundredTwelvePrintableASCII() {
        #expect(APIKey(typed: fakeKey) != nil)
        #expect(APIKey(typed: "  " + fakeKey + "\n")?.secret == fakeKey)
        #expect(APIKey(typed: String(repeating: "k", count: 15)) == nil)
        #expect(APIKey(typed: String(repeating: "k", count: 16)) != nil)
        #expect(APIKey(typed: String(repeating: "k", count: 512)) != nil)
        #expect(APIKey(typed: String(repeating: "k", count: 513)) == nil)
        #expect(APIKey(typed: "test key not real 0000") == nil)
        #expect(APIKey(typed: "test-key-not-réal-0000") == nil)
        #expect(APIKey(typed: "test-key-not-real\t0000") == nil)
    }

    @Test func neverPrintsItself() {
        let key = APIKey(typed: fakeKey)!
        #expect(String(describing: key) == "<redacted>")
        #expect(String(reflecting: key) == "<redacted>")
        #expect("\(key)" == "<redacted>")
        var dumped = ""
        dump(key, to: &dumped)
        #expect(!dumped.contains(fakeKey))
        #expect(Mirror(reflecting: key).children.isEmpty)
    }
}

@Suite struct SearchDayTests {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    @Test func theDayIsTheLocalCalendarDay() {
        // 23:30 in New York on the 15th is already the 16th in UTC.
        let late = instant("2026-11-16T04:30:00Z")
        #expect(SearchDay.key(late, timeZone: newYork) == "2026-11-15")
        #expect(SearchDay.key(late, timeZone: TimeZone(identifier: "UTC")!) == "2026-11-16")
        #expect(SearchDay.key(instant("2026-11-16T05:00:00Z"), timeZone: newYork) == "2026-11-16")
        #expect(SearchDay.key(late, timeZone: tokyo) == "2026-11-16")
    }

    @Test func onlyIANANamesAreSent() {
        #expect(SearchDay.ianaName(newYork) == "America/New_York")
        #expect(SearchDay.ianaName(TimeZone(identifier: "UTC")!) == "UTC")
        #expect(SearchDay.ianaName(TimeZone(secondsFromGMT: -5 * 3600)!) == nil)
    }
}

@Suite struct DailyCapTests {
    @Test func defaultAndRange() {
        #expect(DailyCap.clamp(nil) == 3)
        #expect(DailyCap.clamp(0) == 1)
        #expect(DailyCap.clamp(-4) == 1)
        #expect(DailyCap.clamp(25) == 20)
        #expect(DailyCap.clamp(7) == 7)
    }

    @Test func searchesAreSpreadThroughTheDay() {
        #expect(DailyCap.spacing(cap: 3) == 8 * 3600)
        #expect(DailyCap.spacing(cap: 1) == 24 * 3600)
        #expect(DailyCap.spacing(cap: 20) == 72 * 60)
        // Never closer than the feed's own cadence.
        #expect(DailyCap.spacing(cap: 20) >= FeedModel.refreshInterval)
    }

    @Test func usageLine() {
        #expect(DailyCap.usage(used: 2, cap: 3) == "2 of 3 searches used today")
        #expect(DailyCap.usage(used: 0, cap: 1) == "0 of 1 search used today")
    }
}

@Suite struct SearchGateTests {
    private let now = instant("2026-11-15T23:05:00Z")

    private func gate(
        mode: AIMode = .aiSearch,
        hasKey: Bool = true,
        interests: [String] = ["tide pools"],
        cap: Int = 3,
        used: Int = 0,
        lastSentAt: Date? = nil,
        keyRefused: Bool = false,
        isSearching: Bool = false
    ) -> SearchGate {
        SearchGate(
            mode: mode, hasKey: hasKey, interests: interests, cap: cap, usedToday: used,
            lastSentAt: lastSentAt, keyRefused: keyRefused, isSearching: isSearching
        )
    }

    @Test func myListModeNeverSends() {
        for trigger in [SearchGate.Trigger.automatic, .manual] {
            #expect(gate(mode: .myList).decide(trigger, now: now) == .myListMode)
        }
    }

    @Test func needsKeyAndInterests() {
        #expect(gate(hasKey: false).decide(.manual, now: now) == .notReady(.needsKey))
        #expect(gate(interests: []).decide(.manual, now: now) == .notReady(.needsInterests))
    }

    @Test func theCapHoldsForBothTriggers() {
        #expect(gate(used: 2).decide(.automatic, now: now) == .send)
        #expect(gate(used: 3).decide(.automatic, now: now) == .capReached)
        #expect(gate(used: 3).decide(.manual, now: now) == .capReached)
        #expect(gate(cap: 1, used: 1).decide(.manual, now: now) == .capReached)
    }

    @Test func automaticSearchesAreSpacedAndManualOnesAreNot() {
        let last = now.addingTimeInterval(-7 * 3600)
        #expect(gate(lastSentAt: last).decide(.automatic, now: now) == .tooSoon(until: last.addingTimeInterval(8 * 3600)))
        #expect(gate(lastSentAt: last).decide(.manual, now: now) == .send)
        #expect(gate(lastSentAt: now.addingTimeInterval(-8 * 3600)).decide(.automatic, now: now) == .send)
        // A higher cap means closer spacing.
        #expect(gate(cap: 12, lastSentAt: now.addingTimeInterval(-2 * 3600)).decide(.automatic, now: now) == .send)
        // A clock set back before the last search waits.
        if case .tooSoon = gate(lastSentAt: now.addingTimeInterval(3600)).decide(.automatic, now: now) {} else {
            Issue.record("expected tooSoon")
        }
    }

    @Test func aRefusedKeyStopsAutomaticSearchesOnly() {
        #expect(gate(keyRefused: true).decide(.automatic, now: now) == .stoppedAfterInvalidKey)
        #expect(gate(keyRefused: true).decide(.manual, now: now) == .send)
    }

    @Test func oneSearchAtATime() {
        #expect(gate(isSearching: true).decide(.manual, now: now) == .alreadySearching)
    }
}

@Suite struct AISearchProblemTests {
    @Test func onlyAnswersThatProveNothingWasBilledGiveTheSearchBack() {
        let refunded = SeasignAPI.DiscoverFailure.allCases.filter { AISearchProblem($0).refundsSearch }
        #expect(refunded == [.invalidRequest, .invalidKey])
    }

    @Test func onlyAnInvalidKeyStopsAutomaticSearches() {
        let stopping = SeasignAPI.DiscoverFailure.allCases.filter { AISearchProblem($0).stopsAutomaticSearch }
        #expect(stopping == [.invalidKey])
    }

    @Test func messagesAreFixedAndRoundTrip() {
        #expect(AISearchProblem.invalidKey.message == "That key was refused by the provider. Check the key and the provider.")
        #expect(AISearchProblem.quotaExceeded.message == "Your provider account is out of credit.")
        for failure in SeasignAPI.DiscoverFailure.allCases {
            let problem = AISearchProblem(failure)
            #expect(!problem.message.isEmpty)
            #expect(AISearchProblem(rawValue: problem.rawValue) == problem)
        }
        #expect(AISearchProblem(rawValue: "keyUnreadable") == nil)
        #expect(AISearchProblem(rawValue: "key_unreadable") == .keyUnreadable)
    }
}

@Suite struct AILabelTests {
    @Test func spokenLabelsSayAIFound() {
        #expect(AILabel.accessibility(title: "Tide pools", isAI: true) == "AI-found: Tide pools")
        #expect(AILabel.accessibility(title: "Tide pools", isAI: false) == "Tide pools")
        #expect(AILabel.foundBy(.openai) == "AI search · OpenAI")
        #expect(AILabel.foundBy(nil) == "AI search")
    }

    @Test func anInterestIsNeverTheSameChoiceAsACategoryOfTheSameName() {
        let site: CategoryChoice = "Space"
        let interest = CategoryChoice(name: "space", isAI: true)
        #expect(!site.matches(interest))
        #expect(interest.matches(CategoryChoice(name: "SPACE", isAI: true)))
        #expect(interest.label == "AI · space")
        #expect(CategoryChoice(name: "", isAI: true).label == "AI")
        let distinct = CategoryChoice.distinct([interest, "Sci", site, "sci", CategoryChoice(name: "Space", isAI: true)])
        #expect(distinct == ["Sci", "Space", interest])
        #expect(ArticleQuery(category: interest).matches(title: "t", source: "s", category: "Space", isAI: true))
        #expect(!ArticleQuery(category: interest).matches(title: "t", source: "s", category: "Space", isAI: false))
        #expect(!ArticleQuery(category: site).matches(title: "t", source: "s", category: "Space", isAI: true))
    }

    @Test func spellingsOfOneAddressMatch() {
        let key = ArticleLink.matchKey("https://www.Example.com/a/b/")
        #expect(ArticleLink.matchKey("https://example.com/a/b") == key)
        #expect(ArticleLink.matchKey("http://example.com/a/b#top") == key)
        #expect(ArticleLink.matchKey("https://example.com/a/b?id=2") != key)
        #expect(ArticleLink.matchKey("https://example.com/a/c") != key)
    }
}
