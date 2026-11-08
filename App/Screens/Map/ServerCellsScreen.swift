import CanopyDesign
import CanopyMap
import CanopyModel
import SwiftUI

/// The S2 level-13 cells under the map, and how many of each cell's 64 sites the Gerardus server has prepared,
/// with the option to prepare the rest or build the whole cell again.
struct ServerCellsScreen: View {
    let viewport: MapViewport
    @Environment(AppModel.self) private var model
    @State private var coverage: [CellCoverage] = []
    @State private var error: String?
    @State private var loading = false
    @State private var reload = UUID()
    private let format = QuantityFormat()

    var body: some View {
        List {
            if let preparation = model.cellPreparation {
                Section("Preparing \(preparation.cell.familyDisplay)") {
                    PreparationRow(preparation: preparation)
                }
            }
            Section {
                if loading, coverage.isEmpty {
                    ProgressView("Asking the server which sites it has…")
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                } else if coverage.isEmpty {
                    Text("No cells under the map.")
                } else {
                    ForEach(coverage) { cell in
                        CellRow(coverage: cell, distance: distance(to: cell.cell)) { refresh in
                            model.prepareCell(cell, refresh: refresh)
                        }
                    }
                }
            } header: {
                Text("Level-13 cells under the map")
            } footer: {
                Text(
                    "A level-13 cell is about 1.2 km across and holds 64 level-16 sites. Preparing a site fetches its "
                        + "aerial points, footprints and streets and builds its model, a minute or two each; a whole "
                        + "cell takes an hour or more and carries on in the background. Rebuilding fetches every "
                        + "source again.")
            }
        }
        .navigationTitle("Server cells")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Reload", systemImage: "arrow.clockwise") { reload = UUID() }
                .disabled(loading)
        }
        .task(id: reload) {
            loading = true
            defer { loading = false }
            do {
                coverage = try await model.cellCoverage(in: viewport)
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onChange(of: model.cellPreparation?.isFinished) {
            if model.cellPreparation?.isFinished == true { reload = UUID() }
        }
    }

    private func distance(to cell: S2CellID) -> String {
        format.length(LocalFrame(origin: viewport.center).enu(of: cell.center).horizontalDistance, fractionDigits: 0)
    }
}

private struct CellRow: View {
    let coverage: CellCoverage
    let distance: String
    var onPrepare: (_ refresh: Bool) -> Void
    @Environment(AppModel.self) private var model

    private var busy: Bool { model.cellPreparation?.isRunning == true }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(coverage.cell.familyDisplay).font(CanopyFont.mono(.subheadline, weight: .semibold))
                Spacer()
                if coverage.isComplete {
                    StatusBadge("Complete", systemImage: "checkmark.circle", tone: .ok)
                } else {
                    Text("\(coverage.count) of \(coverage.total) sites")
                        .font(CanopyFont.mono(.footnote))
                        .foregroundStyle(Color.canopyInkMuted)
                }
            }
            ProgressView(value: Double(coverage.count), total: Double(coverage.total))
                .tint(coverage.isComplete ? Color.canopyBrand : Color.canopySurvey)
            HStack(spacing: Spacing.s) {
                Text(distance + " from the map centre")
                    .font(.caption)
                    .foregroundStyle(Color.canopyInkMuted)
                Spacer()
                if !coverage.isComplete {
                    Button("Prepare the rest") { onPrepare(false) }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                }
                Button("Rebuild all", role: .destructive) { confirmingRebuild = true }
                    .buttonStyle(.borderless)
                    .disabled(busy)
            }
            .font(.footnote)
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
        // Rebuilding makes the server fetch every source again for every site in the cell: an hour or more of its
        // time, and the sites already prepared are rebuilt too. One stray tap should not start that.
        .confirmationDialog(
            "Rebuild all \(coverage.total) sites in \(coverage.cell.familyDisplay)?", isPresented: $confirmingRebuild,
            titleVisibility: .visible
        ) {
            Button("Rebuild all \(coverage.total) sites", role: .destructive) { onPrepare(true) }
        } message: {
            Text(
                "The server fetches the aerial points, footprints and streets again for every site in the cell, the "
                    + "\(coverage.count) already prepared included, and builds each model afresh. That takes an hour or "
                    + "more of the server's time.")
        }
    }

    @State private var confirmingRebuild = false
}

private struct PreparationRow: View {
    let preparation: CellPreparation

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                if preparation.isRunning { ProgressView().controlSize(.small) }
                Text(
                    preparation.isRunning
                        ? "\(preparation.done) of \(preparation.total) done"
                            + (preparation.current.map { " · preparing \($0)" } ?? "")
                        : "Finished: \(preparation.done - preparation.failed.count) of \(preparation.total) prepared"
                )
                .font(CanopyFont.mono(.footnote))
                Spacer()
                if preparation.isRunning {
                    Button("Cancel") { preparation.cancel() }.buttonStyle(.borderless).font(.footnote)
                }
            }
            ProgressView(value: Double(preparation.done), total: Double(max(preparation.total, 1)))
            if !preparation.failed.isEmpty {
                Text(preparation.failed.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(StatusTone.hazard.foreground.color)
            }
        }
        .accessibilityIdentifier("cell-preparation")
    }
}
