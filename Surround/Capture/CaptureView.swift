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
                ARPreview(session: model.capture.session,
                          shots: model.capture.shots,
                          retakingIndex: model.capture.retakingIndex)
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
                               plan: model.capture.plan,
                               shots: model.shotFiles,
                               canRetake: model.capture.canRetake,
                               driftMetres: model.capture.maxDriftMetres,
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
    let plan: CapturePlan?
    let shots: [(index: Int, url: URL, pitchDegrees: Float)]
    let canRetake: Bool
    let driftMetres: Float?
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
                if let drift = driftMetres, drift > PivotGuide.warningDistance {
                    Text("The phone moved up to \(Int((drift * 100).rounded())) cm during capture, so things within a few metres of you may not line up. Next time keep it over one spot and step around it.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                if canRetake, plan != nil {
                    Button {
                        showRetake = true
                    } label: {
                        Label("Retake a shot", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                HStack(spacing: 16) {
                    Button(role: .destructive, action: onDiscard) {
                        Label("Discard", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    Button(action: onKeep) {
                        Label("Keep", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
        .sheet(isPresented: $showRetake) {
            if let plan {
                RetakePicker(plan: plan, shots: shots) { index in
                    showRetake = false
                    onRetake(index)
                }
                .presentationDetents([.large])
            }
        }
    }
}

/// Picking the shot to retake by where it points, not by a number in a
/// list: the sphere map shows every shot in its place, tapping one previews
/// that still, and the retake starts from there. Retaking works while the
/// capture's tracking session is still alive, which is why it is offered
/// only before the sphere is kept.
private struct RetakePicker: View {
    let plan: CapturePlan
    let shots: [(index: Int, url: URL, pitchDegrees: Float)]
    let onPick: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int?

    private var taken: Set<Int> { Set(shots.map { $0.index }) }
    private var selectedShot: (index: Int, url: URL, pitchDegrees: Float)? {
        shots.first { $0.index == selected }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Tap the shot to take again. The map is the sphere: left to right is one turn from the front, top to bottom is sky to ground.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                SphereDotMap(plan: plan, done: taken, current: nil, selected: selected) { index in
                    if taken.contains(index) { selected = index }
                }
                .frame(height: plan.targets.contains { $0.pitchDegrees != 0 } ? 200 : 90)
                .padding(.horizontal)

                if let shot = selectedShot {
                    ShotStill(url: shot.url)
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                    Text(Self.describe(plan: plan, index: shot.index))
                        .font(.subheadline)
                    Button {
                        onPick(shot.index)
                    } label: {
                        Label("Retake this shot", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal)
                } else {
                    ContentUnavailableView("Pick a shot", systemImage: "hand.tap",
                                           description: Text("Every dot is one of the \(shots.count) shots."))
                }
                Spacer(minLength: 0)
                Text("Stay where you took the sphere. The shot is taken again with the same exposure and replaces the old one, then the sphere is stitched again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding([.horizontal, .bottom])
            }
            .padding(.top)
            .navigationTitle("Retake a shot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// "Shot 7 · 40° right of the front · level", so the picked dot can be
    /// checked against what the phone is about to be pointed at.
    static func describe(plan: CapturePlan, index: Int) -> String {
        guard index < plan.targets.count, let front = plan.targets.first else { return "Shot \(index + 1)" }
        let target = plan.targets[index]
        let yaw = Angle.wrapDegrees180(target.yawDegrees - front.yawDegrees)
        var parts = ["Shot \(index + 1)"]
        switch target.pitchDegrees {
        case 89...: parts.append("straight up")
        case ...(-89): parts.append("straight down")
        default:
            parts.append(abs(yaw) < 1 ? "the front" : String(format: "%.0f° %@ of the front", abs(yaw), yaw > 0 ? "right" : "left"))
            switch target.pitchDegrees {
            case 10...: parts.append("tilted up")
            case ...(-10): parts.append("tilted down")
            default: parts.append("level")
            }
        }
        return parts.joined(separator: " · ")
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
