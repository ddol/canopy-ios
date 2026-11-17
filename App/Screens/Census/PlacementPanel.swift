import CanopyCapture
import CanopyDesign
import SwiftUI
import simd

/// A tree on the placement radar, where the overlay draws it in the AR world.
struct RadarTree: Identifiable, Equatable {
    enum Kind: Equatable {
        /// One of the census's trees.
        case census
        /// One of Gerardus's trees.
        case site
        /// The selected tree.
        case focus
    }

    var id: String
    var base: SIMD3<Float>
    var kind: Kind
}

/// Lines up the overlay by hand when GPS has put it off the trees, and there is no 3DEP registration to place it:
/// a radar of the trees as they are drawn round the player, heading up, and a pad that moves the player through them
/// and turns them, as a game's would. Moving forward brings the trees ahead nearer; turning right swings them left.
/// Or put the selected tree on the trunk in the middle of the screen in one go.
struct PlacementPanel: View {
    let tracker: TreeTracker
    let trees: [RadarTree]
    /// How the overlay is placed now: by GPS, and how far it was moved and turned by hand.
    let status: String
    /// Whether the overlay can be moved: it is placed by GPS, not by a 3DEP registration.
    let canMove: Bool
    /// The selected tree's name, to put it on the trunk in the middle.
    let focusName: String?
    let isMovedByHand: Bool
    /// Moves the player through the drawing: metres forward and to the right, as the camera faces.
    var onMove: (_ forward: Double, _ right: Double) -> Void
    /// Turns the player against the drawing, degrees clockwise.
    var onTurn: (_ clockwise: Double) -> Void
    var onLineUp: () -> Void
    var onReset: () -> Void
    var onDone: () -> Void

    @State private var fine = true
    @State private var range = 20.0
    private let format = QuantityFormat()

    /// How far one press moves, in metres, and turns, in degrees.
    private var step: Double { fine ? 0.25 : 1 }
    private var turnStep: Double { fine ? 1 : 5 }

    var body: some View {
        VStack(spacing: Spacing.xs) {
            HStack(alignment: .center, spacing: Spacing.s) {
                PlacementRadar(tracker: tracker, trees: trees, range: range)
                    .onTapGesture { range = range == 10 ? 20 : range == 20 ? 40 : 10 }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Changes how far the radar reaches")
                pad
            }
            Text(status)
                .font(CanopyFont.mono(.caption2))
                .foregroundStyle(Color.canopyInkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("placement-status")
            if let focusName {
                Button("Put \(focusName) on the trunk in the middle", systemImage: "scope", action: onLineUp)
                    .buttonStyle(.canopySecondary)
                    .font(.footnote)
                    .disabled(!canMove)
                    .accessibilityIdentifier("placement-line-up")
            }
            HStack(spacing: Spacing.s) {
                Button("From GPS", systemImage: "location", action: onReset)
                    .buttonStyle(.canopySecondary)
                    .disabled(!isMovedByHand)
                    .accessibilityIdentifier("placement-reset")
                Button(action: onDone) {
                    Label("Done", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.canopyPrimary)
                .accessibilityIdentifier("placement-done")
            }
            .font(.footnote)
        }
        .padding(Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("placement-panel")
    }

    /// Forward, back, left and right, a turn each way, and the step size. Held down, a button repeats.
    private var pad: some View {
        VStack(spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xxs) {
                key("Turn left", "arrow.counterclockwise", id: "placement-turn-left") { onTurn(-turnStep) }
                key("Forward", "arrowtriangle.up.fill", id: "placement-forward") { onMove(step, 0) }
                key("Turn right", "arrow.clockwise", id: "placement-turn-right") { onTurn(turnStep) }
            }
            HStack(spacing: Spacing.xxs) {
                key("Left", "arrowtriangle.left.fill", id: "placement-left") { onMove(0, -step) }
                Button {
                    fine.toggle()
                } label: {
                    Text(fine ? "fine" : "big")
                        .font(CanopyFont.mono(.caption2))
                        .frame(width: 48, height: 44)
                        .background(Color.canopyCard, in: RoundedRectangle(cornerRadius: Radius.small))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step size")
                .accessibilityValue(fine ? "25 centimetres and 1 degree" : "1 metre and 5 degrees")
                .accessibilityIdentifier("placement-step")
                key("Right", "arrowtriangle.right.fill", id: "placement-right") { onMove(0, step) }
            }
            key("Back", "arrowtriangle.down.fill", id: "placement-back") { onMove(-step, 0) }
            Text(
                format.length(step, fractionDigits: fine ? 2 : 0) + " · "
                    + format.angle(turnStep, fractionDigits: 0)
            )
            .font(CanopyFont.mono(.caption2))
            .foregroundStyle(Color.canopyInkMuted)
        }
        .disabled(!canMove)
    }

    private func key(_ label: String, _ systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 48, height: 44)
                .background(Color.canopyCard, in: RoundedRectangle(cornerRadius: Radius.small))
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// The trees round the player as the overlay draws them, seen from above with the way the camera faces up: census
/// trees green, Gerardus's hollow, the selected tree orange, the player in the middle. The rings are at half the reach
/// and the reach.
struct PlacementRadar: View {
    let tracker: TreeTracker
    let trees: [RadarTree]
    let range: Double
    static let size: CGFloat = 168
    private let format = QuantityFormat()

    var body: some View {
        let heading = tracker.heading ?? 0
        let camera = tracker.camera
        ZStack {
            Circle().fill(Color.canopyCard.opacity(0.9))
            Circle().strokeBorder(Color.canopyLineStrong, lineWidth: 1)
            Circle()
                .stroke(Color.canopyLine, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: Self.size / 2, height: Self.size / 2)
            Canvas { context, size in
                guard let camera else { return }
                let radius = size.width / 2
                let centre = CGPoint(x: radius, y: radius)
                // The focus last, over the rest.
                for tree in trees.sorted(by: { ($0.kind == .focus ? 1 : 0) < ($1.kind == .focus ? 1 : 0) }) {
                    let placed = Compass.place(
                        Compass.offset(from: camera, to: tree.base), heading: heading, range: range)
                    guard !placed.clamped || tree.kind == .focus else { continue }
                    let at = CGPoint(
                        x: centre.x + CGFloat(placed.point.x) * (radius - 6),
                        y: centre.y + CGFloat(placed.point.y) * (radius - 6))
                    switch tree.kind {
                    case .census:
                        context.fill(dot(at, 3.5), with: .color(Color.canopyBrand))
                    case .site:
                        context.stroke(dot(at, 4.5), with: .color(StatusTone.moved.foreground.color), lineWidth: 1.5)
                    case .focus:
                        context.fill(dot(at, 6), with: .color(Color.canopySurvey))
                        context.stroke(dot(at, 6), with: .color(.white), lineWidth: 1.5)
                    }
                }
            }
            Image(systemName: tracker.heading == nil ? "circle.fill" : "location.north.fill")
                .font(.system(size: tracker.heading == nil ? 8 : 14))
                .foregroundStyle(Color.canopyInk)
            Text(format.length(range, fractionDigits: 0))
                .font(CanopyFont.mono(.caption2))
                .foregroundStyle(Color.canopyInkMuted)
                .offset(y: Self.size / 2 - 10)
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Radar of the trees as drawn, \(trees.count) within reach")
        .accessibilityIdentifier("placement-radar")
    }

    private func dot(_ at: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r))
    }
}
