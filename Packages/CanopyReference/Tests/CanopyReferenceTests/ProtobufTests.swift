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

    /// `gzip -c` of "canopy\n", as a real gzip writes it: a file name and a modification time in the header.
    @Test func readsWhatGzipWrites() throws {
        let file = Data([
            0x1F, 0x8B, 0x08, 0x08, 0xD4, 0xF8, 0xDE, 0x6A, 0x00, 0x03, 0x63, 0x00, 0x4B, 0x4E, 0xCC, 0xCB,
            0x2F, 0xA8, 0xE4, 0x02, 0x00, 0x71, 0x38, 0x04, 0xEB, 0x07, 0x00, 0x00, 0x00,
        ])
        #expect(try Gzip.decompress(file) == Data("canopy\n".utf8))
    }
}
