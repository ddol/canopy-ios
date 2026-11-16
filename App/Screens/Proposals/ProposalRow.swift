import CanopyDesign
import CanopyMap
import CanopyModel
import SwiftUI

/// Where one of the player's proposals stands, in words: what it still needs to reach the shared map.
enum ProposalStatus {
    @MainActor
    static func explain(_ changeset: Changeset, in model: AppModel) -> String {
        let format = QuantityFormat()
        switch changeset.state {
        case .applied:
            return "On the shared map."
        case .rejected:
            return "Rejected by a trusted player: \(changeset.stateReason ?? "no reason given")."
        case .conflicted:
            return "The tree changed on the shared map before this was applied"
                + (changeset.stateReason.map { " (\($0))" } ?? "") + ". Look at it again and propose afresh."
        case .pending, .approved:
            break
        }
        guard model.mapClient != nil else {
            return "On this phone only, with the simulated server. Set a Gerardus server in Me → Settings to share it."
        }
        let made = model.madeHere(changeset)
        guard !made || model.lastSync?.known.contains(changeset.id) == true else {
            return "Not on the server yet. Canopy sends it on its own when it can reach the server."
        }
        // One from another device came from the server, so it is there.
        let device = made ? "" : "Sent from your other device. "
        let authorTrusted = model.serverPlayer?.isTrusted ?? model.player.isTrusted
        let others = changeset.approvals.count
        let need: String
        switch changeset.need(authorTrusted: authorTrusted) {
        case .nothing:
            need = "Agreed. It reaches the shared map at the next sync."
        case .anotherPlayer:
            need =
                authorTrusted
                ? "Needs one more player to agree. You're trusted, so anyone will do."
                : "A trusted player agreed. Needs one more player to agree."
        case .trustedPlayer:
            need =
                others == 0
                ? "Needs a trusted player to agree. It is in their Review queue when they look at this area."
                : "\(format.count(others)) \(others == 1 ? "player" : "players") agreed. Still needs a trusted player."
        }
        return device + need
    }
}

/// One of the player's proposals: the trees it is about, what it changes, its state and what it still needs.
struct ProposalRow: View {
    let changeset: Changeset
    @Environment(AppModel.self) private var model

    private var trees: String {
        Set(changeset.ops.map(\.id)).compactMap { model.tree($0)?.name }.sorted().joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .firstTextBaseline) {
                Text(ChangesetSummary.describe(changeset))
                    .font(.body.weight(.semibold))
                Spacer()
                StatusBadge(changeset.state.presentation)
            }
            if !trees.isEmpty {
                Text(trees).font(.subheadline)
            }
            Text(ProposalStatus.explain(changeset, in: model))
                .font(.footnote)
                .accessibilityIdentifier("proposal-need")
            HStack(spacing: Spacing.xs) {
                Text(changeset.meta.createdAt, style: .relative)
                if !changeset.approvals.isEmpty {
                    Text("·")
                    let trusted = changeset.approvals.filter(\.isTrusted).count
                    Label(
                        trusted == 0
                            ? "\(changeset.approvals.count) agreed"
                            : "\(changeset.approvals.count) agreed, \(trusted) trusted",
                        systemImage: "hand.thumbsup")
                }
            }
            .font(.caption)
            .foregroundStyle(Color.canopyInkMuted)
        }
        .accessibilityElement(children: .combine)
    }
}
