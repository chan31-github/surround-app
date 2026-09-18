import SwiftData
import SwiftUI
import SurroundCore
import UIKit

struct CaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var model = CaptureViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.stage {
            case .preview, .capturing:
                ARPreview(session: model.capture.session)
                    .ignoresSafeArea()
                CaptureOverlay(capture: model.capture,
                               onStart: { model.beginRing() },
                               onCancel: { dismiss() })
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
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
        .onDisappear { model.teardown() }
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
            SphereViewerView(image: image)
                .ignoresSafeArea()
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
