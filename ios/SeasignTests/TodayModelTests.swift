import Foundation
import SwiftData
import Testing
import UIKit

@testable import Seasign

@Suite struct SkyAPITests {
    @Test func unknownZipIsItsOwnFailure() async {
        let api = stubbedSkyAPI()
        await #expect(throws: SeasignAPI.SkyFailure.unknownZip) {
            try await api.sky(zip: "00601")
        }
    }

    @Test func unreachableServerIsUnavailable() async {
        let api = stubbedSkyAPI(SkyStubTransport(offline: true))
        await #expect(throws: SeasignAPI.SkyFailure.unavailable) {
            try await api.sky(zip: "10001")
        }
    }
}

@Suite @MainActor struct TodayModelTests {
    private let fixedNow = instant("2026-11-15T23:05:00Z")

    private func model(
        context: ModelContext,
        transport: SkyStubTransport = SkyStubTransport()
    ) -> TodayModel {
        let now = fixedNow
        return TodayModel(api: stubbedSkyAPI(transport), context: context, now: { now })
    }

    @Test func aFreshInstallStartsInChicagoWithNoSkyYet() throws {
        let model = model(context: try inMemoryContext())
        #expect(model.zip == "60611")
        #expect(SkyStore.defaultZip == "60611")
        #expect(model.snapshot == nil)
        #expect(model.placeDescription == nil)
    }

    @Test func aRemovedZipStaysRemoved() throws {
        let context = try inMemoryContext()
        let model = model(context: context)
        model.clearZip()
        #expect(model.zip == nil)

        // The default is only written when the settings row is first created.
        let relaunched = self.model(context: context)
        #expect(relaunched.zip == nil)
        #expect(SkyStore(context: context).zip == nil)
    }

    @Test func anExistingZipIsNotReplacedByTheDefault() throws {
        let context = try inMemoryContext()
        context.insert(Settings(zip: "10001"))
        try context.save()
        #expect(model(context: context).zip == "10001")
    }

    @Test func savingAZipFetchesAndCachesTheSky() async throws {
        let context = try inMemoryContext()
        let model = model(context: context)
        try await model.saveZip(" 10001 ")
        #expect(model.zip == "10001")
        #expect(model.snapshot?.current.temperatureF == 43.4)
        #expect(model.placeDescription == "New York, New York")

        // A new launch draws from the cache before any request, even offline.
        let relaunched = self.model(context: context, transport: SkyStubTransport(offline: true))
        #expect(relaunched.zip == "10001")
        #expect(relaunched.snapshot == model.snapshot)
        await relaunched.refresh(force: true)
        #expect(relaunched.snapshot == model.snapshot)
    }

    @Test func unknownZipKeepsThePreviousOneAndExplains() async throws {
        let model = model(context: try inMemoryContext())
        try await model.saveZip("10001")
        await #expect(throws: TodayModel.ZipProblem.unknown) {
            try await model.saveZip("00601")
        }
        #expect(model.zip == "10001")
        #expect(model.snapshot?.zip == "10001")
        #expect(TodayModel.ZipProblem.unknown.message == "We couldn't find that zip code. Try a nearby one.")
    }

    @Test func malformedZipIsRejectedWithoutARequest() async throws {
        // Offline transport: a request would surface as `.unavailable`.
        let model = model(context: try inMemoryContext(), transport: SkyStubTransport(offline: true))
        model.clearZip()
        for text in ["", "1000", "100011", "1000a", "１２３４５"] {
            await #expect(throws: TodayModel.ZipProblem.notFiveDigits, "\(text)") {
                try await model.saveZip(text)
            }
        }
        await #expect(throws: TodayModel.ZipProblem.unavailable) {
            try await model.saveZip("10001")
        }
        #expect(model.zip == nil)
    }

    @Test func changingTheZipReplacesTheCachedSky() async throws {
        let context = try inMemoryContext()
        let other = skyJSON10001.replacingOccurrences(of: "\"zip\": \"10001\"", with: "\"zip\": \"94103\"")
        let model = model(
            context: context,
            transport: SkyStubTransport(responses: ["10001": skyJSON10001, "94103": other])
        )
        try await model.saveZip("10001")
        try await model.saveZip("94103")
        #expect(model.zip == "94103")
        let rows = try context.fetch(FetchDescriptor<CachedSky>())
        #expect(rows.map(\.zip) == ["94103"])
        #expect(try context.fetch(FetchDescriptor<Settings>()).count == 1)
    }

    @Test func removingTheZipClearsTheSky() async throws {
        let context = try inMemoryContext()
        let model = model(context: context)
        try await model.saveZip("10001")
        model.clearZip()
        #expect(model.zip == nil)
        #expect(model.snapshot == nil)
        #expect(try context.fetch(FetchDescriptor<CachedSky>()).isEmpty)
    }

    @Test func refreshSkipsAFreshSkyAndFetchesAStaleOne() async throws {
        let context = try inMemoryContext()
        let first = model(context: context)
        try await first.saveZip("10001")

        // Same clock: fresh, so an offline refresh is not even attempted.
        let warmer = skyJSON10001.replacingOccurrences(of: "43.4", with: "51.0")
        let transport = SkyStubTransport(responses: ["10001": warmer])
        let fresh = model(context: context, transport: transport)
        await fresh.refresh()
        #expect(fresh.snapshot?.current.temperatureF == 43.4)

        // Eleven minutes later it is stale and is fetched again.
        let later = fixedNow.addingTimeInterval(11 * 60)
        let stale = TodayModel(api: stubbedSkyAPI(transport), context: context, now: { later })
        await stale.refresh()
        #expect(stale.snapshot?.current.temperatureF == 51.0)
        #expect(stale.snapshot?.fetchedAt == later)
    }
}

