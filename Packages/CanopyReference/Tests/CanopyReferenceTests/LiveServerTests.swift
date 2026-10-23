import CanopyModel
import Foundation
import Testing

@testable import CanopyReference

/// Tests against a real Gerardus align server. Opt in with CANOPY_GERARDUS_URL, e.g.
/// `CANOPY_GERARDUS_URL=http://hydra.local:50061 swift test`. They prepare the Stow Lake site if needed.
enum Live {
    static let url = ProcessInfo.processInfo.environment["CANOPY_GERARDUS_URL"].flatMap(URL.init(string:))
    static var enabled: Bool { url != nil }
    static var client: AlignClient { AlignClient(baseURL: url!) }
    /// The L16 tile at Stow Lake, Golden Gate Park.
    static let stowLake = "8085876c1"
}

@Suite(.enabled(if: Live.enabled), .serialized) struct LiveServerTests {
    @Test func serverInfoAndSite() async throws {
        let info = try await Live.client.serverInfo()
        #expect(info.apiVersion == "gerardus.align.v1alpha1")
        #expect(info.availableLayers.contains(.aerialPoints))

        let site = try await Live.client.preparedSite(Live.stowLake, label: "ggp-stow-lake")
        #expect(site.l16Token == Live.stowLake)
        #expect(site.coveringL16Tokens.count == 9)
        #expect((site.layerCounts[.aerialPoints] ?? 0) > 1_000_000)
        #expect(site.sources.contains { $0.layer == .aerialPoints && $0.licence == "public-domain" })
        let origin = try #require(site.frame?.origin)
        #expect(abs(origin.latitude - 37.7697) < 0.001)
    }

    @Test func poseFromHintIsEastNorthUp() async throws {
        let site = try #require(try await Live.client.site(Live.stowLake))
        let origin = try #require(site.frame?.origin)
        let north = try await Live.client.poseFromHint(
            l16Token: Live.stowLake, sensorID: "canopy-test",
            hint: PoseHint(position: GeodeticPosition(latitude: origin.latitude + 0.001, longitude: origin.longitude)))
        let east = try await Live.client.poseFromHint(
            l16Token: Live.stowLake, sensorID: "canopy-test",
            hint: PoseHint(position: GeodeticPosition(latitude: origin.latitude, longitude: origin.longitude + 0.001)))
        #expect(abs(north.pose.translation.y - 110) < 3)
        #expect(abs(east.pose.translation.x - 88) < 3)
    }

    @Test func streamsAerialPointsAndGround() async throws {
        var points = 0
        var classes: Set<UInt32> = []
        var ground: Heightfield?
        let request = StreamReferenceRequest(
            l16Token: Live.stowLake, layers: [.aerialPoints, .groundMesh], radius: 25, voxelSize: 1)
        for try await chunk in Live.client.reference(request) {
            switch chunk {
            case .points(let layer, let block):
                #expect(layer == .aerialPoints)
                points += block.count
                classes.formUnion(block.classification)
                #expect(block.x.count == block.z.count)
            case .groundMesh(let field):
                ground = field
            default:
                break
            }
        }
        #expect(points > 1000)
        #expect(classes.contains(2))
        let mesh = try #require(ground)
        #expect(mesh.z.count == mesh.nx * mesh.ny)
        let height = try #require(mesh.height(x: 0, y: 0))
        #expect((50...150).contains(height))
    }

    @Test func unpreparedSiteIsNilAndBadTokensAreRejected() async throws {
        // The L16 tile at the Dutch Windmill; tests never prepare it.
        #expect(try await Live.client.site("808587b97") == nil)
        await #expect(throws: GRPCStatusError.self) {
            try await Live.client.site("80858")
        }
    }
}
