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
                                 ready: alignment.isReadyToCapture && !capture.pivotHoldsCapture,
                                 farAway: distance > maxRadius,
                                 waiting: capture.pivotHoldsCapture)
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
            if capture.phase == .capturing, !capture.pivotIsHeld, let pivot = capture.pivot,
               pivot.distance > PivotGuide.warningDistance,
               let instruction = PivotGuide.instruction(for: pivot, pitchDegrees: capture.currentPose?.pitchDegrees ?? 0) {
                PivotBanner(instruction: instruction, distance: pivot.distance, holding: capture.pivotHoldsCapture)
            }
            if let plan = capture.plan {
                HStack(alignment: .center, spacing: 10) {
                SphereDotMap(plan: plan, done: Set(capture.shots.map { $0.pose.index }),
                             current: capture.currentTargetIndex)
                    .frame(width: 240, height: plan.targets.contains { $0.pitchDegrees != 0 } ? 72 : 28)
                    if capture.phase == .capturing {
                        PivotGauge(offset: capture.pivot, isHeld: capture.pivotIsHeld)
                            .frame(width: 60, height: 72)
                    }
                }
                ProgressView(value: Double(capture.shots.count), total: Double(plan.targets.count))
                    .progressViewStyle(.linear)
                    .tint(.green)
                    .frame(width: 240)
                Text(progressText(plan))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white)
                if capture.phase == .capturing, (1...4).contains(capture.shots.count), capture.retakingIndex == nil {
                    Text("Hold a finger on the screen to see the camera alone")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
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
                } else if capture.phase == .capturing, capture.holdIsLong {
                    // The wait is a guide, not a rule: after a few seconds the
                    // user can take the shot where they are.
                    Button {
                        capture.captureNow()
                    } label: {
                        Label("Take it anyway", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
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
                return "Hold the phone upright. Centre the view you want in front, then tap Start. Hold the phone still in the air and walk round it, as if it were on a tripod."
            case .sphere:
                return "Centre the view you want in front, then tap Start. Hold the phone still in the air and walk round it, as if it were on a tripod."
            }
        case .capturing:
            if capture.isCapturingFrame { return "Hold still" }
            if capture.pivotHoldsCapture { return "Move back over the start spot to take this shot. The small gauge shows where it is." }
            guard let a = capture.alignment else { return "" }
            if a.isAligned, !a.isSteady { return "Hold still" }
            if abs(a.deltaPitchDegrees) > 8, abs(a.deltaPitchDegrees) > abs(a.deltaYawDegrees) {
                return a.deltaPitchDegrees > 0 ? "Tilt up to the next target." : "Tilt down to the next target."
            }
            return "Walk slowly round the phone to the right until the circle meets the crosshair."
        default:
            return ""
        }
    }

}

/// The pivot gauge, drawn like the aiming target: the crosshair in the
/// middle is the phone, the ring is the spot the capture started from, seen
/// from above with straight ahead at the top. Move so the crosshair sits in
/// the ring, just as the aiming circle is brought onto the crosshair. The
/// ring has the comfortable 10 cm radius; it turns yellow beyond that and
/// red past 25 cm, when shots wait.
struct PivotGauge: View {
    let offset: PivotOffset?
    /// Pointing at sky or ground, where position cannot be tracked: the last
    /// good reading is shown faded until the phone comes back to the horizon.
    var isHeld = false
    /// Metres from the centre to the gauge's edge.
    private let range: Float = 0.4

