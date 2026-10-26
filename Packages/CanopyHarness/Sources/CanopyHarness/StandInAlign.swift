import CanopyModel
import CanopyReference
import Foundation

/// The align service (`gerardus.align.v1alpha1`) for synthetic sites, answering as the Rust server does: the same
/// messages, the same layer order and block size, intensity included, and the same status codes. Field numbers
/// follow `AlignMessages.swift`. With `anywhere`, any tile asked about gets a synthetic site of its own (made the
/// first time, with the same seed), so the app can load trees wherever its map is.
public final class StandInAlign: @unchecked Sendable {
    /// The site for `site.token`.
    public let site: SyntheticSite
    public let anywhere: Bool
    /// The real server's block size when the request names none.
    public static let pointsPerMessage = 65_536
    static let verticesPerMessage = 60_000

    /// Whether `GetSite` finds the site; `PrepareSite` prepares it.
    public var isPrepared: Bool {
        get { isPrepared(site.token) }
        set { lock.withLock { if newValue { prepared.insert(site.token) } else { prepared.remove(site.token) } } }
    }
    /// How long `PrepareSite` takes, in progress steps a tenth of it apart.
    public var preparation: Duration

    private let preparedAtFirst: Bool
    private var prepared: Set<String> = []
    private var others: [String: SyntheticSite] = [:]
    private var thinned: [String: SyntheticSite.Points] = [:]
    private let lock = NSLock()

    public init(
        site: SyntheticSite, prepared: Bool = true, preparation: Duration = .seconds(1), anywhere: Bool = false
    ) {
        self.site = site
        self.preparedAtFirst = prepared
        self.preparation = preparation
        self.anywhere = anywhere
    }

    func isPrepared(_ token: String) -> Bool {
        lock.withLock { preparedAtFirst || prepared.contains(token) }
    }

    /// The site for a tile, if this server has one.
    func site(_ token: String) -> SyntheticSite? {
        guard let cell = S2CellID(token: token), cell.level >= S2CellID.tileLevel else { return nil }
        let tile = cell.parent(level: S2CellID.tileLevel).token
        if tile == site.token { return site }
        guard anywhere else { return nil }
        if let made = lock.withLock({ others[tile] }) { return made }
        let made = SyntheticSite(token: tile)
        lock.withLock { others[tile] = made }
        return made
    }

    /// Answers one call.
    public func answer(_ path: String, _ request: [UInt8]) -> GRPCReply {
        let fields = (try? ProtoReader.fields(ArraySlice(request))) ?? []
        let method = path.split(separator: "/").last.map(String.init) ?? path
        switch method {
        case "GetServerInfo":
            var w = ProtoWriter()
            w.string(1, "canopy-harness 1")
            w.string(2, "gerardus.align.v1alpha1")
            w.packedVarints(3, [ReferenceLayer.aerialPoints, .footprints, .groundMesh].map { UInt64($0.rawValue) })
            return .messages([w.data])
        case "ListSites":
            guard isPrepared else { return .messages([Data()]) }
            var w = ProtoWriter()
            w.message(1) { encode(site, to: &$0) }
            return .messages([w.data])
        case "GetSite":
            let token = fields.first { $0.number == 1 }?.string ?? ""
            guard let site = site(token), isPrepared(site.token) else {
                return .status(GRPCStatusError.notFound, "site \(token) is not prepared; call PrepareSite")
            }
            var w = ProtoWriter()
            w.message(1) { encode(site, to: &$0) }
            return .messages([w.data])
        case "PrepareSite":
            let token = fields.first { $0.number == 1 }?.string ?? ""
            guard let site = site(token) else { return .status(3, "no aerial data for \(token)") }
            return prepare(site)
        case "StreamReference":
            let token = fields.first { $0.number == 1 }?.string ?? ""
            guard let site = site(token), isPrepared(site.token) else {
                return .status(GRPCStatusError.notFound, "site \(token) is not prepared; call PrepareSite")
            }
            return stream(site, fields)
        case "PoseFromHint":
            let token = fields.first { $0.number == 1 }?.string ?? ""
            guard let site = site(token), isPrepared(site.token) else {
                return .status(9, "site \(token) is not prepared; call PrepareSite")
            }
            return pose(site, fields)
        default:
            return .status(GRPCStatusError.unimplemented, "\(path) is not implemented by the stand-in")
        }
    }

    // MARK: Sites

