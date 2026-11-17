import Foundation
import Testing

@testable import CanopyModel

/// Trees of several stems: their equivalent DBH, a second scan's stems, and the `stems` field they are shared in.
@Suite struct StemTests {
    let stems = [
        StemMeasure(diameter: Quantity(0.30, uncertainty: 0.01), east: 0, north: 0),
        StemMeasure(diameter: Quantity(0.40, uncertainty: 0.01), east: 1.2, north: 0.4),
    ]

    @Test func theEquivalentDBHIsTheRootOfTheSumOfTheSquares() throws {
        let dbh = try #require(DBH.equivalent(of: stems.map(\.diameter), method: .lidarCircleFit))
        #expect(abs(dbh.diameter.value - 0.5) < 1e-9)
        // (0.3 · 0.01)² + (0.4 · 0.01)² = 0.005², over 0.5.
        #expect(abs(dbh.diameter.uncertainty - 0.01) < 1e-9)
        #expect(dbh.height == DBH.standardHeight)
        let one = try #require(DBH.equivalent(of: [Quantity(0.3, uncertainty: 0.02)], method: .tape))
        #expect(one.diameter == Quantity(0.3, uncertainty: 0.02))
        #expect(DBH.equivalent(of: [], method: .tape) == nil)
    }

    @Test func aSecondScanReplacesTheStemsItMeasuredAgainAndAddsTheRest() {
        let again = StemMeasure(diameter: Quantity(0.41, uncertainty: 0.005), east: 1.25, north: 0.35)
        let missed = StemMeasure(diameter: Quantity(0.2, uncertainty: 0.01), east: -1, north: 2)
        let merged = StemMeasure.merging(stems, with: [again, missed])
        #expect(merged == [stems[0], again, missed])
    }

    @Test func measuringSeveralStemsKeepsThemOnTheTreeAndSharesThem() throws {
        let tree = Sample.detectedTree()
        let dbh = try #require(DBH.equivalent(of: stems.map(\.diameter), method: .lidarCircleFit))
        let observation = Sample.observation(
            .trunkMeasured(treeID: tree.id, dbh: dbh, lean: nil, evidence: Sample.evidence, stems: stems))
        let state = CensusState(trees: [tree]).applying(observation)
        #expect(state.trees[tree.id]?.stems == stems)
        #expect(state.trees[tree.id]?.stemCount == 2)
        let changeset = try ChangesetBuilder.changeset(
            for: observation, in: CensusState(trees: [tree]), author: Sample.player)
        let op = try #require(changeset.ops.first)
        #expect(try op.fields["stems"]?.decode([StemMeasure].self) == stems)

        // Sorting them down to one leaves a tree of one stem, and shares that as no stems.
        let sorted = Sample.observation(
            .stemsMeasured(treeID: tree.id, dbh: Sample.dbh, stems: [stems[0]]))
        let after = state.applying(sorted)
        #expect(after.trees[tree.id]?.stems == nil)
        #expect(after.trees[tree.id]?.dbh == Sample.dbh)
        let update = try ChangesetBuilder.changeset(for: sorted, in: state, author: Sample.player)
        #expect(update.ops.first?.fields["stems"] == .null)
    }

    @Test func aMeasurementLoggedBeforeStemsWereKeptStillReads() throws {
        let tree = UUID()
        let old = FieldObservation.Kind.trunkMeasured(
            treeID: tree, dbh: Sample.dbh, lean: nil, evidence: Sample.evidence)
        var json = try JSONValue(encoding: old)
        // As an older build wrote it: no stems key at all.
        if case .object(var outer) = json, case .object(var inner)? = outer["trunkMeasured"] {
            inner["stems"] = nil
            outer["trunkMeasured"] = .object(inner)
            json = .object(outer)
        }
        let read = try json.decode(FieldObservation.Kind.self)
        #expect(read == old)
        // And a tree written before stems were kept reads with none.
        var fields = try #require(try JSONValue(encoding: Sample.detectedTree()).objectValue)
        fields["stems"] = nil
        #expect(try JSONValue.object(fields).decode(Tree.self).stems == nil)
    }
}
