import CanopyDesign
import CanopyMap
import CanopyModel
import CanopyReference
import SwiftUI

/// Proposals, one list at a time: other players' changes to review, the player's open proposals, and their history.
/// Pull down to sync.
struct ProposalsScreen: View {
    /// The lists the tab switches between.
    enum Part: Hashable {
        case review
        case yours
        case history
    }

    /// Which list shows. A list the player picks stays picked. Until they pick one, the tab opens on Review when
    /// something waits there and on Yours otherwise, each time it appears, and keeps that list while it shows, so
    /// agreeing with the last change does not switch lists under the player.
    struct Choice {
        /// The list the player picked with the control.
        private var picked: Part?
        /// The list the tab opened on this time, until the player leaves it.
        private var opened: Part?

        func part(awaiting: Int) -> Part {
            picked ?? opened ?? ProposalsScreen.firstPart(awaiting: awaiting)
        }

        mutating func pick(_ part: Part) {
            picked = part
        }

        mutating func appear(awaiting: Int) {
            opened = part(awaiting: awaiting)
        }

        mutating func disappear() {
            opened = nil
        }
    }

    @Environment(AppModel.self) private var model
    @State private var choice = Choice()
    /// The tree of the proposal the player tapped.
    @State private var shownTree: Tree?

    private var part: Part { choice.part(awaiting: model.proposalsAwaitingPlayer) }

    /// The list the tab opens on: Review when other players' changes wait there, otherwise the player's own.
    static func firstPart(awaiting: Int) -> Part {
        awaiting > 0 ? .review : .yours
    }

    var body: some View {
        NavigationStack {
            List {
                switch part {
                case .review:
                    reviewSection
                case .yours:
                    let open = model.openProposals
                    yoursSection(open)
                    #if DEBUG || TESTING_TOOLS
                        debugSection(open)
                    #endif
                case .history:
                    historySection(model.closedProposals)
                }
            }
            .navigationTitle("Proposals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("List", selection: Binding(get: { part }, set: { choice.pick($0) })) {
                        Text("Review").tag(Part.review)
                        Text("Yours").tag(Part.yours)
                        Text("History").tag(Part.history)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("proposals-list-picker")
                }
            }
            .refreshable {
                await model.sync()
            }
            .onAppear {
                choice.appear(awaiting: model.proposalsAwaitingPlayer)
            }
            .onDisappear {
                // So the tab opens afresh next time: on Review if a sync brought changes to review meanwhile.
                choice.disappear()
            }
            .sheet(item: $shownTree) { tree in
                TreeSheet(tree: tree)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: Lists

    @ViewBuilder
    private var reviewSection: some View {
        let queue = model.gerardusURL == nil ? [] : model.reviewQueue
        Section {
            if model.gerardusURL == nil {
                Text("Other players' changes near you show here once a Gerardus server is set in Me → Settings.")
                    .foregroundStyle(Color.canopyInkMuted)
            } else if queue.isEmpty {
                Text(
                    model.lastSync == nil
                        ? "Pull down to sync and see other players' changes near you."
                        : "Nothing waiting near you."
                )
                .foregroundStyle(Color.canopyInkMuted)
            }
            ForEach(queue, id: \.changeset.id) { item in
                ReviewRow(item: item, canReject: model.serverPlayer?.isTrusted == true)
            }
        } header: {
            Text("Review (\(queue.count))")
        } footer: {
            Text(
                "Agree when you have seen the change on the ground. It reaches the shared map when two players agree "
                    + "and one of them is trusted."
                    + (model.serverPlayer?.isTrusted == true ? " As a trusted player you can also reject it." : ""))
        }
    }

    private func yoursSection(_ open: [Changeset]) -> some View {
        Section {
            if open.isEmpty {
                Text("Nothing waiting. Confirm, measure or add a tree to propose a change.")
                    .foregroundStyle(Color.canopyInkMuted)
            }
            ForEach(open) { changeset in
                proposal(changeset)
            }
        } header: {
            Text("Your proposals (\(open.count))")
        } footer: {
            Text("A change reaches the shared map when a second player agrees and at least one of you is trusted.")
        }
    }

    private func historySection(_ closed: [Changeset]) -> some View {
        Section {
            if closed.isEmpty {
                Text("Nothing yet. Your proposals move here once they are on the shared map, rejected or in conflict.")
                    .foregroundStyle(Color.canopyInkMuted)
            }
            ForEach(closed) { changeset in
                proposal(changeset)
            }
        } header: {
            Text("History (\(closed.count))")
        }
    }

    /// A proposal row; tapping it opens its tree.
    private func proposal(_ changeset: Changeset) -> some View {
        Button {
            shownTree = changeset.ops.lazy.compactMap { model.tree($0.id) }.first
        } label: {
            ProposalRow(changeset: changeset)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("changeset-row")
    }

    #if DEBUG || TESTING_TOOLS
        private func debugSection(_ open: [Changeset]) -> some View {
            Section {
                Button("Simulate trusted approval", systemImage: "checkmark.shield") {
                    Task { await model.simulateTrustedApproval() }
                }
                .disabled(open.isEmpty || model.mapClient != nil)
            } header: {
                Text("Debug")
            } footer: {
                Text(
                    "A simulated trusted ranger approves every pending change on the simulated server, when no "
                        + "server is set.")
            }
        }
    #endif
}

#Preview {
    ProposalsScreen()
        .environment(AppModel.live(arguments: ["-ui-testing"]))
}
