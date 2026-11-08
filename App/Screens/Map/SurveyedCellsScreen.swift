import CanopyDesign
import CanopyMap
import CanopyModel
import SwiftUI

/// The level-16 cells under the map with what the census holds in each, and the mark that says a cell has been
/// walked and looked over: its detections then count as reviewed without a tap on each.
struct SurveyedCellsScreen: View {
    let viewport: MapViewport
    @Environment(AppModel.self) private var model
    private let format = QuantityFormat()

    /// The cells with trees in them within the map's reach, nearest the centre first.
    private var cells: [CellCensus] {
        let frame = LocalFrame(origin: viewport.center)
        let reach = max(viewport.cornerDistance, 300)
        return model.cellCensus.values
            .map { ($0, frame.enu(of: $0.cell.center).horizontalDistance) }
            .filter { $0.1 <= reach }
            .sorted { $0.1 < $1.1 }
            .prefix(40)
            .map(\.0)
    }

    var body: some View {
        let cells = cells
        let surveyed = cells.filter { model.isSurveyed($0.cell) }
        let open = cells.filter { !model.isSurveyed($0.cell) }
        List {
            if !surveyed.isEmpty {
                Section("Surveyed") {
                    ForEach(surveyed, id: \.cell) { cell in row(cell, record: model.surveyedCells[cell.cell]) }
                }
            }
            Section {
                if cells.isEmpty {
                    Text("No trees in the cells under the map.")
                } else if open.isEmpty {
                    Text("Every cell under the map is surveyed.")
                } else {
                    ForEach(open, id: \.cell) { cell in row(cell, record: nil) }
                }
            } header: {
                Text("Level-16 cells under the map")
            } footer: {
                Text(
                    "A level-16 cell is about 150 m across. Confirm and reject the trees you can as you walk it, then "
                        + "mark the cell surveyed: the detections left in it count as looked over, and the cell is drawn "
                        + "in green on the map and in AR. Marks stay on this phone for now.")
            }
        }
        .navigationTitle("Surveyed cells")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ cell: CellCensus, record: SurveyedCell?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                S2CellLabel(cell.cell, font: CanopyFont.mono(.subheadline, weight: .semibold))
                Spacer()
                if let record {
                    StatusBadge("Surveyed", systemImage: "checkmark.circle", tone: .ok)
                        .accessibilityLabel(
                            "Surveyed " + record.surveyedAt.formatted(date: .abbreviated, time: .omitted))
                } else {
                    Text("\(cell.reviewed) of \(cell.total) looked at")
                        .font(CanopyFont.mono(.footnote))
                        .foregroundStyle(Color.canopyInkMuted)
                }
            }
            ProgressView(value: Double(cell.reviewed), total: Double(max(cell.total, 1)))
                .tint(record == nil ? Color.canopySurvey : Color.canopyBrand)
            HStack(spacing: Spacing.s) {
                Text(
                    "\(format.count(cell.confirmed)) confirmed · \(format.count(cell.rejected)) not trees · "
                        + "\(format.count(cell.detected)) detections left"
                )
                .font(.caption)
                .foregroundStyle(Color.canopyInkMuted)
                Spacer()
                if record == nil {
                    Button("Mark surveyed") { Task { await model.markSurveyed(cell.cell) } }
                        .buttonStyle(.borderless)
                } else {
                    Button("Unmark", role: .destructive) { Task { await model.unmarkSurveyed(cell.cell) } }
                        .buttonStyle(.borderless)
                }
            }
            .font(.footnote)
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("survey-cell-" + cell.cell.token)
    }
}
