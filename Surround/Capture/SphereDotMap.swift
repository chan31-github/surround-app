import SurroundCore
import SwiftUI

/// The plan as a small map of the sphere: yaw across, from the front at the
/// left edge once around, pitch down, so a capture reads as one sweep from
/// left to right whatever order the targets come in. Used for progress
/// during capture and for picking a shot to retake afterwards.
struct SphereDotMap: View {
    let plan: CapturePlan
    /// Targets that already have a shot.
    var done: Set<Int> = []
    /// The target being worked on, drawn larger with a column line.
    var current: Int?
    /// The target the user has picked, drawn ringed.
    var selected: Int?
    var onTap: ((Int) -> Void)?

    private var inset: CGFloat { onTap == nil ? 8 : 18 }
    private var dotSize: CGFloat { onTap == nil ? 6 : 12 }

    private var startYaw: Float { plan.targets.first?.yawDegrees ?? 0 }
    private var hasPitch: Bool { plan.targets.contains { $0.pitchDegrees != 0 } }

    private func point(_ t: CaptureTarget, in size: CGSize) -> CGPoint {
        let fx = CGFloat(Angle.wrapDegrees360(t.yawDegrees - startYaw) / 360)
        let fy: CGFloat = hasPitch ? CGFloat((90 - t.pitchDegrees) / 180) : 0.5
        return CGPoint(x: inset + fx * (size.width - 2 * inset),
                       y: inset + fy * (size.height - 2 * inset))
    }

    private func colour(_ t: CaptureTarget) -> Color {
        if t.id == current { return .yellow }
        if done.contains(t.id) { return .green }
        return .white.opacity(0.35)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.35))
                if hasPitch {
                    // The horizon.
                    Rectangle()
                        .fill(.white.opacity(0.15))
                        .frame(height: 1)
                }
                if let current, current < plan.targets.count {
                    Rectangle()
                        .fill(.yellow.opacity(0.35))
                        .frame(width: 2)
                        .position(x: point(plan.targets[current], in: geo.size).x, y: geo.size.height / 2)
                }
                ForEach(plan.targets) { target in
                    dot(target)
                        .position(point(target, in: geo.size))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: current)
    }

    @ViewBuilder
    private func dot(_ target: CaptureTarget) -> some View {
        let size = target.id == current ? dotSize * 1.5 : dotSize
        let marker = Circle()
            .fill(colour(target))
            .frame(width: size, height: size)
            .overlay {
                if target.id == selected {
                    Circle().strokeBorder(.white, lineWidth: 2).padding(-4)
                }
            }
        if let onTap {
            Button { onTap(target.id) } label: {
                marker
                    .frame(width: dotSize * 2.4, height: dotSize * 2.4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            marker
        }
    }
}
