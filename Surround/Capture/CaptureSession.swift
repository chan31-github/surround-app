import ARKit
import AVFoundation
import Combine
import Foundation
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
/// All state is read and written on the main thread; ARKit delivers delegate
/// callbacks there by default.
final class CaptureSession: NSObject, ObservableObject, ARSessionDelegate {
    enum Phase: Equatable {
        case idle
        /// Camera running, waiting for the user to choose the front and tap Start.
        case preview
        /// Walking through the plan's targets.
        case capturing
        /// Every target has a stored shot.
        case finished
    }

    let session = ARSession()

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var plan: CapturePlan?
    @Published private(set) var currentTargetIndex = 0
    @Published private(set) var alignment: AlignmentState?
    @Published private(set) var currentPose: CameraPose?
    @Published private(set) var trackingWarning: String?
    @Published private(set) var shots: [CapturedShot] = []
    @Published private(set) var isCapturingFrame = false
    @Published private(set) var errorMessage: String?
    /// Field of view across the direction of rotation (the sensor's short side in portrait).
    @Published private(set) var yawFieldOfViewDegrees: Float = 50

    var lockExposureAfterFirstShot = true
    var minimumOverlap: Float = 0.4
    var thresholds = AlignmentThresholds() {
        didSet { evaluator.thresholds = thresholds }
    }

    private(set) var frontYawDegrees: Float = 0
    private(set) var startedAt = Date()
    private(set) var highResolutionSupported = false

    private let evaluator = AlignmentEvaluator()
    private var shotsDirectory: URL?
    private let encodingQueue = DispatchQueue(label: "surround.capture.encoding", qos: .userInitiated)
    private let haptics = UIImpactFeedbackGenerator(style: .medium)

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
        phase = .preview
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
        phase = .capturing
    }

    func stop() {
        session.pause()
        if phase != .finished { phase = .idle }
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
        errorMessage = error.localizedDescription
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
        session.captureHighResolutionFrame { [weak self] highRes, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let highRes {
                    self.store(frame: highRes, index: index, target: target)
                } else if let current = self.session.currentFrame {
                    self.store(frame: current, index: index, target: target)
                } else {
                    self.isCapturingFrame = false
                }
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

        // Encode off the main thread. Only the pixel buffer is retained, not the ARFrame.
        encodingQueue.async { [weak self] in
            var failure: String?
            if let data = ImageConversion.jpegData(from: buffer) {
                do {
                    try data.write(to: imageURL, options: .atomic)
                } catch {
                    failure = "Saving image for shot \(index + 1): \(error.localizedDescription)"
                }
                if failure == nil {
                    do {
                        let json = try MetadataCoding.encode(pose)
                        try json.write(to: poseURL, options: .atomic)
                    } catch {
                        failure = "Saving pose for shot \(index + 1): \(error.localizedDescription)"
                    }
                }
            } else {
                failure = "Could not encode the image for shot \(index + 1)."
            }
            DispatchQueue.main.async {
                self?.finishStoring(CapturedShot(fileURL: imageURL, pose: pose), failure: failure)
            }
        }
    }

    private func finishStoring(_ shot: CapturedShot, failure: String?) {
        isCapturingFrame = false
        if let failure {
            errorMessage = failure
            return
        }
        shots.append(shot)
        haptics.impactOccurred()
        if shots.count == 1, lockExposureAfterFirstShot {
            lockExposure()
        }
        currentTargetIndex += 1
        if let plan, currentTargetIndex >= plan.targets.count {
            phase = .finished
            session.pause()
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
