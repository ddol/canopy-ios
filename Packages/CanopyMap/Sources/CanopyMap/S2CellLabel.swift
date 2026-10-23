import CanopyDesign
import CanopyModel
import SwiftUI

/// An S2 cell as people see it: its family display (`80858-745b` for the canonical token `80858745b`), in the
/// monospaced figures font and selectable, so a copy gives exactly the family display.
///
/// Follows the S2 style guide shared with velocity.report: family displays are for human-facing text only, and
/// anything stored, keyed or sent uses the canonical token. The guide's scan cue (a small visual gap inside the
/// family prefix) is standardised only for its L10/L13 displays, so Canopy's L16 tiles and L19 chunks are shown
/// without it.
public struct S2CellLabel: View {
    public let cell: S2CellID
    public var font: Font

    public init(_ cell: S2CellID, font: Font = CanopyFont.mono(.footnote)) {
        self.cell = cell
        self.font = font
    }

    public var body: some View {
        Text(verbatim: cell.familyDisplay)
            .font(font)
            .textSelection(.enabled)
    }
}
