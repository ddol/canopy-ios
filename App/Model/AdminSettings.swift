import CanopyModel
import CryptoKit
import Foundation
import Observation

/// Flags for checking Canopy's data, shown in Settings only to admins: the Game Center players whose ids, or the
/// SHA-256 hashes of them, are in the `CANOPY_ADMIN_PLAYER_IDS` and `CANOPY_ADMIN_PLAYER_HASHES` build settings (set
/// them in the git-ignored Configs/Local.xcconfig, so the list stays out of the public repository; a hash keeps the id
/// out of the build too), anyone the Gerardus server calls an admin (`AppModel.isAdmin`), and anyone in a debug build.
/// Every flag is off until an admin turns it on, except the whole city, which is on until turned off.
@Observable
final class AdminSettings {
    static let osmKey = "canopy.admin.useOSM"
    static let wholeCityKey = "canopy.admin.wholeCity"

    /// Game Center team-scoped player ids allowed to see the flags.
    let allowlist: Set<String>
    /// SHA-256 hashes of more such ids (`hash(_:)`), in lower-case hex.
    let hashes: Set<String>
    /// Debug builds: everyone is an admin.
    let everyoneIsAdmin: Bool
    @ObservationIgnored private let defaults: UserDefaults

    /// Ask the server for OpenStreetMap too, and mask its buildings out of tree detection. For checking detection
    /// only: OpenStreetMap never goes into the shared tree layer.
    var useOSM: Bool {
        didSet { defaults.set(useOSM, forKey: Self.osmKey) }
    }

    /// Show the whole city on the map: every tile in it shaded from the server's counts, and every tile the server
    /// holds trees in pulled to this phone, not just the ones round where the map has been. For admins until it is
    /// ready for everyone.
    var wholeCity: Bool {
        didSet { defaults.set(wholeCity, forKey: Self.wholeCityKey) }
    }

    init(
        allowlist: Set<String>, hashes: Set<String> = [], everyoneIsAdmin: Bool, defaults: UserDefaults = .standard
    ) {
        self.allowlist = allowlist
        self.hashes = Set(hashes.map { $0.lowercased() })
        self.everyoneIsAdmin = everyoneIsAdmin
        self.defaults = defaults
        self.useOSM = defaults.bool(forKey: Self.osmKey)
        self.wholeCity = defaults.object(forKey: Self.wholeCityKey) as? Bool ?? true
    }

    /// The settings for this build: the allowlist and the hashes from Info.plist (`CanopyAdminPlayerIDs`,
    /// `CanopyAdminPlayerHashes`).
    static func live(bundle: Bundle = .main) -> AdminSettings {
        #if DEBUG
            let debug = true
        #else
            let debug = false
        #endif
        return AdminSettings(
            allowlist: allowlist(from: bundle.object(forInfoDictionaryKey: "CanopyAdminPlayerIDs") as? String ?? ""),
            hashes: allowlist(from: bundle.object(forInfoDictionaryKey: "CanopyAdminPlayerHashes") as? String ?? ""),
            everyoneIsAdmin: debug)
    }

    /// Like `live`, but remembering flags only until the app quits: for tests and UI tests.
    static func volatile(bundle: Bundle = .main) -> AdminSettings {
        let name = "canopy.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let build = live(bundle: bundle)
        return AdminSettings(
            allowlist: build.allowlist, hashes: build.hashes, everyoneIsAdmin: build.everyoneIsAdmin, defaults: defaults
        )
    }

    /// Player ids separated by spaces or commas.
    static func allowlist(from text: String) -> Set<String> {
        Set(text.split { $0 == " " || $0 == "," }.map(String.init))
    }

    func isAdmin(_ player: Player) -> Bool {
        guard !everyoneIsAdmin else { return true }
        guard player.source == .gameCenter else { return false }
        return allowlist.contains(player.id.rawValue) || hashes.contains(Self.hash(player.id.rawValue))
    }

    /// A player id's SHA-256 hash, as `CANOPY_ADMIN_PLAYER_HASHES` lists it: the id's UTF-8 bytes hashed, in
    /// lower-case hex (the build setting may give it in either case). `printf %s 'T:_…' | shasum -a 256` gives the same.
    static func hash(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
