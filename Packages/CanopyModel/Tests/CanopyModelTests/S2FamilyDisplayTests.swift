import Foundation
import Testing

@testable import CanopyModel

/// The S2 presentation rules shared with velocity.report (docs/lidar/architecture/geographic-indexing.md in
/// banshee-data/velocity.report), checked against the examples in that guide and Canopy's own levels.
@Suite struct S2FamilyDisplayTests {
    @Test(arguments: [
        // From the guide.
        ("80859", 8, "8085-9"),
        ("808581", 10, "80858-1"),
        ("80858004", 13, "80858-004"),
        ("808580f3f", 16, "80858-0f3f"),
        // Canopy's L16 tile and L19 chunk at the Conservatory of Flowers: the 5+n form.
        ("80858745b", 16, "80858-745b"),
        ("80858745afc", 19, "80858-745afc"),
    ])
    func familyDisplayPutsOneHyphenAfterTheFamilyPrefix(token: String, level: Int, display: String) throws {
        let cell = try #require(S2CellID(token: token))
        #expect(cell.level == level)
        #expect(cell.familyDisplay == display)
        // Removing the presentation hyphen gives the canonical token back.
        #expect(display.replacingOccurrences(of: "-", with: "") == cell.token)
    }

    @Test func canopyLevelsUseTheFivePlusNForm() {
        let point = GeoPoint(latitude: 37.7720, longitude: -122.4602)
        for cell in [point.tile, point.chunk] {
            #expect(cell.familyPrefixLength == 5)
            let parts = cell.familyDisplay.split(separator: "-")
            #expect(parts.count == 2)
            #expect(parts[0].count == 5)
            #expect(parts[0] + parts[1] == cell.token)
        }
    }

    @Test func faceCellsHaveNoHyphen() throws {
        #expect(try #require(S2CellID(token: "9")).familyDisplay == "9")
    }

    @Test func parentsComeFromTheCellNotFromTheText() throws {
        // From the guide: L10 cells and their L8 parents. Truncating the text would give 8085-8, not 8085-9.
        let pairs = [("808581", "80859"), ("808587", "80859"), ("808f7d", "808f7"), ("808f7f", "808f7")]
        for (child, parent) in pairs {
            let cell = try #require(S2CellID(token: child))
            #expect(cell.parent(level: 8).token == parent, "\(child)")
        }
        // The guide's L13 example is a real descendant of its L10 example.
        let l13 = try #require(S2CellID(token: "80858004"))
        #expect(l13.parent(level: 10).token == "808581")
    }

    @Test func peopleMayTypeEitherForm() throws {
        let tile = try #require(S2CellID(token: "80858745b"))
        #expect(S2CellID(familyDisplay: "80858-745b") == tile)
        #expect(S2CellID(familyDisplay: "80858745b") == tile)
        // The hyphen must sit at the family boundary, and only once.
        #expect(S2CellID(familyDisplay: "8085-8745b") == nil)
        #expect(S2CellID(familyDisplay: "80858-74-5b") == nil)
        #expect(S2CellID(familyDisplay: "-80858745b") == nil)
    }

    @Test func machineParsingAcceptsOnlyTheCanonicalToken() {
        #expect(S2CellID(token: "80858-745b") == nil)
        #expect(S2CellID(token: "80858745b0") == nil)  // trailing zero: not canonical
        #expect(S2CellID(token: "80858745B") == nil)
    }
}

@Suite struct S2FieldNameTests {
    @Test func recordsNameTheirS2FieldsByLevelAndRepresentation() throws {
        let meta = RecordMeta(playerID: Sample.player, chunk: Sample.stowLake.chunk)
        let json = try #require(try JSONValue(encoding: meta).objectValue)
        #expect(json["s2_l19_token"] == .string(Sample.stowLake.chunk.token))
        #expect(json["cell"] == nil)
    }

    @Test func recordsWrittenBeforeTheRenameStillDecode() throws {
        let legacy = Data(
            """
            {"createdAt":1792540800000,"id":"00000000-0000-4000-8000-000000000001","playerID":"T:_x",
             "cell":"80858745afc","version":2}
            """.utf8)
        let meta = try CanopyJSON.decoder.decode(RecordMeta.self, from: legacy)
        #expect(meta.chunk.token == "80858745afc")
        #expect(meta.version == 2)

        let changeset = try CanopyJSON.decoder.decode(
            Changeset.self,
            from: Data(
                """
                {"approvals":[],"cells":["80858745b"],"ops":[],"state":"pending",
                 "meta":{"createdAt":0,"id":"00000000-0000-4000-8000-000000000002","playerID":"T:_x",
                         "cell":"80858745afc","version":1}}
                """.utf8))
        #expect(changeset.tiles.map(\.token) == ["80858745b"])
        let reencoded = try #require(try JSONValue(encoding: changeset).objectValue)
        #expect(reencoded["s2_l16_tokens"] != nil)
        #expect(reencoded["cells"] == nil)
    }
}
