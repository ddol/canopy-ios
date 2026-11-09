import CanopyModel
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Synchronization
import Testing

@testable import CanopyCapture

/// Renders are kept few and small: in `scripts/test.sh` they run in the simulator, on the Mac's small shared GPU.
@Suite struct ScanPreviewTests {
    let trunk = Synthetic.scannedTrunk(radius: 0.3, leanDegrees: 2, spacing: 0.06)

    /// The picture's pixels as RGBA, premultiplied, row by row from the top.
    func pixels(_ png: Data) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        // The context draws into the buffer after it is made, so it must hold the buffer's storage for as long as it
        // draws: `&rgba` would only lend a pointer for the length of the initialiser's call.
        try rgba.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (image.width, image.height, rgba)
    }

    @Test func drawsTheMeshInGreyOnAClearBackground() throws {
        let png = try ScanPreview.png(for: trunk, pixels: 96)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let (width, height, rgba) = try pixels(png)
        #expect(width == 96)
        #expect(height == 96)

        var opaque = 0
        var low = (x: width, y: height)
        var high = (x: 0, y: 0)
        var coloured = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                guard rgba[i + 3] > 0 else { continue }
                opaque += 1
                low = (min(low.x, x), min(low.y, y))
                high = (max(high.x, x), max(high.y, y))
                let (r, g, b) = (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]))
                if max(abs(r - g), abs(g - b), abs(r - b)) > 2 { coloured += 1 }
            }
        }
        // The corners are background, and the mesh fills the picture across its longer side.
        for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
            #expect(rgba[(y * width + x) * 4 + 3] == 0)
        }
        #expect(opaque > width * height / 10)
        #expect(max(high.x - low.x, high.y - low.y) > width * 8 / 10)
        // Colourless: every pixel drawn is a grey.
        #expect(coloured == 0)
        // Shaded, not a silhouette.
        let greys = Set(stride(from: 0, to: rgba.count, by: 4).filter { rgba[$0 + 3] == 255 }.map { rgba[$0] })
        #expect(greys.count > 8)
    }

    @Test func refusesAnEmptyMesh() {
        #expect(throws: ScanPreview.Error.emptyMesh) { try ScanPreview.png(for: .empty) }
        #expect(throws: ScanPreview.Error.emptyMesh) {
            try ScanPreview.png(for: Mesh(positions: [.zero, .zero], indices: [0, 1, 2]))
        }
    }
}

@Suite struct ScanPreviewCacheTests {
    static func reference(_ data: Data) -> BlobRef {
        BlobRef(rawValue: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())!
    }

    static func glb(radius: Double) throws -> Data {
        try GLB.data(for: Synthetic.scannedTrunk(radius: radius, leanDegrees: 0, spacing: 0.1))
    }

    @Test func rendersEachBlobOnceAndKeepsItUnderItsHash() async throws {
        let cache = ScanPreviewCache.temporary(pixels: 48)
        let glb = try Self.glb(radius: 0.25)
        let ref = Self.reference(glb)
        let reads = Mutex(0)
        let read: @Sendable () throws -> Data = {
            reads.withLock { $0 += 1 }
            return glb
        }
        #expect(cache.cached(ref) == nil)

        // Asked for four times at once, the mesh is read and drawn once.
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<4 {
                group.addTask { try await cache.preview(for: ref, glb: read) }
            }
            return try await group.reduce(into: [URL]()) { $0.append($1) }
        }
        let url = cache.url(for: ref)
        #expect(urls == Array(repeating: url, count: 4))
        #expect(reads.withLock { $0 } == 1)
        #expect(url.lastPathComponent == ref.rawValue + ".png")
        #expect(url.deletingLastPathComponent().lastPathComponent == "v\(ScanPreview.version)")
        #expect(cache.cached(ref) == url)
        let png = try Data(contentsOf: url)
        let image = try #require(
            CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 48)

        // Asked again later, it comes from disk.
        #expect(try await cache.preview(for: ref, glb: read) == url)
        #expect(reads.withLock { $0 } == 1)
        #expect(try Data(contentsOf: url) == png)

        // Another mesh has its own picture.
        let other = try Self.glb(radius: 0.5)
        let otherURL = try await cache.preview(for: Self.reference(other)) { other }
        #expect(otherURL != url)

        try await cache.removeAll()
        #expect(cache.cached(ref) == nil)
    }

    @Test func aBlobThatIsNotAMeshLeavesNoPreview() async throws {
        let cache = ScanPreviewCache.temporary(pixels: 48)
        let junk = Data(repeating: 0x20, count: 64)
        let ref = Self.reference(junk)
        await #expect(throws: GLB.Error.notGLB) { try await cache.preview(for: ref) { junk } }
        #expect(cache.cached(ref) == nil)
    }

    @Test func aRenderThatDrawsNothingLeavesNoPreview() async throws {
        // Triangles with no area draw no pixels, as does a render the GPU does not do (Metal turns away an app in the
        // background). A clear picture kept under the hash would stand for the scan until Caches is emptied.
        let flat = Mesh(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)], indices: [0, 1, 2])
        let glb = try GLB.data(for: flat)
        let ref = Self.reference(glb)
        let cache = ScanPreviewCache.temporary(pixels: 48)
        await #expect(throws: ScanPreview.Error.nothingDrawn) { try await cache.preview(for: ref) { glb } }
        #expect(cache.cached(ref) == nil)
    }

    @Test func aRequestCancelledWhileItWaitsIsNotDrawn() async throws {
        // A row scrolled out of the list cancels its request, so the rows still in view do not wait behind its render.
        let cache = ScanPreviewCache.temporary(pixels: 48)
        let (first, second) = (try Self.glb(radius: 0.25), try Self.glb(radius: 0.5))
        let reads = Mutex(0)
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let readFirst: @Sendable () throws -> Data = {
            started.signal()
            gate.wait()
            reads.withLock { $0 += 1 }
            return first
        }
        let readSecond: @Sendable () throws -> Data = {
            reads.withLock { $0 += 1 }
            return second
        }
        let drawing = Task { try await cache.preview(for: Self.reference(first), glb: readFirst) }
        // While the first is being drawn, a second request waits for the cache, and is cancelled.
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                started.wait()
                done.resume()
            }
        }
        let waiting = Task { try await cache.preview(for: Self.reference(second), glb: readSecond) }
        waiting.cancel()
        gate.signal()
        _ = try await drawing.value
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(reads.withLock { $0 } == 1)
        #expect(cache.cached(Self.reference(second)) == nil)
    }
}
