import Foundation
import Testing

@testable import CanopyModel

@Suite struct CensusStateTests {
    let tree = Sample.detectedTree()

    @Test func pendingConfirmationShowsAsProposed() throws {
        let observation = Sample.observation(.treeConfirmed(treeID: tree.id))
        let state = CensusState.derive(
            base: [tree],
            observations: [observation],
            changesetStates: [observation.changesetID!: .pending]
        )
        let derived = try #require(state.trees[tree.id])
        #expect(derived.countStatus == .detected)
        #expect(derived.proposedStatus == .confirmed)
        #expect(derived.displayStatus == .proposed)
        #expect(derived.meta.version == 2)
    }

    @Test func appliedConfirmationIsConfirmed() throws {
        let observation = Sample.observation(.treeConfirmed(treeID: tree.id))
        let state = CensusState.derive(
            base: [tree],
            observations: [observation],
            changesetStates: [observation.changesetID!: .applied]
        )
        let derived = try #require(state.trees[tree.id])
        #expect(derived.countStatus == .confirmed)
        #expect(derived.proposedStatus == nil)
        #expect(derived.displayStatus == .confirmed)
    }

    @Test func rejectedObservationsDropOut() throws {
        let observation = Sample.observation(.treeRejected(treeID: tree.id))
        for rejected in [Changeset.State.rejected, .conflicted] {
            let state = CensusState.derive(
                base: [tree],
                observations: [observation],
                changesetStates: [observation.changesetID!: rejected]
            )
            let derived = try #require(state.trees[tree.id])
            #expect(derived == tree)
        }
    }

    @Test func measurementIsVisibleAtOnceAndVerifiesWhenApplied() throws {
        let confirm = Sample.observation(.treeConfirmed(treeID: tree.id))
        let measure = Sample.observation(
            .trunkMeasured(treeID: tree.id, dbh: Sample.dbh, lean: nil, evidence: Sample.evidence)
        )
        var states: [UUID: Changeset.State] = [confirm.changesetID!: .applied, measure.changesetID!: .pending]
        var derived = try #require(
            CensusState.derive(base: [tree], observations: [confirm, measure], changesetStates: states).trees[tree.id]
        )
        #expect(derived.dbh == Sample.dbh)
        #expect(derived.evidenceRefs == [Sample.evidence])
        #expect(derived.countStatus == .confirmed)
        #expect(derived.proposedStatus == .verified)

        states[measure.changesetID!] = .applied
        derived = try #require(
            CensusState.derive(base: [tree], observations: [confirm, measure], changesetStates: states).trees[tree.id]
        )
        #expect(derived.countStatus == .verified)
        #expect(derived.proposedStatus == nil)
        #expect(derived.meta.version == 3)
    }

    @Test func addedTreeExistsOnlyLocallyUntilApplied() throws {
        let added = Sample.newTree()
        let observation = Sample.observation(.treeAdded(added), at: Sample.windmill)
        let pending = try #require(
            CensusState.derive(
                base: [], observations: [observation], changesetStates: [observation.changesetID!: .pending]
            )
            .trees[added.id]
        )
        #expect(pending.countStatus == .proposed)
        #expect(pending.proposedStatus == .confirmed)
        let applied = try #require(
            CensusState.derive(
                base: [], observations: [observation], changesetStates: [observation.changesetID!: .applied]
            )
            .trees[added.id]
        )
        #expect(applied.countStatus == .confirmed)
        #expect(applied.proposedStatus == nil)
    }

    @Test func tagIsProposedUntilApplied() throws {
        let tag = Sample.tag(on: tree)
        let observation = Sample.observation(.tagPlaced(tag))
        let pending = CensusState.derive(
            base: [tree],
            observations: [observation],
            changesetStates: [observation.changesetID!: .pending]
        )
        #expect(pending.tags[tag.id]?.status == .proposed)
        let applied = CensusState.derive(
            base: [tree],
            observations: [observation],
            changesetStates: [observation.changesetID!: .applied]
        )
        #expect(applied.tags[tag.id]?.status == .confirmed)
    }

    @Test func tagOnUnknownTreeIsIgnored() {
        let orphan = Sample.tag(on: Sample.newTree())
        let state = CensusState().applying(Sample.observation(.tagPlaced(orphan)))
        #expect(state.tags.isEmpty)
    }

    @Test func summaryCountsConfirmedEstimatedAndCoverage() {
        func tree(_ status: CountStatus, proposed: CountStatus? = nil) -> Tree {
            var tree = Sample.detectedTree()
            tree.countStatus = status
            tree.proposedStatus = proposed
            return tree
        }
        let trees = [
            tree(.detected), tree(.detected), tree(.detected), tree(.detected),
            tree(.detected, proposed: .confirmed),
            tree(.detected, proposed: .removed),
            tree(.confirmed), tree(.verified),
            tree(.proposed, proposed: .confirmed),
            tree(.removed),
        ]
        let summary = CensusSummary(trees: trees)
        #expect(summary.confirmed == 2)
        #expect(summary.estimated == 8)
        #expect(summary.coverage == 4.0 / 8.0)
        #expect(CensusSummary(trees: []).coverage == 0)
    }

    @Test func observationsRoundTripThroughJSON() throws {
        let tree = Sample.newTree()
        let observations: [Observation] = [
            Sample.observation(.treeConfirmed(treeID: tree.id)),
            Sample.observation(.treeAdded(tree)),
            Sample.observation(.treeRejected(treeID: tree.id), changeset: nil),
            Sample.observation(
                .trunkMeasured(
                    treeID: tree.id,
                    dbh: Sample.dbh,
                    lean: Lean(angle: Quantity(3, uncertainty: 1), azimuth: Quantity(120, uncertainty: 15)),
                    evidence: Sample.evidence
                )
            ),
            Sample.observation(.tagPlaced(Sample.tag(on: tree))),
        ]
        let data = try CanopyJSON.encoder.encode(observations)
        #expect(try CanopyJSON.decoder.decode([Observation].self, from: data) == observations)
    }

    @Test func recordTimesAreKeptToTheMillisecond() throws {
        let meta = RecordMeta(
            createdAt: Date(timeIntervalSince1970: 1_792_540_800.123456), playerID: Sample.player,
            cell: Sample.stowLake.chunk)
        #expect(meta.createdAt.timeIntervalSince1970 == 1_792_540_800.123)
        let back = try CanopyJSON.decoder.decode(RecordMeta.self, from: CanopyJSON.encoder.encode(meta))
        #expect(back == meta)
    }
}
