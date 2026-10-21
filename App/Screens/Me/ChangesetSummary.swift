import CanopyDesign
import CanopyModel

/// Plain-language summaries of changeset operations, for the Me tab.
enum ChangesetSummary {
    static func describe(_ changeset: Changeset) -> String {
        changeset.ops.map(describe).joined(separator: "; ")
    }

    static func describe(_ op: ChangeOp) -> String {
        switch (op.entity, op.op) {
        case (.tree, .create):
            return "New tree"
        case (.tree, .update):
            if let dbh = try? op.fields["dbh"]?.decode(DBH.self) {
                let value = QuantityFormat().length(dbh.diameter.value, uncertainty: dbh.diameter.uncertainty)
                return "Measure trunk, DBH \(value)"
            }
            switch op.fields["countStatus"]?.stringValue {
            case "confirmed": return "Confirm tree"
            case "removed": return "Not a tree"
            default: return "Update tree"
            }
        case (.tag, .create):
            let issue = op.fields["issue"]?.stringValue.flatMap(Tag.Issue.init(rawValue:))
            return "Hazard tag" + (issue.map { ": " + $0.label.lowercased() } ?? "")
        case (.route, .create):
            return "New route"
        case (_, .delete):
            return "Remove \(op.entity.rawValue)"
        default:
            return "Update \(op.entity.rawValue)"
        }
    }
}
