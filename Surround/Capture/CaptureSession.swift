import ARKit
import AVFoundation
import Foundation
import Observation
import SurroundCore
import UIKit

/// One stored still with its pose.
struct CapturedShot: Identifiable {
    var id: Int { pose.index }
    let fileURL: URL
    let pose: ShotPose
}

/// Owns the ARKit session during capture. ARKit is the only owner of the
/// camera: it provides tracking, the camera preview, high-resolution stills
/// (`captureHighResolutionFrame`) and, through
/// `configurableCaptureDeviceForPrimaryCamera`, the exposure lock.
///
/// Main-actor isolated; ARKit delivers its delegate callbacks on the main
/// queue by default, which the delegate methods assume.
@Observable
final class CaptureSession: NSObject, ARSessionDelegate {
    enum Phase: Equatable {
        case idle
        /// Camera running, waiting for the user to choose the front and tap Start.
        case preview
        /// Walking through the plan's targets.
        case capturing
        /// Every target has a stored shot.
        case finished
    }

    @ObservationIgnored let session = ARSession()

    private(set) var phase: Phase = .idle
    private(set) var plan: CapturePlan?
    private(set) var currentTargetIndex = 0
    private(set) var alignment: AlignmentState?
    private(set) var currentPose: CameraPose?
    private(set) var trackingWarning: String?
    private(set) var shots: [CapturedShot] = []
    private(set) var isCapturingFrame = false
    private(set) var errorMessage: String?
    /// Field of view across the direction of rotation (the sensor's short side in portrait).
    private(set) var yawFieldOfViewDegrees: Float = 50

    /// Called after every phase change, on the main actor.
    @ObservationIgnored var onPhaseChange: ((Phase) -> Void)?
    /// Called when capture fails with a message for the user.
    @ObservationIgnored var onError: ((String) -> Void)?

    @ObservationIgnored var lockExposureAfterFirstShot = true
    @ObservationIgnored var minimumOverlap: Float = 0.4
    @ObservationIgnored var thresholds = AlignmentThresholds() {
        didSet { evaluator.thresholds = thresholds }
    }

    @ObservationIgnored private(set) var frontYawDegrees: Float = 0
    @ObservationIgnored private(set) var startedAt = Date()
    @ObservationIgnored private(set) var highResolutionSupported = false

    @ObservationIgnored private let evaluator = AlignmentEvaluator()
    @ObservationIgnored private var shotsDirectory: URL?
    @ObservationIgnored private let haptics = UIImpactFeedbackGenerator(style: .medium)

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    // MARK: Control

