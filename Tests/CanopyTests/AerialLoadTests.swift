import CanopyModel
import CanopyReference
import CanopyStore
import CanopySync
import Foundation
import Testing

@testable import Canopy

@MainActor
@Suite struct AerialLoadTests {
    func model() throws -> AppModel {
        AppModel(
            store: try LocalStore.inMemory(),
            players: .init(local: Player(id: PlayerID(rawValue: "local:test"), alias: "Tester", source: .local)))
    }

    @Test func theClientsAreKeptPerServerAndPlayer() throws {
        let model = try model()
        #expect(model.gerardus == nil)
        #expect(model.alignClient == nil)

        model.serverSettings.save(GerardusEndpoint("gerardus.local"))
        let first = try #require(model.gerardus)
        // Screens ask for the clients whenever they draw: each asking gets the same ones, and so the same connections.
        let again = try #require(model.gerardus)
        #expect(
            try #require(first.align.transport as? URLSessionGRPCTransport)
                === (again.align.transport as? URLSessionGRPCTransport))
        #expect(first.cache === again.cache)
        #expect(first.cache != nil)

        // Another server: new clients, and a cache of its own.
        model.serverSettings.save(GerardusEndpoint("other.local"))
        let other = try #require(model.gerardus)
        #expect(other.url != first.url)
        #expect(
            try #require(other.align.transport as? URLSessionGRPCTransport)
                !== (first.align.transport as? URLSessionGRPCTransport))
        #expect(other.cache?.directory != first.cache?.directory)
    }

    @Test func aLoadSaysWhatItChanged() {
        typealias Replacement = LocalStore.CandidateReplacement
        #expect(
            AppModel.describe(Replacement(replaced: 3, added: 571, gone: 3, samplesGone: 3))
                == ", replacing 3 sample candidates.")
        // The same area again: the same trees, nothing to say.
        #expect(AppModel.describe(Replacement(replaced: 571, added: 0, gone: 0, samplesGone: 0)) == ".")
        #expect(AppModel.describe(Replacement(replaced: 571, added: 4, gone: 0, samplesGone: 0)) == ", 4 of them new.")
        #expect(
            AppModel.describe(Replacement(replaced: 571, added: 0, gone: 2, samplesGone: 0))
                == "; 2 found before are gone.")
        #expect(
            AppModel.describe(Replacement(replaced: 571, added: 4, gone: 2, samplesGone: 0))
                == ", 4 of them new; 2 found before are gone.")
    }

    @Test func progressSaysWhereThePointsComeFrom() {
        #expect(AppModel.describe(.downloading(points: 12_000)).hasPrefix("Downloading"))
        #expect(AppModel.describe(.readingSaved(points: 12_000)).hasPrefix("Reading"))
        #expect(AppModel.describe(.readingSaved(points: 12_000)).contains("saved"))
    }

    @Test func theTimingLineNamesEachStep() throws {
        var result = AerialTrees.SiteResult(
            site: try Site(fields: []), candidates: [], tiles: [], attribution: [], pointCount: 270_132)
        result.timings = [
            .init(step: "site", seconds: 0.12), .init(step: "georeference", seconds: 0),
            .init(step: "points", seconds: 1.43), .init(step: "detection", seconds: 0.38),
        ]
        let line = AppModel.describe(result, total: .milliseconds(2_100))
        #expect(line.hasPrefix("2.1 s: site 0.12, georeference 0.00, points 1.43 ("))
        #expect(line.contains("downloaded"))
        #expect(line.hasSuffix("detection 0.38"))
        result.fromCache = true
        #expect(AppModel.describe(result, total: .milliseconds(300)).contains("saved"))
    }
}
