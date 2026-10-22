import CanopyCapture
import SwiftUI

/// Census: confirm, add, reject and measure trees. LiDAR devices get the AR view; others get a verification
/// list (map-only actions).
struct CensusScreen: View {
    var body: some View {
        NavigationStack {
            Group {
                if LiDAR.isAvailable {
                    LiDARCensusView()
                } else {
                    VerificationCensusView()
                }
            }
            .navigationTitle("Census")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    CensusScreen()
        .environment(AppModel.live(arguments: ["-ui-testing"]))
}
