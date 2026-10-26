import CanopyModel
import CanopyReference
import Foundation

/// What else could shrink a load, measured on the synthetic site: coarser voxels (and what they cost detection), and
/// encodings the server could offer (no intensity, compression, quantised coordinates). For the backlog's "Aerial
/// data volume" questions; the options that need a server change are estimates of what it would send.
public enum Volume {
    public struct Row: Codable, Sendable {
        public var option: String
        public var bytes: Int
        public var points: Int
        public var score: DetectionScore?
    }

    /// One 150 m area, as the app loads it.
    public static func rows(
        site: SyntheticSite, centre: SIMD2<Double> = SIMD2(60, -40), radius: Double = 150
    ) throws
        -> [Row]
    {
        let align = StandInAlign(site: site)
        let area = AerialTrees.Area(centre: site.geo(centre), radius: radius)
        let georeference = try SiteGeoreference(
            origin: site.origin,
            samples: [SIMD2(0.0, 0), SIMD2(100, 0), SIMD2(0, 100), SIMD2(-80, -60)].map {
                (geo: site.geo($0), site: $0)
            })
        func stream(voxel: Float) -> [Data] {
            let request = StreamReferenceRequest(
                l16Token: site.token, layers: [.aerialPoints, .footprints, .groundMesh],
                centre: Vector3(x: centre.x, y: centre.y, z: 0), radius: Float(radius + AerialTrees.areaMargin),
                voxelSize: voxel, aerialClasses: AerialTrees.canopyClasses)
            return align.answer(AlignClient.site + "StreamReference", [UInt8](request.serialized)).events.map(\.data)
        }
        func decode(
            _ messages: [Data]
        ) throws -> (
            points: [PointBlock], ground: Heightfield?, buildings: [[SIMD2<Double>]]
        ) {
            var points: [PointBlock] = []
            var ground: Heightfield?
            var buildings: [[SIMD2<Double>]] = []
            for data in messages {
                switch try ReferenceMessage(serialized: data).chunk {
                case .points(_, let block): points.append(block)
                case .groundMesh(let field): ground = field
                case .lines(_, let lines): buildings += lines.filter { $0.kind == .building }.map(\.points)
                default: break
                }
            }
            return (points, ground, buildings)
        }
        func score(
            _ decoded: (points: [PointBlock], ground: Heightfield?, buildings: [[SIMD2<Double>]])
        )
            -> DetectionScore?
        {
            guard let ground = decoded.ground else { return nil }
            let trees = TreeDetector().detect(points: decoded.points, ground: ground, buildings: decoded.buildings)
            let candidates = AerialTrees.candidates(trees, georeference: georeference, source: "synthetic")
                .filter { area.contains($0.location) }
            return DetectionScore(candidates: candidates, site: site, covers: area.contains)
        }
        func size(_ messages: [Data]) -> Int { messages.reduce(0) { $0 + $1.count + 5 } }

        var rows: [Row] = []
        for voxel: Float in [1, 1.5, 2, 3] {
            let messages = stream(voxel: voxel)
            let decoded = try decode(messages)
            rows.append(
                Row(
                    option: String(format: "%.1f m voxels, as sent today", voxel), bytes: size(messages),
                    points: decoded.points.reduce(0) { $0 + $1.count }, score: score(decoded)))
        }

        // Encodings of the 1 m stream the server could offer. Detection sees the same points, so the same trees,
        // except for quantising, which moves each point by under half a centimetre.
        let messages = stream(voxel: 1)
        let decoded = try decode(messages)
        let points = decoded.points.reduce(0) { $0 + $1.count }
        let others = messages.filter { (try? ReferenceMessage(serialized: $0).layer) != .aerialPoints }
        let otherBytes = size(others)
        let withoutIntensity = decoded.points.map { block in
            var w = ProtoWriter()
            w.enumValue(1, ReferenceLayer.aerialPoints.rawValue)
            w.message(2, PointBlock(x: block.x, y: block.y, z: block.z, classification: block.classification))
            return w.data
        }
        rows.append(
            Row(
                option: "1 m, without intensity", bytes: size(withoutIntensity) + otherBytes, points: points,
                score: nil))
        let raw = messages.reduce(into: Data()) { $0.append($1) }
        rows.append(Row(option: "1 m, gzip (zlib) on the wire", bytes: compressed(raw), points: points, score: nil))
        let lean = (withoutIntensity + others).reduce(into: Data()) { $0.append($1) }
        rows.append(
            Row(option: "1 m, without intensity, gzip", bytes: compressed(lean), points: points, score: nil))
        // Centimetre offsets from each block's minimum as 16-bit integers, classes as bytes: 7 bytes a point.
        var quantised = Data()
        for block in decoded.points {
            for axis in [block.x, block.y, block.z] {
                let low = axis.min() ?? 0
                withUnsafeBytes(of: low) { quantised.append(contentsOf: $0) }
                for v in axis {
                    let q = UInt16(clamping: Int(((v - low) * 100).rounded()))
                    withUnsafeBytes(of: q.littleEndian) { quantised.append(contentsOf: $0) }
                }
            }
            quantised.append(contentsOf: block.classification.map { UInt8(truncatingIfNeeded: $0) })
        }
        rows.append(
            Row(
                option: "1 m, centimetre int16 per block, no intensity", bytes: quantised.count + otherBytes,
                points: points, score: nil))
        rows.append(
            Row(
                option: "1 m, centimetre int16, gzip", bytes: compressed(quantised) + otherBytes, points: points,
                score: nil))
        return rows
    }

    /// What gzip, and leaving out intensity, would make of reference messages as a server sent them.
    public static func encodings(of messages: [Data]) throws -> (sent: Int, gzip: Int, noIntensity: Int, both: Int) {
        let lean = try messages.map { data -> Data in
            let message = try ReferenceMessage(serialized: data)
            guard case .points(let layer, let block) = message.chunk else { return data }
            var w = ProtoWriter()
            w.enumValue(1, layer.rawValue)
            w.message(2, PointBlock(x: block.x, y: block.y, z: block.z, classification: block.classification))
            w.bool(5, message.complete)
            return w.data
        }
        let sent = messages.reduce(0) { $0 + $1.count + 5 }
        let gzip = messages.reduce(0) { $0 + Gzip.compress($1).count + 5 }
        let noIntensity = lean.reduce(0) { $0 + $1.count + 5 }
        let both = lean.reduce(0) { $0 + Gzip.compress($1).count + 5 }
        return (sent, gzip, noIntensity, both)
    }

    static func compressed(_ data: Data) -> Int {
        ((try? (data as NSData).compressed(using: .zlib)) as Data?)?.count ?? data.count
    }

    public static func table(_ rows: [Row]) -> String {
        let base = Double(rows.first?.bytes ?? 1)
        var lines = [
            "| Option | MB | Of today | Points | Trees found (recall, precision) |",
            "|---|---|---|---|---|",
        ]
        for row in rows {
            let score =
                row.score.map { String(format: "%d (%.2f, %.2f)", $0.matched, $0.recall, $0.precision) } ?? "same"
            lines.append(
                String(
                    format: "| %@ | %.2f | %.0f %% | %d | %@ |", row.option as NSString, Double(row.bytes) / 1e6,
                    Double(row.bytes) / base * 100, row.points, score as NSString))
        }
        return lines.joined(separator: "\n")
    }
}
