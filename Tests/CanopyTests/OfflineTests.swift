import Foundation
import Testing

@testable import Canopy

/// Offline first: losing the network is not an error to show, and nothing is asked of the server meanwhile.
@MainActor
@Suite struct OfflineTests {
    @Test func theNetworkBeingOutOfReachIsNotAnError() {
        for code: URLError.Code in [
            .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .timedOut,
        ] {
            #expect(AppModel.isOffline(URLError(code)), "\(code)")
        }
        // Wrapped, as a gRPC call reports it.
        let wrapped = NSError(
            domain: "io.github.ddol.canopy", code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet)])
        #expect(AppModel.isOffline(wrapped))
        // The server answering, and saying no, is.
        #expect(!AppModel.isOffline(URLError(.badServerResponse)))
        #expect(!AppModel.isOffline(URLError(.userAuthenticationRequired)))
    }
}
