import CanopyModel
import Foundation
import Testing

@testable import CanopyReference

#if canImport(AppKit)
    import AppKit
#endif

@Suite(.enabled(if: Live.enabled), .serialized) struct LiveDetectionTests {
    @Test func detectsTreesAtStowLake() async throws {
        let client = Live.client
        let site = try await client.preparedSite(Live.stowLake, label: "ggp-stow-lake")
        let start = Date()
        var blocks: [PointBlock] = []
        var ground: Heightfield?
        var buildings: [[SIMD2<Double>]] = []
        var paths: [[SIMD2<Double>]] = []
        let voxel = Float(ProcessInfo.processInfo.environment["CANOPY_VOXEL"].flatMap(Double.init) ?? 1.0)
        // The City's streets rather than OpenStreetMap, which the server sends only to its admins.
        let request = StreamReferenceRequest(
            l16Token: site.l16Token, layers: [.aerialPoints, .cityStreets, .footprints, .groundMesh],
            voxelSize: voxel, aerialClasses: [1, 2])
        for try await chunk in client.reference(request) {
            switch chunk {
            case .points(_, let block): blocks.append(block)
            case .groundMesh(let field): ground = field
            case .lines(_, let lines):
                for line in lines {
                    if line.kind == .building, line.closed { buildings.append(line.points) }
                    if line.kind == .path || line.kind == .road { paths.append(line.points) }
                }
            default: break
            }
        }
        let fetched = Date().timeIntervalSince(start)
        let groundModel = try #require(ground)
        let total = blocks.reduce(0) { $0 + $1.count }
        let detectStart = Date()
        let trees = TreeDetector().detect(points: blocks, ground: groundModel, buildings: buildings)
        let detected = Date().timeIntervalSince(detectStart)
        print(
            "STOWLAKE voxel \(voxel): \(total) points in \(blocks.count) blocks, fetched in \(fetched) s; ground \(groundModel.nx)×\(groundModel.ny)"
        )
        print("STOWLAKE \(trees.count) trees in \(detected) s; buildings \(buildings.count), paths \(paths.count)")
        let georef = try await SiteGeoreference.fetch(for: site, client: client)
        print("STOWLAKE georef rms \(georef.rms) m, matrix \(georef.matrix), offset \(georef.offset)")
        let heights = trees.map(\.height).sorted()
        let crowns = trees.map(\.crownRadius).sorted()
        if !heights.isEmpty {
            print(
                "STOWLAKE height p10 \(heights[heights.count / 10]) p50 \(heights[heights.count / 2]) p90 \(heights[heights.count * 9 / 10]) max \(heights.last!)"
            )
            print(
                "STOWLAKE crown p10 \(crowns[crowns.count / 10]) p50 \(crowns[crowns.count / 2]) p90 \(crowns[crowns.count * 9 / 10])"
            )
        }
        // Trees standing on a street centreline are suspicious.
        let onPaths = trees.filter { tree in
            paths.contains { line in
                zip(line, line.dropFirst()).contains { a, b in
                    Self.distance(SIMD2(tree.x, tree.y), a, b) < 1.0
                }
            }
        }
        print("STOWLAKE tops within 1 m of a path centreline: \(onPaths.count)")
        #expect(trees.count > 300)
        #expect(georef.rms < 0.05)

        #if canImport(AppKit)
            if let out = ProcessInfo.processInfo.environment["CANOPY_DEBUG_PNG"] {
                try Self.render(
                    trees: trees, blocks: blocks, ground: groundModel, paths: paths, buildings: buildings,
                    to: URL(fileURLWithPath: out))
            }
        #endif
    }

    static func distance(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let t = max(0, min(1, ((p - a) * ab).sum() / max((ab * ab).sum(), 1e-9)))
        let q = a + ab * t - p
        return (q * q).sum().squareRoot()
    }

    #if canImport(AppKit)
        /// Draws the CHM in greens, streets in grey, buildings in red and detected crowns as circles.
        static func render(
            trees: [TreeDetector.Tree], blocks: [PointBlock], ground: Heightfield, paths: [[SIMD2<Double>]],
            buildings: [[SIMD2<Double>]], to url: URL
        ) throws {
            let scale = 2.0  // pixels per metre
            let x0 = ground.origin.x
            let y0 = ground.origin.y
            let width = Int(Double(ground.nx) * ground.cellSize * scale)
            let height = Int(Double(ground.ny) * ground.cellSize * scale)
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            func px(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: (x - x0) * scale, y: (y - y0) * scale) }
            for block in blocks {
                for k in stride(from: 0, to: block.count, by: 1) where block.classification[k] == 1 {
                    let x = Double(block.x[k])
                    let y = Double(block.y[k])
                    guard let g = ground.height(x: x, y: y) else { continue }
                    let h = min(40, max(0, Double(block.z[k]) - g))
                    guard h > 2 else { continue }
                    NSColor(calibratedRed: 0.1, green: 0.25 + 0.6 * h / 40, blue: 0.1, alpha: 0.5).setFill()
                    let p = px(x, y)
                    NSRect(x: p.x, y: p.y, width: scale, height: scale).fill()
                }
            }
            NSColor.gray.setStroke()
            for line in paths where line.count > 1 {
                let path = NSBezierPath()
                path.move(to: px(line[0].x, line[0].y))
                for p in line.dropFirst() { path.line(to: px(p.x, p.y)) }
                path.lineWidth = 2
                path.stroke()
            }
            NSColor.red.setStroke()
            for outline in buildings where outline.count > 2 {
                let path = NSBezierPath()
                path.move(to: px(outline[0].x, outline[0].y))
                for p in outline.dropFirst() { path.line(to: px(p.x, p.y)) }
                path.close()
                path.lineWidth = 2
                path.stroke()
            }
            NSColor.orange.setStroke()
            for tree in trees {
                let p = px(tree.x, tree.y)
                let r = tree.crownRadius * scale
                let circle = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                circle.lineWidth = 1
                circle.stroke()
                NSColor.orange.setFill()
                NSRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            try rep.representation(using: .png, properties: [:])!.write(to: url)
        }
    #endif
}
