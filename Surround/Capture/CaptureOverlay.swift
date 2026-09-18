import SwiftUI
import SurroundCore

/// Guidance drawn over the camera preview: the next target, the crosshair,
/// tracking warnings and the ring's progress.
struct CaptureOverlay: View {
    let capture: CaptureSession
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
                HStack(spacing: 4) {
                    ForEach(plan.targets) { target in
                        Circle()
                            .fill(target.id < capture.shots.count ? Color.green : Color.white.opacity(0.35))
                            .frame(width: 8, height: 8)
                    }
                }
                Text("Shot \(min(capture.currentTargetIndex + 1, plan.targets.count)) of \(plan.targets.count)")
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

    private var instruction: String {
        switch capture.phase {
        case .preview:
            return "Hold the phone upright. Centre the view you want in front, then tap Start."
        case .capturing:
            if capture.isCapturingFrame { return "Hold still" }
            if let a = capture.alignment, a.isAligned, !a.isSteady { return "Hold still" }
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
