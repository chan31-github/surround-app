import ImageIO
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
                                   onCancel: {
                                       // Cancelling a retake returns to the review, not the library.
                                       if model.capture.retakingIndex != nil {
                                           model.cancelRetake()
                                       } else {
                                           dismiss()
                                       }
                                   })
                }
            case .stitching(let fraction):
                StitchingView(fraction: fraction, shotCount: model.capture.shots.count)
            case .review:
                if let image = model.reviewImage {
                    ReviewView(image: image,
                               metadata: model.metadata,
                               shots: model.shotFiles,
                               onKeep: {
                                   model.keep(in: context)
                                   dismiss()
                               },
                               onRetake: { model.retake(index: $0) },
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
    let shots: [(index: Int, url: URL, pitchDegrees: Float)]
    let onKeep: () -> Void
    let onRetake: (Int) -> Void
    let onDiscard: () -> Void
    @State private var showRetake = false

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
                    Button {
                        showRetake = true
                    } label: {
                        Label("Retake", systemImage: "arrow.counterclockwise")
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
        .sheet(isPresented: $showRetake) {
            RetakePicker(shots: shots) { index in
                showRetake = false
                onRetake(index)
            }
            .presentationDetents([.large])
        }
    }
}

/// The stills of the capture, so the one with the passer-by in it can be
/// picked out and retaken. Retaking works while you are still standing
/// where you took the sphere; the exposure lock and the tracking frame are
/// kept, so the new shot matches the others.
private struct RetakePicker: View {
    let shots: [(index: Int, url: URL, pitchDegrees: Float)]
    let onPick: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 14) {
                    ForEach(shots, id: \.index) { shot in
                        Button {
                            onPick(shot.index)
                        } label: {
                            VStack(spacing: 4) {
                                ShotStill(url: shot.url)
                                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text("\(shot.index + 1) · \(Self.pitchName(shot.pitchDegrees))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                Text("Stay where you took the sphere. The chosen shot is taken again with the same exposure and replaces the old one, then the sphere is stitched again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.bottom)
            }
            .navigationTitle("Retake which shot?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    static func pitchName(_ pitch: Float) -> String {
        switch pitch {
        case 89...: return "zenith"
        case ...(-89): return "nadir"
        case 10...: return "up"
        case ...(-10): return "down"
        default: return "level"
        }
    }
}

/// A stored still, decoded small and rotated upright: stills are saved in the
/// sensor's landscape orientation, and the phone was held in portrait with
/// the sensor's +X (image right) pointing down the screen.
private struct ShotStill: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.2)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            image = await Self.decode(url)
        }
    }

    @concurrent
    private static func decode(_ url: URL) async -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Sensor landscape to screen portrait: rotate 90 degrees clockwise.
        return UIImage(cgImage: cg, scale: 1, orientation: .right)
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
