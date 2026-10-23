import Foundation
import simd

@testable import CanopyCapture

/// Deterministic random numbers for synthetic test data.
struct SeededRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func gaussian(_ sigma: Double) -> Double {
        let u = max(unit(), 1e-12)
        return sigma * (-2 * log(u)).squareRoot() * cos(2 * .pi * unit())
    }
}

enum Synthetic {
    /// Points on a circle arc with Gaussian noise along the radius.
    static func arc(
        center: SIMD2<Double>, radius: Double, from start: Double, through span: Double, count: Int,
        noise: Double, seed: UInt64
    ) -> [SIMD2<Double>] {
        var random = SeededRandom(state: seed)
        return (0..<count).map { i in
            let angle = start + span * Double(i) / Double(max(count - 1, 1))
            let r = radius + random.gaussian(noise)
            return center + SIMD2(cos(angle), sin(angle)) * r
        }
    }

    /// A LiDAR-like scan of one side of a trunk: a cylinder mesh of `radius`, visible over `visibleDegrees`
    /// facing −z (towards the scanner), leaning `leanDegrees` towards +x, standing on a flat ground patch at
    /// y = `ground`. Vertices get Gaussian noise.
    /// - Parameters:
    ///   - facingDegrees: direction (in the x–z plane, from +x towards +z) of the middle of the visible side;
    ///     −90 faces −z.
    ///   - spacing: vertical and around-the-trunk vertex spacing, in metres: larger is coarser.
    ///   - includeGround: whether to add the flat ground grid.
    static func scannedTrunk(
        radius: Double, leanDegrees: Double, visibleDegrees: Double = 160, height: Double = 3,
        ground: Double = 0, noise: Double = 0.003, seed: UInt64 = 1, facingDegrees: Double = -90,
        spacing: Double = 0.03, includeGround: Bool = true
    ) -> Mesh {
        var random = SeededRandom(state: seed)
        var mesh = Mesh.empty
        let rings = Int(height / spacing)
        let segments = max(4, Int(visibleDegrees * .pi / 180 * radius / spacing))
        let tilt = tan(leanDegrees * .pi / 180)
        let start = (facingDegrees - visibleDegrees / 2) * .pi / 180
        for ring in 0...rings {
            let h = Double(ring) * height / Double(rings)
            for segment in 0...segments {
                let angle = start + visibleDegrees * .pi / 180 * Double(segment) / Double(segments)
                let r = radius + random.gaussian(noise)
                let x = tilt * h + cos(angle) * r
                let z = sin(angle) * r
                mesh.positions.append(SIMD3(Float(x), Float(ground + h + random.gaussian(noise / 3)), Float(z)))
            }
        }
        let columns = segments + 1
        for ring in 0..<rings {
            for segment in 0..<segments {
                let a = UInt32(ring * columns + segment)
                let b = a + 1
                let c = a + UInt32(columns)
                let d = c + 1
                mesh.indices += [a, c, b, b, c, d]
            }
        }
        guard includeGround else { return mesh }
        // Ground: a flat grid around the trunk.
        var groundMesh = Mesh.empty
        let cells = 12
        for i in 0...cells {
            for j in 0...cells {
                let x = -1.2 + 2.4 * Double(i) / Double(cells)
                let z = -1.2 + 2.4 * Double(j) / Double(cells)
                groundMesh.positions.append(SIMD3(Float(x), Float(ground + random.gaussian(noise)), Float(z)))
            }
        }
        for i in 0..<cells {
            for j in 0..<cells {
                let a = UInt32(i * (cells + 1) + j)
                groundMesh.indices += [
                    a, a + 1, a + UInt32(cells + 1), a + 1, a + UInt32(cells + 2), a + UInt32(cells + 1),
                ]
            }
        }
        mesh.append(groundMesh)
        return mesh
    }
}
