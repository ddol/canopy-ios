import CanopyCapture
import CanopyDesign
import CanopyMap
import CanopyModel
import CanopyReference
import Foundation

/// The aerial lidar (USGS 3DEP) points round a site on the 3D map, to set the vectors and the census's trees against
/// what the aircraft saw.
extension AppModel {
    /// How far round the middle of the map the points are asked for, in metres: a tile and its edges.
    nonisolated static let mapPointRadius: Float = 160
    /// Thinning for the map, in metres: enough to make out crowns, walls and kerbs, few enough to draw at once.
    nonisolated static let mapPointVoxel: Float = 0.5
    /// A site's points are kept to this many, so a few sites still draw smoothly on an iPad.
    nonisolated static let mapPointLimit = 300_000

    /// Whether the points round `point` are loaded.
    func hasAerialPoints(at point: GeoPoint) -> Bool {
        aerialPointClouds[point.tile.token] != nil
    }

    /// Loads the aerial points within `mapPointRadius` of `centre`, of every class, from the site there (prepared on
    /// the server first if need be), and adds them to the 3D map beside any loaded before.
    func loadAerialPoints(around centre: GeoPoint) async {
        guard !aerial.isWorking else { return }
        guard let client = alignClient else {
            aerial = .failed(NoServerSet().errorDescription!)
            return
        }
        let tile = centre.tile
        aerial = .working("Loading 3DEP points…")
        do {
            let site: Site
            if let prepared = try await client.site(tile.token, cache: referenceCache) {
                site = prepared
            } else {
                aerial = .working("Preparing the site on the server…")
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
            let georeference = try await SiteGeoreference.fetch(for: site, client: client, cache: referenceCache)
            let middle = georeference.site(of: centre)
            let request = StreamReferenceRequest(
                l16Token: tile.token, layers: [.aerialPoints], centre: Vector3(x: middle.x, y: middle.y, z: 0),
                radius: Self.mapPointRadius, voxelSize: Self.mapPointVoxel, aerialClasses: [])
            var blocks: [PointBlock] = []
            for try await chunk in client.reference(request, bundleID: site.bundleID, cache: referenceCache) {
                if case .points(_, let block) = chunk { blocks.append(block) }
            }
            guard !blocks.isEmpty else { throw AerialTrees.Failure.noAerialData }
            let cloud = await Task.detached(priority: .userInitiated) {
                Self.cloud(blocks, token: tile.token, georeference: georeference, limit: Self.mapPointLimit)
            }.value
            aerialPointClouds[tile.token] = cloud
            aerial = .done(
                "\(QuantityFormat().count(cloud.points.count)) 3DEP points round tile \(tile.familyDisplay). "
                    + "Layers → 3DEP points shows or hides them.")
        } catch let error as AerialTrees.Failure {
            aerial = .failed(error.localizedDescription)
        } catch  where Self.isOffline(error) {
            aerial = .failed("Offline: the points load once the device is back online.")
        } catch {
            aerial = .failed("Could not load 3DEP points: \(error.localizedDescription)")
        }
    }

    /// The streamed blocks as one cloud, every `limit`-th point kept past `limit`.
    nonisolated static func cloud(
        _ blocks: [PointBlock], token: String, georeference: SiteGeoreference, limit: Int
    ) -> MapLayers.AerialPoints.Cloud {
        let total = blocks.reduce(0) { $0 + $1.x.count }
        let stride = max(1, Int((Double(total) / Double(max(limit, 1))).rounded(.up)))
        var points: [SIMD3<Float>] = []
        var classes: [UInt8] = []
        points.reserveCapacity(min(total, limit))
        var index = 0
        for block in blocks {
            let classed = block.classification.count == block.x.count
            for i in block.x.indices where block.y.count > i && block.z.count > i {
                defer { index += 1 }
                guard index % stride == 0 else { continue }
                points.append(SIMD3(block.x[i], block.y[i], block.z[i]))
                if classed { classes.append(UInt8(clamping: block.classification[i])) }
            }
        }
        return MapLayers.AerialPoints.Cloud(
            token: token, georeference: georeference, points: points,
            classes: classes.count == points.count ? classes : [])
    }
}
