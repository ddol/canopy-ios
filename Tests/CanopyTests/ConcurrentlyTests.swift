import Foundation
import Testing

@testable import Canopy

@Suite struct ConcurrentlyTests {
    actor Gauge {
        var running = 0
        var most = 0

        func enter() {
            running += 1
            most = max(most, running)
        }

        func leave() { running -= 1 }
    }

    struct Refused: Error {}

    @Test func asksAFewAtATimeAndKeepsTheOrder() async throws {
        let gauge = Gauge()
        let results = try await AppModel.concurrently(Array(0..<20), width: 4) { k in
            await gauge.enter()
            // Later items finish first, so the order has to be put back.
            try await Task.sleep(for: .milliseconds(5 * (20 - k)))
            await gauge.leave()
            return k * k
        }
        #expect(results == (0..<20).map { $0 * $0 })
        #expect(await gauge.most == 4)
        #expect(try await AppModel.concurrently([Int](), width: 4) { $0 }.isEmpty)
    }

    @Test func aFailureFailsTheWhole() async {
        await #expect(throws: Refused.self) {
            _ = try await AppModel.concurrently(Array(0..<8)) { k in
                if k == 5 { throw Refused() }
                return k
            }
        }
    }
}
