import CanopyDesign
import CanopyModel

/// Word, icon and tone for each status, so every screen shows a status the same way.
public struct StatusPresentation: Equatable, Sendable {
    public var label: String
    public var systemImage: String
    public var tone: StatusTone

    public init(_ label: String, systemImage: String, tone: StatusTone) {
        self.label = label
        self.systemImage = systemImage
        self.tone = tone
    }
}

extension StatusBadge {
    public init(_ presentation: StatusPresentation) {
        self.init(presentation.label, systemImage: presentation.systemImage, tone: presentation.tone)
    }
}

extension CountStatus {
    public var presentation: StatusPresentation {
        switch self {
        case .detected: StatusPresentation("Detected", systemImage: "scope", tone: .moved)
        case .proposed: StatusPresentation("Proposed", systemImage: "clock", tone: .proposed)
        case .confirmed: StatusPresentation("Confirmed", systemImage: "checkmark.circle", tone: .ok)
        case .verified: StatusPresentation("Verified", systemImage: "checkmark.seal", tone: .ok)
        case .removed: StatusPresentation("Removed", systemImage: "xmark.circle", tone: .hazard)
        }
    }
}

extension Tag.Urgency {
    public var presentation: StatusPresentation {
        switch self {
        case .low: StatusPresentation("Low", systemImage: "arrow.down.circle", tone: .moved)
        case .moderate: StatusPresentation("Moderate", systemImage: "exclamationmark.circle", tone: .watch)
        case .high: StatusPresentation("High", systemImage: "exclamationmark.triangle", tone: .hazard)
        case .immediate: StatusPresentation("Immediate", systemImage: "exclamationmark.octagon", tone: .hazard)
        }
    }
}

extension Tag.Status {
    public var presentation: StatusPresentation {
        switch self {
        case .proposed: StatusPresentation("Proposed", systemImage: "clock", tone: .proposed)
        case .confirmed: StatusPresentation("Confirmed", systemImage: "checkmark.circle", tone: .ok)
        case .resolved: StatusPresentation("Resolved", systemImage: "checkmark.seal", tone: .ok)
        }
    }
}

extension Changeset.State {
    public var presentation: StatusPresentation {
        switch self {
        case .pending: StatusPresentation("Pending", systemImage: "clock", tone: .proposed)
        case .approved: StatusPresentation("Approved", systemImage: "hand.thumbsup", tone: .ok)
        case .applied: StatusPresentation("On the map", systemImage: "checkmark.circle", tone: .ok)
        case .rejected: StatusPresentation("Rejected", systemImage: "xmark.octagon", tone: .hazard)
        case .conflicted:
            StatusPresentation("Conflict", systemImage: "exclamationmark.arrow.triangle.2.circlepath", tone: .watch)
        }
    }
}
