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
                if capture.phase == .capturing, let alignment = capture.alignment,
                   let pose = capture.currentPose, let target = currentTarget {
                    let pointsPerDegree = geo.size.width / CGFloat(max(20, capture.yawFieldOfViewDegrees))
                    let offset = Self.screenAngles(pose: pose, target: target)
                    let dx = CGFloat(offset.right) * pointsPerDegree
                    let dy = CGFloat(-offset.up) * pointsPerDegree
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
                SphereDotMap(plan: plan, done: Set(capture.shots.map { $0.pose.index }),
                             current: capture.currentTargetIndex)
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
            HStack(spacing: 12) {
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
                } else if capture.phase == .capturing, capture.retakingIndex != nil {
                    Button {
                        capture.captureNow()
                    } label: {
                        Label("Take it now", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(capture.isCapturingFrame)
                } else if capture.phase == .capturing {
                    Button {
                        capture.retakeLast()
                    } label: {
                        Label("Retake last", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(capture.shots.isEmpty || capture.isCapturingFrame)
                    if capture.canFinishEarly {
                        Button {
                            capture.finishEarly()
                        } label: {
                            Label("Finish", systemImage: "checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
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

    private var currentTarget: CaptureTarget? {
        guard let plan = capture.plan, capture.currentTargetIndex < plan.targets.count else { return nil }
        return plan.targets[capture.currentTargetIndex]
    }

    /// Where the target sits on screen, as angles right of and above the
    /// centre of the view. Projecting the direction into the camera's own
    /// frame keeps this right when the phone is rolled and near the poles,
    /// where a yaw difference means nothing. Screen right is the camera's
    /// +Y and screen up its -X, the portrait convention the roll readout
    /// uses (see CameraPose.rollDegrees).
    static func screenAngles(pose: CameraPose, target: CaptureTarget) -> (right: Float, up: Float) {
        let c = pose.rotation.transposed * target.direction
        let depth = max(0.0001, -c.z)
        return (Angle.degrees(atan2(c.y, depth)), Angle.degrees(atan2(-c.x, depth)))
    }

    private func progressText(_ plan: CapturePlan) -> String {
        let total = plan.targets.count
        if let retaking = capture.retakingIndex {
            return "Retaking shot \(retaking + 1) of \(total) · stand where you took it"
        }
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
