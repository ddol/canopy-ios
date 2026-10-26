import Foundation
import Testing

@testable import CanopyReference

@Suite struct ProtobufTests {
    @Test func varintsMatchTheSpecExample() throws {
        var w = ProtoWriter()
        w.uint(1, 150)
        #expect([UInt8](w.data) == [0x08, 0x96, 0x01])
        let field = try #require(try ProtoReader.fields(ArraySlice([UInt8](w.data))).first)
        #expect(field.number == 1)
        #expect(field.uint == 150)
    }

    @Test func defaultsAreLeftOutButPresenceIsKept() {
        var w = ProtoWriter()
        w.uint(1, 0)
        w.string(2, "")
        w.float(3, 0)
        w.double(4, 0)
        #expect(w.data.isEmpty)
        w.double(4, 0, always: true)
        w.message(5) { _ in }
        #expect([UInt8](w.data) == [0x21, 0, 0, 0, 0, 0, 0, 0, 0, 0x2A, 0x00])
    }

    @Test func messagesRoundTrip() throws {
        let block = PointBlock(
            x: [1.5, -2.25, 1e6], y: [0, 3, -4], z: [87.6, 90, 133.25], classification: [1, 2, 300], intensity: [],
            confidence: [])
        #expect(try PointBlock(serialized: block.serialized) == block)

        let pose = SensorPose(translation: Vector3(x: 60, y: -60, z: 110.6), rotation: .yaw(0.4))
        let decoded = try SensorPose(serialized: pose.serialized)
        #expect(decoded.translation == pose.translation)
        #expect(abs(decoded.rotation.z - pose.rotation.z) < 1e-15)

        let position = GeodeticPosition(latitude: 37.7697, longitude: -122.4757, orthometricHeight: 0)
        #expect(GeodeticPosition(fields: try ProtoReader.fields(ArraySlice([UInt8](position.serialized)))) == position)
    }

    @Test func unknownFieldsAreSkipped() throws {
        var w = ProtoWriter()
        w.double(1, 3)
        w.string(99, "from a newer server")
        w.uint(100, 7)
        w.float(101, 2)
        w.double(2, 4)
        let v = Vector3(fields: try ProtoReader.fields(ArraySlice([UInt8](w.data))))
        #expect(v == Vector3(x: 3, y: 4, z: 0))
    }

    @Test func truncatedInputThrows() {
        var w = ProtoWriter()
        w.string(1, "8085876c1")
        let truncated = ArraySlice([UInt8](w.data.dropLast(3)))
        #expect(throws: ProtobufError.truncated) { try ProtoReader.fields(truncated) }
        #expect(throws: ProtobufError.self) { try ProtoReader.fields([0x08, 0xFF]) }
        #expect(throws: ProtobufError.unsupportedWireType(3)) { try ProtoReader.fields([0x0B]) }
    }

    @Test func quaternionYawRotatesCounterClockwise() {
        let q = Quaternion.yaw(.pi / 2)
        let v = q.rotate(Vector3(x: 0, y: 1, z: 0))
        #expect(abs(v.x + 1) < 1e-12)
        #expect(abs(v.y) < 1e-12)
    }

    @Test func heightfieldInterpolatesAndSkipsGaps() {
        let field = Heightfield(
            origin: Vector3(x: 0, y: 0, z: 0), cellSize: 1, nx: 3, ny: 2, z: [10, 12, .nan, 14, 16, .nan])
        #expect(field.height(x: 0, y: 0) == 10)
        #expect(field.height(x: 0.5, y: 0) == 11)
        #expect(field.height(x: 0.5, y: 0.5) == 13)
        // Next to a gap only the valid corners count.
        #expect(field.height(x: 1.5, y: 0) == 12)
        #expect(field.height(x: 2, y: 1) == nil)
        #expect(field.height(x: -5, y: 0) == nil)
    }
}

@Suite struct GzipTests {
    @Test func roundTripsAndChecksItsCRC() throws {
        var random = SystemRandomNumberGenerator()
        for size in [0, 1, 100, 70_000] {
            let data = Data((0..<size).map { _ in UInt8.random(in: 0...20, using: &random) })
            #expect(try Gzip.decompress(Gzip.compress(data)) == data)
        }
        var damaged = Gzip.compress(Data(repeating: 7, count: 1000))
        damaged[damaged.count - 6] ^= 0xFF  // the CRC
        #expect(throws: Gzip.Failure.corrupt) { try Gzip.decompress(damaged) }
        #expect(throws: Gzip.Failure.notGzip) { try Gzip.decompress(Data("hello, not gzip at all".utf8)) }
    }

    /// GetServerInfo's answer from gerardus serve built with tonic's send_compressed(Gzip), as it came off the wire.
    @Test func readsWhatTonicSends() throws {
        let message = Data([
            0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x01, 0x53, 0x00, 0xAC, 0xFF, 0x0A,
            0x18, 0x30, 0x2E, 0x32, 0x2E, 0x30, 0x2B, 0x34, 0x63, 0x64, 0x33, 0x34, 0x66, 0x37, 0x61, 0x32,
            0x33, 0x30, 0x32, 0x2D, 0x64, 0x69, 0x72, 0x74, 0x79, 0x12, 0x17, 0x67, 0x65, 0x72, 0x61, 0x72,
            0x64, 0x75, 0x73, 0x2E, 0x61, 0x6C, 0x69, 0x67, 0x6E, 0x2E, 0x76, 0x31, 0x61, 0x6C, 0x70, 0x68,
            0x61, 0x31, 0x1A, 0x05, 0x06, 0x07, 0x08, 0x0B, 0x0C, 0x22, 0x13, 0x08, 0x14, 0x15, 0x00, 0x00,
            0xA0, 0x40, 0x1D, 0x00, 0x00, 0xF0, 0x41, 0x25, 0x00, 0x00, 0x80, 0x3F, 0x28, 0x01, 0x28, 0x09,
            0x30, 0x0A, 0x64, 0xF1, 0x62, 0xD1, 0x53, 0x00, 0x00, 0x00,
        ])
        let info = try ServerInfo(serialized: Gzip.decompress(message))
        #expect(info.serverVersion == "0.2.0+4cd34f7a2302-dirty")
        #expect(info.apiVersion == "gerardus.align.v1alpha1")
        #expect(info.availableLayers.contains(.groundMesh))
    }

    /// `gzip -c` of "canopy\n", as a real gzip writes it: a file name and a modification time in the header.
    @Test func readsWhatGzipWrites() throws {
        let file = Data([
            0x1F, 0x8B, 0x08, 0x08, 0xD4, 0xF8, 0xDE, 0x6A, 0x00, 0x03, 0x63, 0x00, 0x4B, 0x4E, 0xCC, 0xCB,
            0x2F, 0xA8, 0xE4, 0x02, 0x00, 0x71, 0x38, 0x04, 0xEB, 0x07, 0x00, 0x00, 0x00,
        ])
        #expect(try Gzip.decompress(file) == Data("canopy\n".utf8))
    }
}