    func startPreview(shotsDirectory: URL) {
        guard Self.isSupported else {
            errorMessage = "This device does not support ARKit world tracking."
            return
        }
        self.shotsDirectory = shotsDirectory
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.isAutoFocusEnabled = true
        config.planeDetection = []
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = format
            highResolutionSupported = true
        }
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        shots = []
        plan = nil
        currentTargetIndex = 0
        alignment = nil
        errorMessage = nil
        evaluator.thresholds = thresholds
        evaluator.reset()
        transition(to: .preview)
    }

    /// Locks the current viewing direction in as the sphere's front and builds the ring plan.
    func beginRing() {
        guard phase == .preview, let frame = session.currentFrame else { return }
        let pose = Self.pose(of: frame.camera)
        let intrinsics = Self.intrinsics(of: frame.camera)
        yawFieldOfViewDegrees = intrinsics.fovAcrossHeightDegrees
        frontYawDegrees = pose.yawDegrees
        startedAt = Date()
        plan = CapturePlan.ring(startYawDegrees: pose.yawDegrees,
                                fovAcrossYawDegrees: yawFieldOfViewDegrees,
                                minimumOverlap: minimumOverlap)
        currentTargetIndex = 0
        evaluator.reset()
        haptics.prepare()
        transition(to: .capturing)
    }

    func stop() {
        session.pause()
        if phase != .finished { transition(to: .idle) }
    }

    private func transition(to newPhase: Phase) {
        guard newPhase != phase else { return }
        phase = newPhase
        onPhaseChange?(newPhase)
    }

    private func fail(_ message: String) {
        errorMessage = message
        onError?(message)
    }

    func manifest() -> CaptureManifest {
        CaptureManifest(startedAt: startedAt,
                        frontYawDegrees: frontYawDegrees,
                        poses: shots.map { $0.pose },
                        planYawStepDegrees: plan?.yawStepDegrees ?? 0)
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        updateTrackingWarning(frame.camera.trackingState)
        let pose = Self.pose(of: frame.camera)
        currentPose = pose
        guard phase == .capturing, let plan, currentTargetIndex < plan.targets.count else { return }
        let target = plan.targets[currentTargetIndex]
        let state = evaluator.evaluate(pose: pose, target: target, timestamp: frame.timestamp)
        alignment = state
        if state.isReadyToCapture, !isCapturingFrame, trackingWarning == nil {
            capture(fallback: frame, target: target)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        fail(error.localizedDescription)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        trackingWarning = "Camera interrupted"
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        trackingWarning = nil
    }

    // MARK: Capture

    private func capture(fallback frame: ARFrame, target: CaptureTarget) {
        isCapturingFrame = true
        evaluator.markCaptured(at: frame.timestamp)
        let index = currentTargetIndex
        guard highResolutionSupported else {
            store(frame: frame, index: index, target: target)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            if let highRes = try? await session.captureHighResolutionFrame() {
                store(frame: highRes, index: index, target: target)
            } else if let current = session.currentFrame {
                store(frame: current, index: index, target: target)
            } else {
                isCapturingFrame = false
            }
        }
    }

    private func store(frame: ARFrame, index: Int, target: CaptureTarget) {
        guard let directory = shotsDirectory else {
            isCapturingFrame = false
            return
        }
        let buffer = frame.capturedImage
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var intrinsics = Self.intrinsics(of: frame.camera)
        if intrinsics.width != width || intrinsics.height != height {
            intrinsics = intrinsics.scaled(toWidth: width, height: height)
        }
        // Exposure values are informational; ARKit can report NaN for them.
        let exposureDuration = frame.camera.exposureDuration.isFinite ? frame.camera.exposureDuration : nil
        let exposureOffset = frame.camera.exposureOffset.isFinite ? frame.camera.exposureOffset : nil
        let pose = ShotPose(index: index,
                            timestamp: frame.timestamp,
                            transformColumnMajor: Self.columnMajor(frame.camera.transform),
                            intrinsics: intrinsics,
                            exposureDurationSeconds: exposureDuration,
                            exposureOffset: exposureOffset,
                            targetYawDegrees: target.yawDegrees,
                            targetPitchDegrees: target.pitchDegrees)
        guard pose.hasFiniteGeometry else {
            // Tracking delivered an unusable pose; leave the target in place so it is retried.
            isCapturingFrame = false
            trackingWarning = "Tracking not ready, hold still"
            return
        }
        let imageURL = directory.appendingPathComponent(pose.imageFileName)
        let poseURL = directory.appendingPathComponent(pose.poseFileName)

        // Encode off the main actor. Only the pixel buffer is retained, not the
        // ARFrame. A delivered CVPixelBuffer is immutable and safe to read from
        // another thread, which the compiler cannot know.
        nonisolated(unsafe) let pixels = buffer
        Task { [weak self] in
            let failure = await Self.encode(pixels, pose: pose, imageURL: imageURL, poseURL: poseURL, index: index)
            self?.finishStoring(CapturedShot(fileURL: imageURL, pose: pose), failure: failure)
        }
    }

    /// Writes the still and its pose file; returns a message on failure.
    @concurrent
    private nonisolated static func encode(_ buffer: CVPixelBuffer, pose: ShotPose, imageURL: URL, poseURL: URL, index: Int) async -> String? {
        guard let data = ImageConversion.jpegData(from: buffer) else {
            return "Could not encode the image for shot \(index + 1)."
        }
        do {
            try data.write(to: imageURL, options: .atomic)
        } catch {
            return "Saving image for shot \(index + 1): \(error.localizedDescription)"
        }
        do {
            try MetadataCoding.encode(pose).write(to: poseURL, options: .atomic)
        } catch {
            return "Saving pose for shot \(index + 1): \(error.localizedDescription)"
        }
        return nil
    }

    private func finishStoring(_ shot: CapturedShot, failure: String?) {
        isCapturingFrame = false
        if let failure {
            fail(failure)
            return
        }
        shots.append(shot)
        haptics.impactOccurred()
        if shots.count == 1, lockExposureAfterFirstShot {
            lockExposure()
        }
        currentTargetIndex += 1
        if let plan, currentTargetIndex >= plan.targets.count {
            session.pause()
            transition(to: .finished)
        }
    }

    private func lockExposure() {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
            device.unlockForConfiguration()
        } catch {
            // Exposure lock is best effort; the capture still works without it.
        }
    }

    private func updateTrackingWarning(_ state: ARCamera.TrackingState) {
        let warning: String?
        switch state {
        case .normal:
            warning = nil
        case .notAvailable:
            warning = "Tracking unavailable"
        case .limited(let reason):
            switch reason {
            case .initializing: warning = "Hold still while tracking starts"
            case .excessiveMotion: warning = "Slow down"
            case .insufficientFeatures: warning = "Tracking is weak here"
            case .relocalizing: warning = "Re-finding position"
            @unknown default: warning = "Tracking limited"
            }
        }
        if warning != trackingWarning {
            trackingWarning = warning
        }
    }

    // MARK: ARKit conversions

    static func columnMajor(_ m: simd_float4x4) -> [Float] {
        let c = m.columns
        return [c.0.x, c.0.y, c.0.z, c.0.w,
                c.1.x, c.1.y, c.1.z, c.1.w,
                c.2.x, c.2.y, c.2.z, c.2.w,
                c.3.x, c.3.y, c.3.z, c.3.w]
    }

    static func pose(of camera: ARCamera) -> CameraPose {
        CameraPose(rotation: Mat3(columnMajor4x4: columnMajor(camera.transform)))
    }

    static func intrinsics(of camera: ARCamera) -> CameraIntrinsics {
        let k = camera.intrinsics
        return CameraIntrinsics(fx: k.columns.0.x,
                                fy: k.columns.1.y,
                                cx: k.columns.2.x,
                                cy: k.columns.2.y,
                                width: Int(camera.imageResolution.width),
                                height: Int(camera.imageResolution.height))
    }
}