    func encode(_ site: SyntheticSite, to w: inout ProtoWriter) {
        w.string(1, site.token)
        w.string(2, "canopy-harness")
        w.message(3) { f in
            f.string(1, "site/\(site.token)")
            f.string(2, site.token)
            f.message(3, GeodeticPosition(latitude: site.origin.latitude, longitude: site.origin.longitude))
            f.string(4, "NAD83(2011)")
            f.string(5, "NAVD88")
            f.string(6, "GEOID18")
            f.double(7, -32.1)
            f.string(8, "site-enu")
        }
        for token in site.covering { w.string(4, token) }
        for (layer, count) in [(ReferenceLayer.aerialPoints, site.points.count), (.footprints, site.buildings.count)] {
            w.message(5) { c in
                c.enumValue(1, layer.rawValue)
                c.uint(2, UInt64(count))
            }
        }
        let sources: [(ReferenceLayer, String, String, String)] = [
            (
                .aerialPoints, "USGS 3DEP CA_SanFrancisco_1_B23 (synthetic)", "public-domain",
                "U.S. Geological Survey, 3D Elevation Program"
            ),
            (.footprints, "DataSF Building Footprints (synthetic)", "PDDL-1.0", "City and County of San Francisco"),
            (.groundMesh, "Gerardus ground model (synthetic)", "public-domain", ""),
        ]
        for (layer, name, licence, attribution) in sources {
            w.message(6) { s in
                s.enumValue(1, layer.rawValue)
                s.string(2, name)
                s.string(5, licence)
                s.string(6, attribution)
            }
        }
        w.string(7, site.bundleID)
    }

    func prepare(_ site: SyntheticSite) -> GRPCReply {
        if isPrepared(site.token) {
            var ready = ProtoWriter()
            ready.message(2) { encode(site, to: &$0) }
            return .messages([ready.data])
        }
        var events: [GRPCReply.Event] = []
        let step = preparation / 10
        for k in 0..<10 {
            var w = ProtoWriter()
            w.message(1) { p in
                p.string(1, "aerial")
                p.float(2, Float(k) / 10)
                p.string(3, "Preparing the synthetic site")
            }
            events.append(.init(after: step * k, data: w.data))
        }
        // The site is ready once the last step has passed, whether or not the caller is still listening.
        let delay = preparation
        let token = site.token
        DispatchQueue.global().asyncAfter(deadline: .now() + delay.timeInterval) { [weak self] in
            self?.lock.withLock { _ = self?.prepared.insert(token) }
        }
        var ready = ProtoWriter()
        ready.message(2) { encode(site, to: &$0) }
        events.append(.init(after: preparation, data: ready.data))
        return GRPCReply(events: events)
    }

    // MARK: Reference layers

    /// The points thinned to `voxel` metres, keeping the first return in each voxel. The site is made at 1 m, so finer
    /// voxels give the 1 m points.
    func points(_ site: SyntheticSite, voxel: Float) -> SyntheticSite.Points {
        let key = Int((max(1, voxel) * 100).rounded())
        if key == 100 { return site.points }
        let name = "\(site.token)/\(key)"
        if let cached = lock.withLock({ thinned[name] }) { return cached }
        let size = Float(key) / 100
        let all = site.points
        var seen = Set<SIMD3<Int32>>()
        var out = SyntheticSite.Points()
        for k in 0..<all.count {
            let cell = SIMD3(
                Int32((all.x[k] / size).rounded(.down)), Int32((all.y[k] / size).rounded(.down)),
                Int32((all.z[k] / size).rounded(.down)))
            guard seen.insert(cell).inserted else { continue }
            out.x.append(all.x[k])
            out.y.append(all.y[k])
            out.z.append(all.z[k])
            out.classification.append(all.classification[k])
            out.intensity.append(all.intensity[k])
        }
        lock.withLock { thinned[name] = out }
        return out
    }

