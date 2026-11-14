import CanopyModel
import CanopyReference
import CanopySync
import Foundation
import Testing

@testable import Canopy

/// An iPad lists the scans its player took on a phone: from the shared map's history, which says who added each
/// scan, and from their changes still waiting for agreement.
@MainActor
struct AccountScansTests {
    let me = PlayerID(rawValue: "T:_me")
    let other = PlayerID(rawValue: "T:_other")
    let tile = GeoPoint(latitude: 37.7699, longitude: -122.4757).tile
    let tree = UUID()

    func ref(_ n: Int) -> BlobRef { BlobRef(rawValue: String(repeating: String(n), count: 64))! }

    func refs(_ refs: [BlobRef]) -> JSONValue { .array(refs.map { .string($0.rawValue) }) }

    func change(
        _ sequence: Int64, _ op: ChangeOp.Kind, _ fields: [String: JSONValue], by author: PlayerID
    )
        -> AppliedChange
    {
        AppliedChange(
            sequence: sequence, changesetID: UUID(), tile: tile,
            op: ChangeOp(op: op, entity: .tree, id: tree, baseVersion: 0, fields: fields),
            appliedAt: Date(timeIntervalSince1970: Double(sequence)), author: author)
    }

    /// A tree's list of scans is given whole each time: a scan is credited to the player whose change added it.
    @Test func eachScanIsCreditedToWhoeverAddedIt() {
        let history = [
            change(1, .create, ["evidenceRefs": refs([ref(1)])], by: other),
            change(2, .update, ["evidenceRefs": refs([ref(1), ref(2)])], by: me),
            change(3, .update, ["evidenceRefs": refs([ref(1), ref(2), ref(3)])], by: other),
            // The same change pulled again from a second tile counts once.
            change(2, .update, ["evidenceRefs": refs([ref(1), ref(2)])], by: me),
        ]
        let mine = AppModel.scans(by: me, in: history)
        #expect(mine.map(\.blob) == [ref(2)])
        #expect(mine.first?.state == .onMap && mine.first?.subject == tree)
        #expect(mine.first?.date == Date(timeIntervalSince1970: 2))
        #expect(Set(AppModel.scans(by: other, in: history).map(\.blob)) == [ref(1), ref(3)])
    }

    /// A change that only reorders or keeps a tree's scans adds none.
    @Test func keepingScansAddsNone() {
        let history = [
            change(1, .create, ["evidenceRefs": refs([ref(1)])], by: me),
            change(2, .update, ["evidenceRefs": refs([ref(1)]), "species": .string("Quercus")], by: other),
        ]
        #expect(AppModel.scans(by: other, in: history).isEmpty)
        #expect(AppModel.scans(by: me, in: history).map(\.blob) == [ref(1)])
    }

    /// A change of mine still waiting lists the scans it brings that the shared map does not hold yet.
    @Test func myWaitingChangesListTheirNewScans() {
        let op = ChangeOp(
            op: .update, entity: .tree, id: tree, baseVersion: 3, fields: ["evidenceRefs": refs([ref(1), ref(4)])])
        let mine = Changeset(meta: RecordMeta(playerID: me, chunk: tile), ops: [op], tiles: [tile])
        let theirs = Changeset(meta: RecordMeta(playerID: other, chunk: tile), ops: [op], tiles: [tile])
        let waiting = AppModel.waitingScans(by: me, in: [mine, theirs], alreadyOn: [tree: [ref(1)]])
        #expect(waiting.map(\.blob) == [ref(4)])
        #expect(waiting.first?.state == .waiting)
    }

    /// A limb tag's one scan.
    @Test func aTagsScanIsItsOwn() {
        let op = ChangeOp(
            op: .create, entity: .tag, id: UUID(), baseVersion: 0, fields: ["evidenceRef": .string(ref(5).rawValue)])
        #expect(AppModel.scansAfter(op, holding: []).added == [ref(5)])
    }
}

/// The Me tab's trust badge says what the server said, and why a player this build makes an admin is not trusted.
@MainActor
struct TrustBadgeTests {
    func server(trusted: Bool, admin: Bool) -> GerardusMapClient.PlayerInfo {
        GerardusMapClient.PlayerInfo(id: "T:_me", alias: "Me", isTrusted: trusted, isAdmin: admin, isOSMAllowed: admin)
    }

    @Test func theBadgeFollowsTheServer() {
        #expect(MeScreen.trust(server: server(trusted: true, admin: true), adminInThisBuild: false).label == "Admin")
        #expect(MeScreen.trust(server: server(trusted: true, admin: false), adminInThisBuild: false).label == "Trusted")
        #expect(
            MeScreen.trust(server: server(trusted: false, admin: false), adminInThisBuild: true).label
                == "Admin on this phone")
        #expect(MeScreen.trust(server: nil, adminInThisBuild: false).label == "Not trusted yet")
    }

    @Test func anAdminTheServerDoesNotTrustIsToldWhy() {
        let note = MeScreen.trustNote(
            server: server(trusted: false, admin: false), adminInThisBuild: true, hasServer: true, signedIn: true)
        #expect(note?.contains("GERARDUS_ADMINS") == true)
        #expect(
            MeScreen.trustNote(
                server: server(trusted: true, admin: true), adminInThisBuild: true, hasServer: true, signedIn: true)
                == nil)
        #expect(
            MeScreen.trustNote(server: nil, adminInThisBuild: false, hasServer: true, signedIn: false)?
                .contains("Game Center") == true)
    }
}
