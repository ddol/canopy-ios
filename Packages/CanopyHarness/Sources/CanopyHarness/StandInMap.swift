import CanopyReference
import Foundation

/// Just enough of the map service (`gerardus.map.v1alpha1`) for the app to sync with the stand-in: it keeps
/// submitted changesets (pending; nobody else is there to agree), counts imported trees, and has an empty shared map.
/// Field numbers follow `MapClient.swift`.
public final class StandInMap: @unchecked Sendable {
    private let lock = NSLock()
    private var changesets: [String: Data] = [:]
    private var trees: Set<String> = []

    public init() {}

    public func answer(_ path: String, _ request: [UInt8]) -> GRPCReply {
        let fields = (try? ProtoReader.fields(ArraySlice(request))) ?? []
        let method = path.split(separator: "/").last.map(String.init) ?? path
        var w = ProtoWriter()
        switch method {
        case "SubmitChangeset":
            guard let changeset = fields.first(where: { $0.number == 1 }) else {
                return .status(3, "changeset is required")
            }
            let bytes = Data(changeset.bytes)
            let id = (try? ProtoReader.fields(changeset.bytes))?.first { $0.number == 1 }?.string ?? UUID().uuidString
            lock.withLock { changesets[id] = bytes }
            w.bytes(1, bytes)
        case "GetChangesets":
            let known = lock.withLock { changesets }
            for f in fields where f.number == 1 {
                if let bytes = known[f.string] { w.bytes(1, bytes) }
            }
        case "UploadBlob", "ListOpenChangesets":
            break
        case "GetPlayer":
            w.message(1) { p in
                p.string(1, "stand-in")
                p.string(2, "Player")
            }
        case "GetTile":
            w.uint(2, 0)
        case "PullChanges":
            w.uint(2, fields.first { $0.number == 2 }?.uint ?? 0)
        case "ImportDetectedTrees":
            let ids = fields.filter { $0.number == 1 }.compactMap { f in
                (try? ProtoReader.fields(f.bytes))?.first { $0.number == 1 }?.string
            }
            let created = lock.withLock { ids.filter { trees.insert($0).inserted }.count }
            w.uint(2, UInt64(created))
            w.uint(3, UInt64(ids.count - created))
        default:
            return .status(GRPCStatusError.unimplemented, "\(method) is not implemented by the stand-in")
        }
        return .messages([w.data])
    }
}

extension StandInServer {
    /// A server answering the align service for a synthetic site and the map service in memory, as `canopy-harness
    /// serve` runs it for the app.
    public convenience init(align: StandInAlign, map: StandInMap, profile: NetworkProfile = .loopback) {
        self.init(profile: profile) { path, request in
            path.contains("gerardus.map.") ? map.answer(path, request) : align.answer(path, request)
        }
    }

    /// The status page (`GET /`) a Gerardus server answers, which the app's connection test reads.
    static func statusPage(started: Date) -> Data {
        let page: [String: Any] = [
            "status": "ok", "service": "gerardus", "server_version": "canopy-harness",
            "api_version": "gerardus.align.v1alpha1", "started_at": ISO8601DateFormatter().string(from: started),
            "uptime_s": Int(Date().timeIntervalSince(started)), "available_layers": ["aerial", "footprints", "ground"],
        ]
        return (try? JSONSerialization.data(withJSONObject: page, options: [.sortedKeys])) ?? Data()
    }
}
