import CanopyDesign
import CanopyMap
import CanopyModel
import CanopyReference
import SwiftUI

/// Another player's open change: what it does, to which tree, who proposed it, and Agree (or Reject, for trusted
/// players).
struct ReviewRow: View {
    let item: GerardusMapClient.OpenChangeset
    let canReject: Bool
    @Environment(AppModel.self) private var model
    @State private var rejecting = false
    @State private var reason = ""

    private var subjects: String {
        Set(item.changeset.ops.map(\.id)).compactMap { model.tree($0)?.name }.sorted().joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(ChangesetSummary.describe(item.changeset))
                .font(.body.weight(.semibold))
            if !subjects.isEmpty {
                Text(subjects).font(.subheadline)
            }
            HStack(spacing: Spacing.xs) {
                Text(item.authorAlias.isEmpty ? "A player" : item.authorAlias)
                if item.authorTrusted {
                    Image(systemName: "checkmark.shield").accessibilityLabel("trusted")
                }
                Text("·")
                Text(item.changeset.meta.createdAt, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(Color.canopyInkMuted)
            HStack(spacing: Spacing.s) {
                Button("Agree", systemImage: "hand.thumbsup") {
                    Task { await model.review(item, approve: true) }
                }
                .buttonStyle(.canopyPrimary)
                .accessibilityIdentifier("review-agree")
                if canReject {
                    Button("Reject", systemImage: "hand.thumbsdown") { rejecting = true }
                        .buttonStyle(.canopySecondary)
                }
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityIdentifier("review-row")
        .alert("Reject this change?", isPresented: $rejecting) {
            TextField("Why", text: $reason)
            Button("Reject", role: .destructive) {
                let reason = reason.trimmingCharacters(in: .whitespaces)
                Task {
                    await model.review(item, approve: false, reason: reason.isEmpty ? "Not seen on the ground" : reason)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A rejected change never reaches the shared map. Say what you saw.")
        }
    }
}
