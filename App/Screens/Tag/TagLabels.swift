import CanopyDesign
import CanopyModel

extension Tag.Issue {
    var label: String {
        switch self {
        case .deadwood: "Deadwood"
        case .hanger: "Hanging limb"
        case .crack: "Crack"
        case .decay: "Decay or cavity"
        case .weakUnion: "Weak union"
        case .other: "Other"
        }
    }
}

extension Tag.Target {
    var label: String {
        switch self {
        case .path: "Path"
        case .road: "Road"
        case .seating: "Bench or seating"
        case .playArea: "Play area"
        case .structure: "Building or structure"
        case .nothing: "Nothing"
        }
    }
}

extension Tag.SizeClass {
    var label: String {
        let format = QuantityFormat()
        return switch self {
        case .small: "Under " + format.length(0.1, fractionDigits: 2)
        case .medium: format.length(0.1, fractionDigits: 2) + " to " + format.length(0.3, fractionDigits: 2)
        case .large: "Over " + format.length(0.3, fractionDigits: 2)
        }
    }

    var shortLabel: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}