    private var colour: Color {
        guard let d = offset?.distance else { return .white }
        if d <= PivotGuide.comfortableDistance { return .green }
        if d <= PivotGuide.warningDistance { return .yellow }
        return .red
    }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let radius = min(geo.size.width, geo.size.height) / 2
                let scale = radius / CGFloat(range)
                let centre = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let ring = CGFloat(PivotGuide.comfortableDistance) * scale * 2
                ZStack {
                    Circle().fill(.black.opacity(0.35))
                    if let o = offset {
                        // Where the start spot is from here: the opposite of the drift.
                        let dx = CGFloat(max(-range, min(range, -o.right))) * scale
                        let dy = CGFloat(max(-range, min(range, o.forward))) * scale
                        Circle()
                            .fill(colour.opacity(isHeld ? 0.12 : 0.3))
                            .overlay(Circle().strokeBorder(colour.opacity(isHeld ? 0.4 : 1), lineWidth: 2))
                            .frame(width: ring, height: ring)
                            .position(x: centre.x + dx, y: centre.y + dy)
                    }
                    // The phone.
                    Rectangle().fill(.white).frame(width: 12, height: 1.5).position(centre)
                    Rectangle().fill(.white).frame(width: 1.5, height: 12).position(centre)
                }
                .clipShape(Circle())
            }
            .aspectRatio(1, contentMode: .fit)
            Text(isHeld ? "holding" : offset.map { "\(Int(($0.distance * 100).rounded())) cm" } ?? "pivot")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isHeld ? .white.opacity(0.6) : colour)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Start spot")
        .accessibilityValue(offset.flatMap { PivotGuide.instruction(for: $0)?.text } ?? "On the spot")
    }
}

/// What to do about the drift, in words and an arrow: which way to step,
/// how far, a habit to change when there is one, and whether the shot is
/// waiting. The arrow points the way to step, with straight ahead up.
struct PivotBanner: View {
    let instruction: PivotInstruction
    let distance: Float
    let holding: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up")
                .font(.title.weight(.bold))
                .rotationEffect(.degrees(Double(instruction.arrowDegrees)))
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(instruction.text)
                    .font(.headline)
                if let tip = instruction.tip {
                    Text(tip)
                        .font(.footnote.weight(.semibold))
                }
                Text("\(Int((distance * 100).rounded())) cm from the start" + (holding ? " · the shot waits until you're back" : ""))
                    .font(.footnote)
                    .opacity(0.9)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.red.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
/// A gallery of pivot states for checking the gauge and banner in the
/// simulator, which has no camera. Launch with -pivotGallery.
struct PivotGallery: View {
    private static func offset(_ right: Float, _ forward: Float) -> PivotOffset {
        PivotOffset(distance: (right * right + forward * forward).squareRoot(), right: right, forward: forward, up: 0)
    }

    private let cases: [(String, PivotOffset, Float, Bool)] = [
        ("On the spot", offset(0.03, 0.02), 0, false),
        ("Drifted right 18 cm", offset(0.18, 0), 0, false),
        ("Ahead and right, waiting", offset(0.2, 0.25), 0, true),
        ("Tilted down, leaning forward", offset(0.02, 0.32), -40, true),
        ("Behind and left", offset(-0.22, -0.2), 0, true),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(cases.indices, id: \.self) { i in
                    let c = cases[i]
                    VStack(alignment: .leading, spacing: 6) {
                        Text(c.0).font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 12) {
                            PivotGauge(offset: c.1).frame(width: 60, height: 72)
                            if c.1.distance > PivotGuide.warningDistance,
                               let instruction = PivotGuide.instruction(for: c.1, pitchDegrees: c.2) {
                                PivotBanner(instruction: instruction, distance: c.1.distance, holding: c.3)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(white: 0.25))
        .preferredColorScheme(.dark)
    }
}
#endif

private struct TargetMarker: View {
    let aligned: Bool
    let ready: Bool
    let farAway: Bool
    /// Aimed, but the shot is waiting for the phone to come back over the start.
    var waiting = false

    var body: some View {
        Circle()
            .strokeBorder(colour, lineWidth: 4)
            .frame(width: farAway ? 36 : 72, height: farAway ? 36 : 72)
            .background(Circle().fill(colour.opacity(ready ? 0.35 : 0.1)))
            .shadow(color: .black.opacity(0.5), radius: 3)
    }

    private var colour: Color {
        if waiting { return .gray }
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
