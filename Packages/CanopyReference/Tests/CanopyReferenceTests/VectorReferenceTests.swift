import Foundation
import Testing

@testable import CanopyReference

@Suite struct VectorReferenceTests {
    private func mock(layers: [ReferenceLayer], messages: [ProtoWriter]) -> MockTransport {
        let transport = MockTransport()
        var info = ProtoWriter()
        info.packedVarints(3, layers.map { UInt64($0.rawValue) })
        transport.responses[AlignClient.site + "GetServerInfo"] = .success([info.data])
        var site = ProtoWriter()
        site.message(1) {
            $0.string(1, VectorReference.kirkham9th)
            $0.string(2, "kirkham-9th")
            for layer in [ReferenceLayer.aerialPoints, .footprints, .osm] {
                $0.message(6) {
                    $0.enumValue(1, layer.rawValue)
                    $0.string(2, "source-\(layer.rawValue)")
                    $0.string(5, layer == .osm ? "ODbL-1.0" : "public-domain")
                }
            }
            $0.string(7, "sha256:bundle")
        }
        transport.responses[AlignClient.site + "GetSite"] = .success([site.data])
        transport.responses[AlignClient.site + "StreamReference"] = .success(messages.map(\.data))
        return transport
    }

    private func wall(complete: Bool = true, model: String = "model-1") -> ProtoWriter {
        var message = ProtoWriter()
        message.message(3) {
            $0.message(1) {
                $0.string(1, "datasf:building#wall0")
                $0.enumValue(2, FeatureKind.building.rawValue)
                $0.packedFloats(3, [0, 0, 40, 10, 0, 40, 10, 0, 48, 0, 0, 48])
                $0.bool(4, true)
                $0.float(5, 8)
            }
        }
        message.enumValue(1, ReferenceLayer.boxes.rawValue)  // Deliberately after the payload.
        message.bool(5, complete)
        message.string(8, model)
        return message
    }

    @Test func loadsActual3DCoordinatesAndOnlyAdvertisedPublicVectors() async throws {
        let transport = mock(layers: [.boxes, .osm, .registeredScans], messages: [wall()])
        let result = try await VectorReference.load(
            token: VectorReference.kirkham9th, client: AlignClient(transport: transport))
        #expect(result.site.label == "kirkham-9th")
        #expect(result.modelID == "model-1")
        #expect(result.features.first?.layer == .boxes)
        #expect(result.features.first?.line.vertices.last == SIMD3<Float>(0, 0, 48))
        #expect(result.attribution == ["source-1 (public-domain)", "source-3 (public-domain)"])
        let sent = try #require(transport.sent.last?.requests.first)
        let fields = try ProtoReader.fields(ArraySlice([UInt8](sent)))
        #expect(try fields.first { $0.number == 2 }?.varints() == [8])
        #expect(fields.first { $0.number == 4 }?.float == 220)
    }

    @Test func refusesPartialStreamsEvenAfterGeometryArrives() async throws {
        let transport = mock(layers: [.boxes], messages: [wall(complete: false)])
        await #expect(throws: VectorReference.Failure.incomplete) {
            try await VectorReference.load(token: VectorReference.kirkham9th, client: AlignClient(transport: transport))
        }
    }

    @Test func refusesGeometryFromDifferentModelVersions() async throws {
        let transport = mock(layers: [.boxes], messages: [wall(), wall(model: "model-2")])
        await #expect(throws: VectorReference.Failure.mixedModels) {
            try await VectorReference.load(token: VectorReference.kirkham9th, client: AlignClient(transport: transport))
        }
    }

    @Test func anEmptyLayerDoesNotPretendThereAreBuildings() async throws {
        var empty = ProtoWriter()
        empty.enumValue(1, ReferenceLayer.buildings.rawValue)
        empty.bool(5, true)
        let transport = mock(layers: [.buildings], messages: [empty])
        await #expect(throws: VectorReference.Failure.unavailable) {
            try await VectorReference.load(token: VectorReference.kirkham9th, client: AlignClient(transport: transport))
        }
    }

    @Test func futureRoofsRetainTheirKindTagsAndElevation() throws {
        var wire = ProtoWriter()
        wire.enumValue(2, 17)
        wire.packedFloats(3, [0, 0, 50, 10, 0, 54, 10, 10, 54])
        wire.bool(4, true)
        wire.message(6) {
            $0.string(1, "part")
            $0.string(2, "building-part-1")
        }
        wire.string(7, "derivation-1")
        let roof = try LineFeature(fields: ProtoReader.fields(ArraySlice([UInt8](wire.data))))
        #expect(roof.kind == .roofPlane)
        #expect(roof.vertices[1].z == 54)
        #expect(roof.tags["part"] == "building-part-1")
        #expect(roof.sourceVersion == "derivation-1")
        #expect(try LineFeature(fields: []).vertices.isEmpty)
    }

    @Test(.enabled(if: Live.url != nil)) func liveKirkhamVectors() async throws {
        let reference = try await VectorReference.load(token: VectorReference.kirkham9th, client: Live.client)
        #expect(reference.features.contains { $0.layer == .boxes })
        #expect(reference.features.contains { $0.line.kind == .wallPlane })
        #expect(reference.ground != nil)
        #expect(!reference.modelID.isEmpty)
        print("Kirkham vectors: \(reference.features.count) features; model \(reference.modelID)")
    }
}
