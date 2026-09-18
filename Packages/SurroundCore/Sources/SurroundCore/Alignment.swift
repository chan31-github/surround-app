import Foundation

public struct AlignmentThresholds: Equatable {
    /// Maximum angle between the viewing direction and the target.
    public var angleToleranceDegrees: Float = 3
    /// Maximum absolute roll. Nil disables the roll check (the stitcher does not
    /// need level shots; this only keeps overlap consistent).
    public var rollToleranceDegrees: Float? = nil
    /// Maximum rotation speed for the phone to count as steady.
    public var maxAngularSpeedDegreesPerSecond: Float = 12
    /// How long the phone must stay aligned and steady before a shot is taken.
    public var settleSeconds: TimeInterval = 0.25
    /// Minimum time between two shots.
    public var minimumIntervalBetweenCaptures: TimeInterval = 0.8

    public init() {}
}

public struct AlignmentState: Equatable {
    /// Target yaw minus current yaw, wrapped to (-180, 180]. Positive means turn right.
    public var deltaYawDegrees: Float
    /// Target pitch minus current pitch. Positive means tilt up.
    public var deltaPitchDegrees: Float
    public var angularErrorDegrees: Float
    public var rollDegrees: Float
    public var angularSpeedDegreesPerSecond: Float
    public var isAligned: Bool
    public var isSteady: Bool
    public var isReadyToCapture: Bool
}

/// Tracks pose over time and decides when the phone is aligned and steady
/// enough to take the next shot. Not thread-safe: call from one thread.
public final class AlignmentEvaluator {
    public var thresholds: AlignmentThresholds

    private var lastForward: Vec3?
    private var lastTimestamp: TimeInterval?
    private var alignedSince: TimeInterval?
    private var lastCaptureTimestamp: TimeInterval?

    public init(thresholds: AlignmentThresholds = AlignmentThresholds()) {
        self.thresholds = thresholds
    }

    public func reset() {
        lastForward = nil
        lastTimestamp = nil
        alignedSince = nil
        lastCaptureTimestamp = nil
    }

    /// Call after a shot was taken so the settle timer restarts.
    public func markCaptured(at timestamp: TimeInterval) {
        lastCaptureTimestamp = timestamp
        alignedSince = nil
    }

    public func evaluate(pose: CameraPose, target: CaptureTarget, timestamp: TimeInterval) -> AlignmentState {
        let forward = pose.forward.normalized
        let error = Angle.degrees(forward.angle(to: target.direction))
        let roll = pose.rollDegrees()

        var speed: Float = 0
        if let lf = lastForward, let lt = lastTimestamp, timestamp > lt {
            speed = Angle.degrees(forward.angle(to: lf)) / Float(timestamp - lt)
        }
        lastForward = forward
        lastTimestamp = timestamp

        let rollOK = thresholds.rollToleranceDegrees.map { abs(roll) <= $0 } ?? true
        let aligned = error <= thresholds.angleToleranceDegrees && rollOK
        let steady = speed <= thresholds.maxAngularSpeedDegreesPerSecond

        var ready = false
        if aligned && steady {
            if alignedSince == nil { alignedSince = timestamp }
            let settled = timestamp - (alignedSince ?? timestamp) >= thresholds.settleSeconds
            let spaced = lastCaptureTimestamp.map { timestamp - $0 >= thresholds.minimumIntervalBetweenCaptures } ?? true
            ready = settled && spaced
        } else {
            alignedSince = nil
        }

        return AlignmentState(
            deltaYawDegrees: Angle.wrapDegrees180(target.yawDegrees - pose.yawDegrees),
            deltaPitchDegrees: target.pitchDegrees - pose.pitchDegrees,
            angularErrorDegrees: error,
            rollDegrees: roll,
            angularSpeedDegreesPerSecond: speed,
            isAligned: aligned,
            isSteady: steady,
            isReadyToCapture: ready
        )
    }
}
