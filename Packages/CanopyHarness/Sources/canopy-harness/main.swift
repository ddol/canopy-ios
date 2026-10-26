import CanopyHarness
import Foundation

// Line by line, so a script reading the output sees each line as it is printed.
setvbuf(stdout, nil, _IOLBF, 0)

// canopy-harness serve  — a stand-in Gerardus server with a synthetic park, for the simulator or a phone.
// canopy-harness bench  — measure loading real trees under each network profile, and the work on the phone.
// See docs/PERFORMANCE.md.

let usage = """
    usage: canopy-harness serve [--port 50099] [--profile loopback|lan|cellular|poor] [--any-interface] [--unprepared]
           canopy-harness bench [--profiles loopback,lan,cellular,poor] [--out report.json] [--compare base.json]
                                [--loads-only | --work-only] [--no-cache]
    """

guard CommandLine.arguments.count > 1 else {
    print(usage)
    exit(2)
}
let command = CommandLine.arguments[1]
let arguments = Array(CommandLine.arguments.dropFirst(2))

func option(_ name: String) -> String? {
    guard let k = arguments.firstIndex(of: name), k + 1 < arguments.count else { return nil }
    return arguments[k + 1]
}

func flag(_ name: String) -> Bool { arguments.contains(name) }

func profile(named name: String) -> NetworkProfile {
    guard let profile = NetworkProfile.all.first(where: { $0.name == name }) else {
        print("unknown profile \(name); one of \(NetworkProfile.all.map(\.name).joined(separator: ", "))")
        exit(2)
    }
    return profile
}

func shell(_ command: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

switch command {
case "serve":
    let site = SyntheticSite()
    let align = StandInAlign(site: site, prepared: !flag("--unprepared"), preparation: .seconds(8), anywhere: true)
    let server = StandInServer(
        align: align, map: StandInMap(), profile: profile(named: option("--profile") ?? "loopback"))
    try await server.start(port: UInt16(option("--port") ?? "50099") ?? 50099, anyInterface: flag("--any-interface"))
    print("Serving \(site.token) (\(site.trees.count) trees, \(site.points.count) points) at \(server.url)")
    print("Link: \(server.profile). Set it in Canopy → Me → Settings. Every tile has a synthetic site. Ctrl-C stops.")
    while true {
        try await Task.sleep(for: .seconds(30))
        let stats = server.stats
        if stats.totalCalls > 0 {
            print("calls \(stats.calls), \(stats.totalBytes) bytes over \(stats.connections) connections")
            server.resetStats()
        }
    }

case "bench":
    let site = SyntheticSite()
    print("Synthetic site \(site.token): \(site.trees.count) trees, \(site.points.count) points")
    var loads: [Bench.Load] = []
    var work: [Bench.Work] = []
    if !flag("--work-only") {
        let names = (option("--profiles") ?? "loopback,lan,cellular").split(separator: ",").map(String.init)
        for name in names {
            let p = profile(named: name)
            print("Loads over \(p)")
            loads += try await Bench.loads(site: site, profile: p, cached: !flag("--no-cache"), log: { print($0) })
        }
    }
    if !flag("--loads-only") {
        print("Work on this machine")
        work = try await Bench.work(site: site, log: { print($0) })
    }
    let report = Bench.Report(
        date: .now, machine: shell("sysctl -n hw.model") + ", " + shell("sysctl -n machdep.cpu.brand_string"),
        commit: shell("git rev-parse --short HEAD") + (shell("git status --porcelain").isEmpty ? "" : "+dirty"),
        site: "\(site.token) seed 1: \(site.trees.count) trees, \(site.points.count) points", loads: loads, work: work)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let out = option("--out") {
        try encoder.encode(report).write(to: URL(fileURLWithPath: out))
        print("Wrote \(out)")
    }
    if let base = option("--compare") {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let before = try decoder.decode(Bench.Report.self, from: Data(contentsOf: URL(fileURLWithPath: base)))
        print(Bench.compare(before, report))
    }

default:
    print(usage)
    exit(2)
}
