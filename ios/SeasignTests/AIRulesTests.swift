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
        #expect(cut.trim.message == "Interests are cut to 80 characters (an emoji can count as several).")
    }

    // The API's rule: at most 400 UTF-16 units as sent, and 1 to 80 code
    // points (Unicode scalars). These sit on both sides of the boundary
    // with characters made of several scalars.

    /// A flag is two scalars (regional indicators): 40 fit, 41 do not.
    @Test func flagsAreCountedAsTheAPICountsThem() {
        let flag = "\u{1F1FA}\u{1F1F8}"
        let forty = String(repeating: flag, count: 40)
        #expect(forty.count == 40 && forty.unicodeScalars.count == 80 && forty.utf16.count == 160)
        let fits = InterestList.parse(forty)
        #expect(fits.interests == [forty])
        #expect(fits.trim.isEmpty)

        let cut = InterestList.parse(String(repeating: flag, count: 41))
        #expect(cut.interests == [forty])
        #expect(cut.trim.shortened == 1)
        // Swift counted 41 characters, under the old 80-character rule.
        #expect(String(repeating: flag, count: 41).count == 41)
    }

    /// A family is seven scalars joined by ZWJ: 11 fit (77), a 12th does not
    /// and is not split, so no half family is sent.
    @Test func familyEmojiAreNeverSplit() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        #expect(family.count == 1 && family.unicodeScalars.count == 7)
        let eleven = String(repeating: family, count: 11)
        #expect(InterestList.parse(eleven).interests == [eleven])
        #expect(InterestList.parse(eleven).trim.isEmpty)

        let twelve = InterestList.parse(String(repeating: family, count: 12))
        #expect(twelve.interests == [eleven])
        #expect(twelve.trim.shortened == 1)

        // 77 scalars of families plus "abc" is exactly 80; one letter more is
        // cut back to 80 at the letter, not inside a family.
        #expect(InterestList.parse(eleven + "abc").interests == [eleven + "abc"])
        #expect(InterestList.parse(eleven + "abcd").interests == [eleven + "abc"])
    }

    /// A subdivision flag (England) is seven scalars, tag characters included.
    @Test func tagSequenceFlagsKeepTheirTags() {
        let england = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        #expect(england.unicodeScalars.count == 7)
        let interest = String(repeating: "a", count: 73) + england
        #expect(InterestList.parse(interest).interests == [interest])
        let over = String(repeating: "a", count: 74) + england
        #expect(InterestList.parse(over).interests == [String(repeating: "a", count: 74)])
    }

    /// "é" written as e + combining acute is two scalars: 40 fit, 41 do not.
    @Test func combiningSequencesAreCountedByScalar() {
        let e = "e\u{0301}"
        let forty = String(repeating: e, count: 40)
        #expect(InterestList.parse(forty).interests == [forty])
        let cut = InterestList.parse(String(repeating: e, count: 41))
        #expect(cut.interests == [forty])
        #expect(cut.interests[0].unicodeScalars.count == 80)
    }

    /// A cut that ends at a space does not leave it at the end.
    @Test func aCutEndingInASpaceIsTrimmed() {
        let text = String(repeating: "a", count: 79) + " bcd"
        #expect(InterestList.parse(text).interests == [String(repeating: "a", count: 79)])
    }

    /// One character of more than 80 scalars cannot be cut to fit: it is
    /// left out and Settings says it is too long, instead of the API
    /// refusing every search with it.
    @Test func anInterestNoCutCanFitIsLeftOutWithAMessage() {
        let tower = "e" + String(repeating: "\u{0301}", count: 80)
        #expect(tower.count == 1 && tower.unicodeScalars.count == 81)
        let parsed = InterestList.parse(tower + ", tide pools")
        #expect(parsed.interests == ["tide pools"])
        #expect(parsed.trim.tooLong == 1)
        #expect(parsed.trim.shortened == 0)
        #expect(parsed.trim.message == "One interest is too long to use and was left out.")
        #expect(InterestList.parse(tower + "," + tower).trim.message == "2 interests are too long to use and were left out.")
        // Exactly 80 scalars in one character fits.
        let eighty = "e" + String(repeating: "\u{0301}", count: 79)
        #expect(InterestList.parse(eighty).interests == [eighty])
    }

    /// Everything `parse` returns meets the API's rule, for a mix of scripts
    /// and emoji at every length up to well past the limit.
    @Test func everyParsedInterestFitsTheAPI() {
        let pieces = ["a", " ", "\u{1F1EF}\u{1F1F5}", "e\u{0301}", "\u{1F469}\u{1F3FD}\u{200D}\u{1F52C}", "漢", "\u{1F600}", "ß"]
        for length in 1...120 {
            let text = (0..<length).map { pieces[$0 % pieces.count] }.joined()
            for interest in InterestList.parse(text).interests {
                #expect(InterestList.fits(interest))
                #expect((1...80).contains(interest.unicodeScalars.count))
                #expect(interest.utf16.count <= 400)
                #expect(interest == interest.trimmingCharacters(in: .whitespaces))
            }
        }
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

    /// "Could not read the Keychain" is not "no key": it never asks for the
    /// key, whatever the interests.
    @Test func anUnreadableKeychainIsNotAMissingKey() throws {
        #expect(AIPrecondition(key: .unknown, interests: ["x"]) == .keyUnreadable)
        #expect(AIPrecondition(key: .unknown, interests: []) == .keyUnreadable)
        #expect(AIPrecondition(key: .missing, interests: ["x"]) == .needsKey)
        for text in [AIPrecondition.keyUnreadable.message, AISearchProblem.keyUnreadable.message] {
            let message = try #require(text)
            #expect(!message.localizedCaseInsensitiveContains("add your"))
            #expect(!message.localizedCaseInsensitiveContains("enter"))
        }
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
        #expect(SearchDay.ianaName(TimeZone(secondsFromGMT: 0)!) == "UTC")
    }

    /// The API refuses (400) a zone it does not know, which would refuse
    /// every search; a doubtful name is left out instead.
    @Test(arguments: [
        ("America/Chicago", "America/Chicago"),
        ("Asia/Tokyo", "Asia/Tokyo"),
        // Not in Foundation's list (it has Asia/Calcutta) but what phones
        // in India report, and an IANA name the API knows.
        ("Asia/Kolkata", "Asia/Kolkata"),
        ("America/Argentina/Buenos_Aires", "America/Argentina/Buenos_Aires"),
        ("GMT", "UTC"),
        ("Etc/UTC", "UTC"),
        ("UTC", "UTC"),
    ] as [(String, String?)])
    func knownNamesAreKept(identifier: String, expected: String?) {
        #expect(SearchDay.ianaName(identifier: identifier) == expected)
    }

    @Test(arguments: [
        "", "GMT-0500", "GMT+05:30", "+05:00", "EST", "CST", "PST",
        "Mars/Olympus_Mons", "America/chicago", "America/Not_A_Zone", "Asia/", "America", "America/Chicago ", " America/Chicago",
        "America/Chicago\u{0}", "Europe/Kyiv\u{200B}", "Amérique/Montréal",
        String(repeating: "A", count: 65),
    ])
    func doubtfulNamesAreLeftOut(identifier: String) {
        #expect(SearchDay.ianaName(identifier: identifier) == nil)
    }

    /// Whatever Foundation calls the phone's zone, what is sent is UTC or a
    /// known name within the API's 64 characters.
    @Test func everyKnownNameFitsTheAPI() {
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            guard let name = SearchDay.ianaName(identifier: identifier) else { continue }
            #expect(name.utf16.count <= 64)
            #expect(name == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(name))
        }
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
        key: KeyStatus = .saved,
        interests: [String] = ["tide pools"],
        cap: Int = 3,
        used: Int = 0,
        lastSentAt: Date? = nil,
        keyRefused: Bool = false,
        isSearching: Bool = false
    ) -> SearchGate {
        SearchGate(
            mode: mode, key: key, interests: interests, cap: cap, usedToday: used,
            lastSentAt: lastSentAt, keyRefused: keyRefused, isSearching: isSearching
        )
    }

    @Test func myListModeNeverSends() {
        for trigger in [SearchGate.Trigger.automatic, .manual] {
            #expect(gate(mode: .myList).decide(trigger, now: now) == .myListMode)
        }
    }

    @Test func needsKeyAndInterests() {
        #expect(gate(key: .missing).decide(.manual, now: now) == .notReady(.needsKey))
        #expect(gate(interests: []).decide(.manual, now: now) == .notReady(.needsInterests))
    }

    /// A Keychain that cannot be read never sends, by either trigger.
    @Test func anUnknownKeyNeverSends() {
        for trigger in [SearchGate.Trigger.automatic, .manual] {
            #expect(gate(key: .unknown).decide(trigger, now: now) == .notReady(.keyUnreadable))
        }
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
