import Testing
import Foundation
@testable import Brain
import Domain

/// The factory decides whether this Mac has a brain at all, and everything the app does for a keyless user
/// hangs off that one answer. It used to answer yes regardless, which is why a stranger's first morning read
/// "The brain rejected your key" about a key they had never typed.
@Suite struct BrainFactoryTests {

    @Test func aCloudEngineWithNoKeyMakesNoBrainAtAll() {
        for e in [BrainEngine.openai, .anthropic, .openrouter] {
            #expect(BrainFactory.make(BrainConfig(engine: e, model: e.defaultModel), key: "") == nil,
                    "\(e.rawValue) with no key must be no brain, not a brain that sends Bearer none")
            #expect(BrainFactory.make(BrainConfig(engine: e, model: e.defaultModel), key: "sk-whatever") != nil,
                    "\(e.rawValue) with a key is a brain as before")
        }
    }

    @Test func theOnesThatNeedAKeySayExactlyWhichTheyAre() {
        #expect(BrainEngine.allCases.filter(\.needsKey).map(\.rawValue) == ["openai", "anthropic", "openrouter"])
        #expect(BrainEngine.local.needsKey == false && BrainEngine.none.needsKey == false && BrainEngine.custom.needsKey == false,
                "a local server and the on-device reader are nobody's subscription")
    }

    @Test func aCustomEndpointStillMakesABrainWithoutAKey() {
        let b = BrainFactory.make(BrainConfig(engine: .custom, model: "local", customBaseURL: "http://127.0.0.1:1234/v1"), key: "")
        #expect(b != nil, "LM Studio and friends legitimately want no key")
    }

    @Test func theTwoThatCostNothingAreOfferedFirst() {
        #expect(BrainEngine.allCases.prefix(2).map(\.rawValue) == ["none", "local"],
                "the grid is rendered in this order, and a stranger should meet a choice they can make")
        #expect(BrainEngine.allCases.firstIndex(of: .none)! < BrainEngine.allCases.firstIndex(of: .local)!,
                "and \"no brain\" comes before \"this Mac only\" while it is the one that does more: it writes the day's note and the status block, and this Mac's model cannot build notes at all")
    }

    @Test func everyEngineCarriesItsOwnCaptionSoNoScreenWritesItsOwn() {
        for e in BrainEngine.allCases { #expect(!e.caption.isEmpty) }
        #expect(BrainEngine.local.caption.contains("No key"), "the one that needs no key must say so — it used to say the opposite")
        #expect(!BrainEngine.local.caption.contains("API key"))
        #expect(BrainEngine.none.caption.contains("note each day"))
        #expect(BrainEngine.local.caption.contains("no notes or cards yet"),
                "the caption must not promise notes this engine has never once produced")
    }

    @Test func theLocalAndNoBrainEnginesAreBuiltElsewhereOrNotAtAll() {
        #expect(BrainFactory.make(BrainConfig(engine: .local, model: "gemma-4-e4b"), key: "") == nil, "the app builds LocalBrain itself — it needs the reader")
        #expect(BrainFactory.make(BrainConfig(engine: .none, model: ""), key: "") == nil)
    }
}
