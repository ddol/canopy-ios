import CanopyCapture
import CanopyModel
import CanopyReference
import Foundation

/// The aerial lidar points round a tree, for setting its crown against them (`ScanAlignmentScreen`).
extension AppModel {
    /// How far round the tree its aerial points are asked for, in metres: the widest crown and some.
    nonisolated static let canopyPointRadius: Float = 18
    /// Aerial thinning for a crown, in metres: fine enough to see its shape, small enough to draw on a phone.
    nonisolated static let canopyVoxel: Float = 0.4

    /// The aerial points within `canopyPointRadius` of a tree, in its scan's frame (`CanopyPoints.scanFrame`): the
    /// tree's site from the server (prepared first if need be), its vegetation and unclassified returns, and the
    /// ground under the trunk from the site's ground model to set their heights by. Kept on the phone with the rest
    /// of the server's reference data, so opening the tree again costs no download.
    nonisolated static func canopyPoints(
        around position: GeoPoint, groundHeight: Double, correction: SIMD2<Double>, client: AlignClient,
        cache: ReferenceCache?
    ) async throws -> [SIMD3<Float>] {
        let tile = position.tile
        let site: Site
        if let prepared = try await client.site(tile.token, cache: cache) {
            site = prepared
        } else {
            do {
                site = try await client.preparedSite(tile.token, label: "canopy-ggp")
            } catch GRPCTransportError.timedOut {
                throw AerialTrees.Failure.stillPreparing
            }
        }
        guard
            site.layerCounts[.aerialPoints, default: 0] > 0
                || site.sources.contains(where: { $0.layer == .aerialPoints })
        else { throw AerialTrees.Failure.noAerialData }
        let georeference = try await SiteGeoreference.fetch(for: site, client: client, cache: cache)
        let base = georeference.site(of: position)
        let request = StreamReferenceRequest(
            l16Token: tile.token, layers: [.aerialPoints, .groundMesh], centre: Vector3(x: base.x, y: base.y, z: 0),
            radius: canopyPointRadius, voxelSize: canopyVoxel, aerialClasses: AerialTrees.canopyClasses)
        var blocks: [PointBlock] = []
        var ground: Heightfield?
        for try await chunk in client.reference(request, bundleID: site.bundleID, cache: cache) {
            switch chunk {
            case .points(_, let block): blocks.append(block)
            case .groundMesh(let field): ground = field
            default: break
            }
        }
        guard !blocks.isEmpty else { throw AerialTrees.Failure.noAerialData }
        // Without a ground model, the lowest returns round the trunk stand in for the ground.
        let elevation =
            ground?.height(x: base.x, y: base.y)
            ?? blocks.flatMap(\.z).map(Double.init).sorted().first ?? 0
        return CanopyPoints.scanFrame(
            blocks, georeference: georeference, base: base, groundElevation: elevation, groundHeight: groundHeight,
            correction: correction)
    }
}
