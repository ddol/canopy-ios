import Foundation
import simd

/// Raw LiDAR depth frames turned into world points. ARKit's reconstructed mesh is smoothed over a few centimetres,
/// which rounds a trunk off and biases a circle fitted to it; the depth map behind it (a 256 × 192 image of metres
/// per pixel with a confidence per pixel) is noisier per point but unbiased, and dense enough that a slice through
/// the accumulated points gives the fit hundreds of points instead of dozens.
public enum DepthFrame {
    /// The depth map's pixels as world points.
    ///
    /// - Parameters:
    ///   - depth: metres per pixel, row-major, `width × height`.
    ///   - confidence: ARKit's confidence per pixel (0 low, 1 medium, 2 high), or nil to take every pixel.
    ///   - intrinsics: the camera matrix at the depth map's resolution (the frame's intrinsics scaled from the
    ///     image's resolution).
    ///   - cameraTransform: camera to world, ARKit's `camera.transform`: the camera looks down its −z, +y is up
    ///     in the sensor's landscape-right frame, which is how the buffers are laid out.
    ///   - minimumConfidence: pixels below this are dropped.
    ///   - maxDistance: pixels farther than this are dropped; LiDAR noise grows with range.
    ///   - stride: take every n-th pixel in each direction.
    public static func unproject(
        depth: [Float], confidence: [UInt8]?, width: Int, height: Int, intrinsics: simd_float3x3,
        cameraTransform: simd_float4x4, minimumConfidence: UInt8 = 2, maxDistance: Float = 3.5, stride: Int = 1
    ) -> [SIMD3<Float>] {
        guard width > 0, height > 0, depth.count == width * height, stride > 0 else { return [] }
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]
        guard fx > 0, fy > 0 else { return [] }
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(depth.count / (stride * stride))
        for v in Swift.stride(from: 0, to: height, by: stride) {
            for u in Swift.stride(from: 0, to: width, by: stride) {
                let i = v * width + u
                let d = depth[i]
                guard d.isFinite, d > 0, d <= maxDistance else { continue }
                if let confidence, confidence[i] < minimumConfidence { continue }
                // Image y runs down and the camera looks down −z, so flip y and z into the camera's frame.
                let local = SIMD4<Float>((Float(u) - cx) / fx * d, -(Float(v) - cy) / fy * d, -d, 1)
                let world = cameraTransform * local
                points.append(SIMD3(world.x, world.y, world.z))
            }
        }
        return points
    }

    /// The camera matrix at another resolution.
    public static func intrinsics(
        _ intrinsics: simd_float3x3, from imageSize: SIMD2<Float>, to depthSize: SIMD2<Float>
    ) -> simd_float3x3 {
        let sx = depthSize.x / imageSize.x
        let sy = depthSize.y / imageSize.y
        var scaled = intrinsics
        scaled[0][0] *= sx
        scaled[1][1] *= sy
        scaled[2][0] *= sx
        scaled[2][1] *= sy
        return scaled
    }
}

/// Keeps the depth points that fall in a region round a subject, one per small voxel, averaged, so a surface seen
/// from many frames settles toward its true position instead of piling up noise.
public struct DepthAccumulator: Sendable {
    public let center: SIMD3<Float>
    /// Horizontal radius of the region, in metres.
    public let radius: Float
    /// How far below and above `center` the region reaches, in metres.
    public let below: Float
    public let above: Float
    /// Voxel edge, in metres.
    public var voxelSize: Float = 0.01

    private struct Sum: Sendable {
        var total: SIMD3<Float>
        var count: Float
    }

    private var voxels: [SIMD3<Int32>: Sum] = [:]
    /// How many frames have been added.
    public private(set) var frameCount = 0
    /// How many points have been taken in, before averaging.
    public private(set) var pointsSeen = 0

    public init(center: SIMD3<Float>, radius: Float, below: Float, above: Float) {
        self.center = center
        self.radius = radius
        self.below = below
        self.above = above
    }

    /// Adds one frame's world points; those outside the region are ignored.
    public mutating func add(_ points: [SIMD3<Float>]) {
        frameCount += 1
        let r2 = radius * radius
        for p in points {
            let d = p - center
            guard d.x * d.x + d.z * d.z <= r2, d.y >= -below, d.y <= above else { continue }
            pointsSeen += 1
            let key = SIMD3<Int32>((p / voxelSize).rounded(.down))
            if var sum = voxels[key] {
                sum.total += p
                sum.count += 1
                voxels[key] = sum
            } else {
                voxels[key] = Sum(total: p, count: 1)
            }
        }
    }

    public var isEmpty: Bool { voxels.isEmpty }

    /// Occupied voxels.
    public var count: Int { voxels.count }

    /// One averaged world point per occupied voxel, in a stable order.
    public func points() -> [SIMD3<Float>] {
        voxels.sorted { a, b in
            a.key.x != b.key.x ? a.key.x < b.key.x : a.key.y != b.key.y ? a.key.y < b.key.y : a.key.z < b.key.z
        }
        .map { $0.value.total / $0.value.count }
    }
}

extension Array where Element == SIMD3<Float> {
    /// The (x, z) of the points within `halfWidth` of height `y`: a slice through a point cloud, the counterpart
    /// of `Mesh.slice(atHeight:)`.
    public func slice(atHeight y: Float, halfWidth: Float) -> [SIMD2<Double>] {
        compactMap { p in abs(p.y - y) <= halfWidth ? SIMD2(Double(p.x), Double(p.z)) : nil }
    }

    /// The points inside a vertical cylinder round `center`, moved so `center` is the origin, as `Mesh.cropped`.
    public func cropped(around center: SIMD3<Float>, radius: Float, below: Float, above: Float) -> [SIMD3<Float>] {
        let r2 = radius * radius
        return compactMap { p in
            let d = p - center
            guard d.x * d.x + d.z * d.z <= r2, d.y >= -below, d.y <= above else { return nil }
            return d
        }
    }
}