    func stream(_ site: SyntheticSite, _ fields: [ProtoField]) -> GRPCReply {
        var layers: [ReferenceLayer] = []
        var centre = SIMD2(0.0, 0.0)
        var radius: Float = 0
        var voxel: Float = 0
        var classes: Set<UInt8> = []
        var per = 0
        for f in fields {
            switch f.number {
            case 2: layers += ((try? f.varints()) ?? []).compactMap { ReferenceLayer(rawValue: Int($0)) }
            case 3:
                let v = Vector3(fields: (try? ProtoReader.fields(f.bytes)) ?? [])
                centre = SIMD2(v.x, v.y)
            case 4: radius = f.float
            case 5: voxel = f.float
            case 6: classes.formUnion(((try? f.varints()) ?? []).map { UInt8(truncatingIfNeeded: $0) })
            case 7: per = f.int
            default: break
            }
        }
        if layers.isEmpty { layers = [.aerialPoints, .footprints] }
        if layers.contains(.osm) {
            return .status(GRPCStatusError.permissionDenied, "OpenStreetMap is sent to admins only")
        }
        let blockSize = per == 0 ? Self.pointsPerMessage : min(per, (4 * 1024 * 1024 - 64) / 17)
        let r2 = radius > 0 ? Double(radius) * Double(radius) : .infinity
        func near(_ x: Float, _ y: Float) -> Bool {
            let dx = Double(x) - centre.x
            let dy = Double(y) - centre.y
            return dx * dx + dy * dy <= r2
        }
        var messages: [Data] = []
        func send(_ layer: ReferenceLayer, complete: Bool, _ payload: ((inout ProtoWriter) -> Void)?) {
            var w = ProtoWriter()
            w.enumValue(1, layer.rawValue)
            payload?(&w)
            w.bool(5, complete)
            messages.append(w.data)
        }
        for layer in layers {
            switch layer {
            case .aerialPoints:
                let all = points(site, voxel: voxel)
                var block = PointBlock()
                func flush(complete: Bool) {
                    let full = block
                    send(.aerialPoints, complete: complete, full.count == 0 ? nil : { $0.message(2, full) })
                    block = PointBlock()
                }
                for k in 0..<all.count {
                    let c = all.classification[k]
                    if classes.isEmpty ? (c == 7 || c == 18) : !classes.contains(c) { continue }
                    guard near(all.x[k], all.y[k]) else { continue }
                    block.x.append(all.x[k])
                    block.y.append(all.y[k])
                    block.z.append(all.z[k])
                    block.classification.append(UInt32(c))
                    block.intensity.append(UInt32(all.intensity[k]))
                    if block.count == blockSize { flush(complete: false) }
                }
                flush(complete: true)
            case .footprints:
                var features: [Data] = []
                for (k, b) in site.buildings.enumerated()
                where b.outline.contains(where: { near(Float($0.x), Float($0.y)) }) {
                    var f = ProtoWriter()
                    f.string(1, "datasf:\(k)")
                    f.enumValue(2, FeatureKind.building.rawValue)
                    f.packedFloats(
                        3,
                        b.outline.flatMap { p in
                            [Float(p.x), Float(p.y), Float(site.groundHeight(p) ?? 50)]
                        })
                    f.bool(4, true)
                    f.float(5, Float(b.height))
                    features.append(f.data)
                }
                send(.footprints, complete: true) { w in
                    w.message(3) { set in
                        for f in features { set.bytes(1, f) }
                    }
                }
            case .groundMesh:
                send(.groundMesh, complete: true) { w in
                    guard
                        let crop = site.ground.cropped(centre: centre, radius: radius > 0 ? Double(radius) : .infinity)
                    else { return }
                    w.message(7) { h in
                        h.message(1, crop.origin)
                        h.float(2, Float(crop.cellSize))
                        h.uint(3, UInt64(crop.nx))
                        h.uint(4, UInt64(crop.ny))
                        h.packedFloats(5, crop.z)
                    }
                }
            default:
                send(layer, complete: true, nil)
            }
        }
        return .messages(messages)
    }

    // MARK: Poses

    func pose(_ site: SyntheticSite, _ fields: [ProtoField]) -> GRPCReply {
        guard let sensor = fields.first(where: { $0.number == 2 })?.string, !sensor.isEmpty else {
            return .status(3, "sensor_id is required")
        }
        var position = GeodeticPosition(latitude: 0, longitude: 0)
        var mount = 1.5
        for f in fields where f.number == 3 {
            for g in (try? ProtoReader.fields(f.bytes)) ?? [] {
                if g.number == 1 { position = GeodeticPosition(fields: (try? ProtoReader.fields(g.bytes)) ?? []) }
                if g.number == 3 { mount = g.double }
            }
        }
        let p = site.site(GeoPoint(latitude: position.latitude, longitude: position.longitude))
        guard let ground = site.groundHeight(p) else {
            return .status(9, "no ground height at the hint")
        }
        var w = ProtoWriter()
        w.message(1) { pose in
            pose.string(1, "site/\(site.token)")
            pose.string(2, "sensor/\(sensor)")
            pose.message(3, Vector3(x: p.x, y: p.y, z: ground + mount))
            pose.message(4, Quaternion.identity)
            pose.enumValue(6, PoseSource.hint.rawValue)
        }
        w.message(2) { s in
            s.double(4, mount)
            s.message(5, position)
        }
        return .messages([w.data])
    }
}

extension Duration {
    /// Seconds, as a Double.
    public var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
