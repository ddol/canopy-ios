#!/usr/bin/env swift
// Generates the Golden Gate Park sample fixtures in Fixtures/ggp:
//   park-boundary.geojson   an approximate park outline, hand-traced from the street grid
//   tree-candidates.geojson ~200 SYNTHETIC aerial tree candidates (made-up data, not real trees)
//
// Deterministic: the same seed always produces the same files. Run from the repository root:
//   swift scripts/make-fixtures.swift
import Foundation

// MARK: Park outline

/// Approximate outline, counter-clockwise, as (longitude, latitude). Traced from the streets that bound the
/// park (Fulton, Stanyan, Lincoln, the Great Highway) and the Panhandle (Fell, Oak, Baker). Good to ~50 m.
let boundary: [(Double, Double)] = [
    (-122.5112, 37.7722),  // Fulton St & Great Hwy
    (-122.5098, 37.7638),  // Lincoln Way & Great Hwy
    (-122.4588, 37.7660),  // Lincoln Way & Arguello Blvd
    (-122.4531, 37.7663),  // Stanyan St, south end
    (-122.4532, 37.7716),  // Stanyan St & Oak St
    (-122.4431, 37.7726),  // Baker St & Oak St (Panhandle)
    (-122.4429, 37.7735),  // Baker St & Fell St (Panhandle)
    (-122.4533, 37.7725),  // Stanyan St & Fell St
    (-122.4543, 37.7750),  // Stanyan St & Fulton St
    (-122.5112, 37.7722),  // close
]

/// Open areas without trees: (longitude, latitude, radius in metres).
let clearings: [(Double, Double, Double)] = [
    (-122.4930, 37.7680, 160),  // Polo Field
    (-122.4945, 37.7706, 70),  // Spreckels Lake
    (-122.4760, 37.7693, 40),  // Stow Lake water (north arm)
    (-122.4585, 37.7695, 60),  // Sharon Meadow
]

// MARK: Random numbers

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * unit()
    }
    mutating func gaussian() -> Double {
        let u = max(unit(), 1e-12)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * unit())
    }
    mutating func uuid() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { bytes[i] = UInt8(truncatingIfNeeded: next()) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40  // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // variant
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return parts.joined(separator: "-")
    }
}

// MARK: Geometry

let metresPerDegreeLatitude = 111_132.0
let metresPerDegreeLongitude = 111_320.0 * cos(37.7694 * .pi / 180)

func inside(_ lng: Double, _ lat: Double) -> Bool {
    var result = false
    var j = boundary.count - 1
    for i in 0..<boundary.count {
        let (xi, yi) = boundary[i]
        let (xj, yj) = boundary[j]
        if (yi > lat) != (yj > lat), lng < (xj - xi) * (lat - yi) / (yj - yi) + xi {
            result.toggle()
        }
        j = i
    }
    return result
}

func inClearing(_ lng: Double, _ lat: Double) -> Bool {
    clearings.contains { cx, cy, r in
        let dx = (lng - cx) * metresPerDegreeLongitude
        let dy = (lat - cy) * metresPerDegreeLatitude
        return dx * dx + dy * dy < r * r
    }
}

func acceptable(_ lng: Double, _ lat: Double) -> Bool { inside(lng, lat) && !inClearing(lng, lat) }

let lngRange = boundary.map(\.0).min()!...boundary.map(\.0).max()!
let latRange = boundary.map(\.1).min()!...boundary.map(\.1).max()!

func randomPoint(_ rng: inout SplitMix64) -> (Double, Double) {
    while true {
        let lng = rng.uniform(lngRange)
        let lat = rng.uniform(latRange)
        if acceptable(lng, lat) { return (lng, lat) }
    }
}

// MARK: Candidates

struct PointGeometry: Encodable {
    let type = "Point"
    let coordinates: [Double]
}

struct CandidateProperties: Encodable {
    let height_m: Double
    let crown_radius_m: Double
    let confidence: Double
    let synthetic = true
}

struct CandidateFeature: Encodable {
    let type = "Feature"
    let id: String
    let geometry: PointGeometry
    let properties: CandidateProperties
}

func rounded(_ value: Double, _ digits: Double) -> Double { (value * digits).rounded() / digits }

var rng = SplitMix64(state: 0x00C4_0E9A_2026_0001)
let groves = (0..<28).map { _ in randomPoint(&rng) }
var candidates: [CandidateFeature] = []
while candidates.count < 200 {
    let lng: Double
    let lat: Double
    if rng.unit() < 0.8 {
        // In a grove: Gaussian scatter, σ = 45 m.
        let (gx, gy) = groves[Int(rng.next() % UInt64(groves.count))]
        lng = gx + rng.gaussian() * 45 / metresPerDegreeLongitude
        lat = gy + rng.gaussian() * 45 / metresPerDegreeLatitude
    } else {
        (lng, lat) = randomPoint(&rng)
    }
    guard acceptable(lng, lat) else { continue }
    let height = rounded(rng.uniform(8...38), 10)
    let crown = rounded(height * rng.uniform(0.15...0.3), 10)
    let confidence = rounded(rng.uniform(0.5...0.99), 100)
    candidates.append(
        CandidateFeature(
            id: rng.uuid(),
            geometry: PointGeometry(coordinates: [rounded(lng, 1e7), rounded(lat, 1e7)]),
            properties: CandidateProperties(height_m: height, crown_radius_m: crown, confidence: confidence)
        )
    )
}

// MARK: Boundary

struct PolygonGeometry: Encodable {
    let type = "Polygon"
    let coordinates: [[[Double]]]
}

struct BoundaryProperties: Encodable {
    let name: String
    let approximate = true
}

struct BoundaryFeature: Encodable {
    let type = "Feature"
    let id: String
    let geometry: PolygonGeometry
    let properties: BoundaryProperties
}

struct FeatureCollection<Feature: Encodable>: Encodable {
    let type = "FeatureCollection"
    let name: String
    let description: String
    let features: [Feature]
}

// MARK: Output

func write(_ value: some Encodable, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    try (String(decoding: data, as: UTF8.self) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    print("wrote \(path)")
}

try write(
    FeatureCollection(
        name: "Golden Gate Park (approximate outline)",
        description:
            "Hand-traced from the bounding streets for development; accurate to about 50 m. Not an official boundary.",
        features: [
            BoundaryFeature(
                id: "golden-gate-park",
                geometry: PolygonGeometry(coordinates: [boundary.map { [$0.0, $0.1] }]),
                properties: BoundaryProperties(name: "Golden Gate Park")
            )
        ]
    ),
    to: "Fixtures/ggp/park-boundary.geojson"
)

try write(
    FeatureCollection(
        name: "SYNTHETIC aerial tree candidates",
        description: "Made-up sample data generated by scripts/make-fixtures.swift. These are not real trees.",
        features: candidates
    ),
    to: "Fixtures/ggp/tree-candidates.geojson"
)
