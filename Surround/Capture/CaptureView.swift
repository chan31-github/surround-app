import SwiftData
import SwiftUI
import SurroundCore
import UIKit

struct CaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var model = CaptureViewModel()
    @AppStorage("capture.planKind") private var planKindRaw = CapturePlanKind.ring.rawValue

    private var planKind: Binding<CapturePlanKind> {
        Binding(get: { CapturePlanKind(rawValue: planKindRaw) ?? .ring }, set: { planKindRaw = $0.rawValue })
    }

    var body: some View {
        GeometryReader { geo in
            captureBody(isLandscape: geo.size.width > geo.size.height)
        }
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
        .onDisappear { model.teardown() }
    }

    /// Capture is portrait only on every device (spec 6.7): the yaw field of
    /// view and the screen-up axis both assume it. In landscape the preview
    /// stays live behind a prompt to turn the phone.
    @ViewBuilder
    private func captureBody(isLandscape: Bool) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.stage {
            case .preview, .capturing:
                ARPreview(session: model.capture.session)
                    .ignoresSafeArea()
                if isLandscape {
                    RotatePrompt(onCancel: { dismiss() })
                } else {
                    CaptureOverlay(capture: model.capture,
                                   planKind: planKind,
                                   onStart: { model.beginCapture(kind: planKind.wrappedValue) },
                                   onCancel: { dismiss() })
                }
            case .stitching(let fraction):
                StitchingView(fraction: fraction, shotCount: model.capture.shots.count)
            case .review:
                if let image = model.reviewImage {
                    ReviewView(image: image,
                               metadata: model.metadata,
                               onKeep: {
                                   model.keep(in: context)
                                   dismiss()
                               },
                               onDiscard: { dismiss() })
                }
            case .failed(let message):
                FailedView(message: message, onClose: { dismiss() })
            }
        }
    }
}

private struct RotatePrompt: View {
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.portrait.rotate")
                .font(.system(size: 44))
            Text("Turn the phone upright to capture")
                .font(.headline)
            Text("Spheres are captured in portrait so each shot covers the most height.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }
}

private struct StitchingView: View {
    let fraction: Float
    let shotCount: Int

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(fraction))
                .progressViewStyle(.linear)
                .frame(maxWidth: 240)
            Text("Stitching \(shotCount) shots")
                .font(.headline)
            Text("Stay here in case a shot needs retaking.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct ReviewView: View {
    let image: UIImage
    let metadata: SphereMetadata?
    let onKeep: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            SphereViewer(image: image, frontHeadingDegrees: metadata?.frontHeadingDegrees)
            VStack(spacing: 12) {
                if let metadata, let lo = metadata.coveredPitchMinDegrees, let hi = metadata.coveredPitchMaxDegrees {
                    Text(String(format: "Covered %.0f° below to %.0f° above the horizon", -lo, hi))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The ring did not fully close; expect a gap.")
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                }
                HStack(spacing: 16) {
                    Button(role: .destructive, action: onDiscard) {
                        Label("Discard", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button(action: onKeep) {
                        Label("Keep", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
    }
}

private struct FailedView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text("Capture failed")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Close", action: onClose)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
