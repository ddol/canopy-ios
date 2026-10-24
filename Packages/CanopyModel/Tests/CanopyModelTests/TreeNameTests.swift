import Foundation
import Testing

@testable import CanopyModel

@Suite struct TreeNameTests {
    @Test func theScrambleIsAPermutationOfTwentyOneBits() {
        var seen = [Bool](repeating: false, count: 1 << 21)
        for index in 0..<UInt32(1 << 21) {
            let n = Int(TreeName.scramble(index))
            #expect(n < seen.count)
            if seen[n] {
                Issue.record("\(index) collides")
                return
            }
            seen[n] = true
        }
    }

    @Test func wordListsAreFullDistinctAndClean() {
        for words in [TreeName.adjectives, TreeName.names, TreeName.latin] {
            #expect(words.count == 128)
            #expect(Set(words).count == 128)
            #expect(
                words.allSatisfy {
                    $0.allSatisfy(\.isLetter) && $0.first!.isUppercase && $0.dropFirst() == $0.dropFirst().lowercased()
                })
        }
        let all = TreeName.adjectives + TreeName.names + TreeName.latin
        #expect(Set(all).count == all.count)  // no word in two lists
    }

    @Test func theRegionIsDistinctTilesWithRoomToGrow() {
        #expect(TreeName.region.count == 414)
        #expect(TreeName.region.count <= 512)
        #expect(Set(TreeName.region).count == TreeName.region.count)
        #expect(TreeName.region.allSatisfy { $0.level == S2CellID.tileLevel })
        #expect(TreeName.region == TreeName.region.sorted())
        // The park's corners and middle are in it.
        for point in [
            GeoPoint(latitude: 37.7712, longitude: -122.5098),  // near the Dutch Windmill
            GeoPoint(latitude: 37.7694, longitude: -122.4770),  // the middle
            GeoPoint(latitude: 37.7726, longitude: -122.4435),  // the Panhandle at Baker
        ] {
            #expect(TreeName.name(for: point) != nil)
        }
        #expect(TreeName.name(for: GeoPoint(latitude: 37.7793, longitude: -122.4193)) == nil)  // City Hall
    }

    @Test func everyCellInATileHasItsOwnName() throws {
        // All 4,096 L22 cells of one tile: no name repeats.
        let tile = TreeName.region[200]
        var names = Set<String>()
        for place in 0..<UInt64(4096) {
            // Children of the tile at L22: the tile's id with its trailing bit replaced by six child positions.
            let raw = (tile.rawValue & ~(tile.rawValue & (~tile.rawValue &+ 1))) | (place << 17) | (1 << 16)
            let cell = S2CellID(rawValue: raw)
            #expect(cell.level == 22 && cell.parent(level: 16) == tile)
            names.insert(try #require(TreeName.name(for: cell)))
        }
        #expect(names.count == 4096)
    }

    @Test func namesAreDeterministicAndThreeWords() throws {
        let point = GeoPoint(latitude: 37.769652, longitude: -122.475737)
        let name = try #require(TreeName.name(for: point))
        #expect(name == TreeName.name(for: point))
        #expect(name.split(separator: " ").count == 3)
        // Frozen: if this changes, every tree in the park gets a new name.
        #expect(name == "Steadfast Raelin Caelum")
        // A metre away is usually the same cell; 3 m away is another cell and another name.
        let frame = LocalFrame(origin: point)
        let other = frame.geoPoint(of: ENU(east: 3, north: 3, up: 0)).point
        #expect(TreeName.name(for: other) != name)
    }

    @Test func playersNamesComeFirst() {
        let position = Position(
            geo: GeoPoint(latitude: 37.769652, longitude: -122.475737),
            covariance: .isotropic(horizontal: 3, vertical: 3))
        var tree = Tree(
            meta: RecordMeta(playerID: .aerialSurvey, chunk: position.chunk), position: position, countStatus: .detected
        )
        #expect(tree.name == TreeName.name(for: position.geo))
        tree.localName = "Picnic Oak"
        #expect(tree.name == "Picnic Oak")
    }
}
