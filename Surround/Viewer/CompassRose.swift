import SwiftUI

/// A small dial showing where the user is looking. With a recorded front
/// heading the dial is north-up like the map, the front is a tick at that
/// heading, and the wedge is the current field of view. Without a heading the
/// front is at the top. Tapping it recentres the view.
struct CompassRose: View {
    let state: ViewerState
    var size: CGFloat = 64

    /// Rotation of the sphere's front on the dial: its heading when known, else up.
    private var frontAngle: Angle {
        .degrees(state.frontHeadingDegrees ?? 0)
    }

    private var viewAngle: Angle {
        frontAngle + .degrees(Double(state.viewYawDegrees))
    }

    var body: some View {
        Button {
            state.recentre()
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)

                // Field of view.
                Wedge(halfAngleDegrees: Double(min(80, state.fieldOfViewDegrees)) / 2)
                    .fill(Color.accentColor.opacity(0.75))
                    .rotationEffect(viewAngle)
                    .padding(6)

                // The sphere's front (the recorded heading).
                Triangle()
                    .fill(.white)
                    .frame(width: 8, height: 7)
                    .offset(y: -size / 2 + 6)
                    .rotationEffect(frontAngle)

                if state.frontHeadingDegrees != nil {
                    ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.offset) { index, letter in
                        let angle = Angle.degrees(Double(index) * 90)
                        // Rotate the glyph back so it stays upright at its position on the dial.
                        Text(letter)
                            .font(.system(size: letter == "N" ? 10 : 8, weight: letter == "N" ? .bold : .medium))
                            .foregroundStyle(letter == "N" ? .white : .white.opacity(0.7))
                            .rotationEffect(-angle)
                            .offset(y: -size / 2 + 15)
                            .rotationEffect(angle)
                    }
                }
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recentre on the sphere's front")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if let heading = state.frontHeadingDegrees {
            let looking = (heading + Double(state.viewYawDegrees)).truncatingRemainder(dividingBy: 360)
            return String(format: "Looking %.0f degrees", looking < 0 ? looking + 360 : looking)
        }
        return String(format: "%.0f degrees from the front", state.viewYawDegrees)
    }
}

/// A sector centred on the top of its frame.
nonisolated private struct Wedge: Shape {
    var halfAngleDegrees: Double

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var p = Path()
        p.move(to: centre)
        p.addArc(center: centre, radius: radius,
                 startAngle: .degrees(-90 - halfAngleDegrees),
                 endAngle: .degrees(-90 + halfAngleDegrees),
                 clockwise: false)
        p.closeSubpath()
        return p
    }
}

nonisolated private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