@Suite struct DesignTests {
    /// A misspelt PostScript name falls back to the system font silently.
    @Test func bundledFontsLoad() {
        for name in FontName.all {
            #expect(UIFont(name: name, size: 12) != nil, "font \(name) is not registered")
        }
    }

    /// The faces Today takes from iOS. Printed so the log shows what
    /// resolved on each runtime.
    @Test func systemFacesResolve() {
        for name in FontName.system {
            let font = UIFont(name: name, size: 12)
            #expect(font != nil, "font \(name) is not on this runtime")
            #expect(font?.fontName == name)
            print("system face \(name) -> \(font?.fontName ?? "nil") (\(font?.familyName ?? "nil")) on \(ProcessInfo.processInfo.operatingSystemVersionString)")
        }
    }

    @Test func everyIconHasAPath() {
        let rect = CGRect(x: 0, y: 0, width: 20, height: 20)
        for icon in LineIcon.allCases {
            let bounds = icon.path(in: rect).boundingRect
            #expect(!bounds.isEmpty)
            #expect(rect.insetBy(dx: -0.5, dy: -0.5).contains(bounds), "\(icon) leaves its frame")
        }
    }
}

@Suite struct CapsWrapperTests {
    /// One unit per character, so widths are easy to read.
    private func wrap(_ text: String, width: CGFloat, maxLines: Int = 2) -> [String] {
        CapsWrapper.wrap(text, width: width, maxLines: maxLines) { CGFloat($0.count) }
    }

    @Test func shortTextStaysOnOneLine() {
        #expect(wrap("ALPHAPROOF CODE", width: 20) == ["ALPHAPROOF CODE"])
    }

    @Test func breaksAtSpacesWithinTheWidth() {
        #expect(wrap("A SHORT EXPLAINER ON HOW", width: 12) == ["A SHORT", "EXPLAINER…"])
        #expect(wrap("ONE TWO THREE FOUR", width: 9) == ["ONE TWO", "THREE…"])
        #expect(wrap("ONE TWO THREE FOUR", width: 9, maxLines: 3) == ["ONE TWO", "THREE", "FOUR"])
    }

    @Test func overflowEndsInAnEllipsisThatFits() {
        let lines = wrap("AAAA BBBB CCCC DDDD EEEE", width: 9)
        #expect(lines == ["AAAA BBBB", "CCCC…"])
        #expect(lines.allSatisfy { $0.count <= 9 })
    }

    @Test func aWordWiderThanTheLineIsKeptWhole() {
        #expect(wrap("SUPERCALIFRAGILISTIC OK", width: 5) == ["SUPERCALIFRAGILISTIC", "OK"])
    }

    @Test func aLongWordIsBrokenBetweenCharactersWhenAsked() {
        func wrap(_ text: String, width: CGFloat, maxLines: Int) -> [String] {
            CapsWrapper.wrap(text, width: width, maxLines: maxLines, breakingLongWords: true) { CGFloat($0.count) }
        }
        #expect(wrap("SUPERCALIFRAGILISTIC OK", width: 5, maxLines: 5) == ["SUPER", "CALIF", "RAGIL", "ISTIC", "OK"])
        // Out of lines inside the word: the ellipsis still fits.
        #expect(wrap("SUPERCALIFRAGILISTIC OK", width: 5, maxLines: 2) == ["SUPER", "CALI…"])
        // Text written without spaces.
        let japanese = wrap("東京都の天気予報と週間予報", width: 4, maxLines: 2)
        #expect(japanese == ["東京都の", "天気予…"])
        // A link after a short word starts its own line.
        let link = wrap("SEE HTTPS://ZOOM.US/J/8123456789", width: 10, maxLines: 3)
        #expect(link.first == "SEE")
        for lines in [japanese, link] {
            #expect(lines.allSatisfy { $0.count <= 10 })
        }
    }

    @Test func emptyTextHasNoLines() {
        #expect(wrap("   ", width: 10).isEmpty)
        #expect(wrap("WORD", width: 10, maxLines: 0).isEmpty)
    }

    @Test func measuresWithTheBundledFont() {
        let narrow = CapsWrapper.width(of: "SEASIGN", size: 11, tracking: 0)
        let tracked = CapsWrapper.width(of: "SEASIGN", size: 11, tracking: 0.2)
        // Six gaps between seven letters.
        #expect(abs((tracked - narrow) - 6 * 11 * 0.2) < 0.01)
    }
}
