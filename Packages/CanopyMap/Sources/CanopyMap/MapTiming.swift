import Foundation
import os

/// How long the map's own work takes on the main thread: making the layers, and each renderer applying them. Each step
/// is a signpost interval (subsystem `io.github.ddol.canopy`, category `map`) for Instruments, and a step slower than
/// 4 ms is logged at debug level with its time, so `log stream --level debug` shows what holds up a gesture.
public enum MapTiming {
    static let signposter = OSSignposter(subsystem: "io.github.ddol.canopy", category: "map")
    static let log = Logger(subsystem: "io.github.ddol.canopy", category: "map")

    /// Runs `body` as the step `name`.
    public static func measure<Result>(_ name: StaticString, _ body: () throws -> Result) rethrows -> Result {
        let state = signposter.beginInterval(name)
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            let elapsed = ContinuousClock.now - start
            if elapsed > .milliseconds(4) {
                let milliseconds =
                    Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
                log.debug("\(name, privacy: .public) \(milliseconds, format: .fixed(precision: 1)) ms")
            }
        }
        return try body()
    }
}
