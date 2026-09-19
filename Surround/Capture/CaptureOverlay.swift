import SwiftUI
import SurroundCore

/// Guidance drawn over the camera preview: the next target, the crosshair,
/// tracking warnings and the ring's progress.
struct CaptureOverlay: View {
    let capture: CaptureSession
    @Binding var planKind: CapturePlanKind
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        GeometryReader { geo in
            let centre = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                if capture.phase == .capturing, let alignment = capture.alignment {
                    let pointsPerDegree = geo.size.width / CGFloat(max(20, capture.yawFieldOfViewDegrees))
                    let dx = CGFloat(alignment.deltaYawDegrees) * pointsPerDegree
                    let dy = -CGFloat(alignment.deltaPitchDegrees) * pointsPerDegree
                    let maxRadius = min(geo.size.width, geo.size.height) * 0.42
                    let distance = hypot(dx, dy)
                    let scale = distance > maxRadius ? maxRadius / distance : 1
                    TargetMarker(aligned: alignment.isAligned,
                                 ready: alignment.isReadyToCapture,
                                 farAway: distance > maxRadius)
                        .position(x: centre.x + dx * scale, y: centre.y + dy * scale)
                        .animation(.linear(duration: 0.05), value: dx + dy)
                }

                Crosshair()
                    .position(centre)

                VStack {
                    topBar
                    Spacer()
                    bottomBar
                }
                .padding()
            }
        }
    }

    private var topBar: some View {
        VStack(spacing: 8) {
            if let warning = capture.trackingWarning {
                Text(warning)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.yellow, in: Capsule())
                    .foregroundStyle(.black)
            }
            if let plan = capture.plan {
                CoverageMap(plan: plan, done: capture.shots.count, current: capture.currentTargetIndex)
                    .frame(width: 240, height: plan.targets.contains { $0.pitchDegrees != 0 } ? 72 : 28)
                ProgressView(value: Double(capture.shots.count), total: Double(plan.targets.count))
                    .progressViewStyle(.linear)
                    .tint(.green)
                    .frame(width: 240)
                Text(progressText(plan))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white)
            }
            if let pose = capture.currentPose {
                Text(String(format: "yaw %.0f°  pitch %.0f°  roll %.0f°", pose.yawDegrees, pose.pitchDegrees, pose.rollDegrees()))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            Text(instruction)
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if capture.phase == .preview {
                Picker("Coverage", selection: $planKind) {
                    ForEach(CapturePlanKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                if let count = capture.plannedShotCount(for: planKind) {
                    Text(expectation(shots: count))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            HStack(spacing: 16) {
                Button(role: .cancel, action: onCancel) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                if capture.phase == .preview {
                    Button(action: onStart) {
                        Text("Start")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Roughly 2.5 seconds per shot, from the rooftop captures.
    private func expectation(shots: Int) -> String {
        let seconds = Double(shots) * 2.5
        let time: String
        switch seconds {
        case ..<50: time = "under a minute"
        case ..<75: time = "about a minute"
        case ..<105: time = "about a minute and a half"
        default: time = "about \(Int((seconds / 60).rounded())) minutes"
        }
        switch planKind {
        case .ring: return "\(shots) shots in one slow turn to the right, \(time)."
        case .sphere: return "\(shots) shots in one slow turn to the right, sweeping up and down as you go, \(time)."
        }
    }

    private func progressText(_ plan: CapturePlan) -> String {
        let total = plan.targets.count
        let done = capture.shots.count
        var parts = ["Shot \(min(capture.currentTargetIndex + 1, total)) of \(total)"]
        if plan.yawStepDegrees > 0, capture.currentTargetIndex < total, let start = plan.targets.first {
            let target = plan.targets[capture.currentTargetIndex]
            let column = Int((Angle.wrapDegrees360(target.yawDegrees - start.yawDegrees) / plan.yawStepDegrees).rounded()) + 1
            let columns = Int((360 / plan.yawStepDegrees).rounded())
            if columns > 1 { parts.append("turn \(min(column, columns)) of \(columns)") }
        }
        // Remaining time from the pace so far, once there is a pace to measure.
        if done >= 3, let first = capture.shots.first, let last = capture.shots.last, last.pose.timestamp > first.pose.timestamp {
            let perShot = (last.pose.timestamp - first.pose.timestamp) / Double(done - 1)
            let remaining = perShot * Double(total - done)
            if remaining >= 8 {
                parts.append(remaining >= 90 ? "about \(Int((remaining / 60).rounded())) min left" : "about \(Int((remaining / 10).rounded()) * 10) s left")
            } else if total > done {
                parts.append("nearly there")
            }
        }
        return parts.joined(separator: " · ")
    }

    private var instruction: String {
        switch capture.phase {
        case .preview:
            switch planKind {
            case .ring:
                return "Hold the phone upright. Centre the view you want in front, then tap Start."
            case .sphere:
                return "Centre the view you want in front, then tap Start. Pivot around the phone, not your body."
            }
        case .capturing:
            if capture.isCapturingFrame { return "Hold still" }
            guard let a = capture.alignment else { return "" }
            if a.isAligned, !a.isSteady { return "Hold still" }
            if abs(a.deltaPitchDegrees) > 8, abs(a.deltaPitchDegrees) > abs(a.deltaYawDegrees) {
                return a.deltaPitchDegrees > 0 ? "Tilt up to the next target." : "Tilt down to the next target."
            }
            return "Turn slowly to the right until the circle meets the crosshair."
        default:
            return ""
        }
    }

}

/// The plan as a small map of the sphere: yaw across, from the front at the
/// left edge once around, pitch down, so the capture reads as one sweep
/// from left to right whatever order the targets come in. Done targets are
/// green, the current one yellow, and a line marks the column being worked.
private struct CoverageMap: View {
    let plan: CapturePlan
    let done: Int
    let current: Int

    private let inset: CGFloat = 8

    private var startYaw: Float { plan.targets.first?.yawDegrees ?? 0 }
    private var hasPitch: Bool { plan.targets.contains { $0.pitchDegrees != 0 } }

    private func point(_ t: CaptureTarget, in size: CGSize) -> CGPoint {
        let fx = CGFloat(Angle.wrapDegrees360(t.yawDegrees - startYaw) / 360)
        let fy: CGFloat = hasPitch ? CGFloat((90 - t.pitchDegrees) / 180) : 0.5
        return CGPoint(x: inset + fx * (size.width - 2 * inset),
                       y: inset + fy * (size.height - 2 * inset))
    }

    private func colour(_ t: CaptureTarget) -> Color {
        if t.id < done { return .green }
        if t.id == current { return .yellow }
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
                if current < plan.targets.count {
                    Rectangle()
                        .fill(.yellow.opacity(0.35))
                        .frame(width: 2)
                        .position(x: point(plan.targets[current], in: geo.size).x, y: geo.size.height / 2)
                }
                ForEach(plan.targets) { target in
                    Circle()
                        .fill(colour(target))
                        .frame(width: target.id == current ? 9 : 6, height: target.id == current ? 9 : 6)
                        .position(point(target, in: geo.size))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: current)
    }
}

private struct TargetMarker: View {
    let aligned: Bool
    let ready: Bool
    let farAway: Bool

    var body: some View {
        Circle()
            .strokeBorder(colour, lineWidth: 4)
            .frame(width: farAway ? 36 : 72, height: farAway ? 36 : 72)
            .background(Circle().fill(colour.opacity(ready ? 0.35 : 0.1)))
            .shadow(color: .black.opacity(0.5), radius: 3)
    }

    private var colour: Color {
        if ready { return .green }
        if aligned { return .yellow }
        return .white
    }
}

private struct Crosshair: View {
    var body: some View {
        ZStack {
            Rectangle().frame(width: 28, height: 2)
            Rectangle().frame(width: 2, height: 28)
        }
        .foregroundStyle(.white.opacity(0.9))
        .shadow(color: .black.opacity(0.6), radius: 2)
    }
}
