import Foundation

/// One direction the user must point the camera at.
public struct CaptureTarget: Equatable, Identifiable, Sendable {
    public let id: Int
    public let yawDegrees: Float
    public let pitchDegrees: Float
    public let direction: Vec3

    public init(id: Int, yawDegrees: Float, pitchDegrees: Float) {
        self.id = id
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
        self.direction = CapturePlan.direction(yawDegrees: yawDegrees, pitchDegrees: pitchDegrees)
    }
}

/// The ordered set of targets for one sphere.
public struct CapturePlan: Equatable, Sendable {
    public let targets: [CaptureTarget]
    public let yawStepDegrees: Float

    public init(targets: [CaptureTarget], yawStepDegrees: Float) {
        self.targets = targets
        self.yawStepDegrees = yawStepDegrees
    }

    /// Unit direction for a yaw and pitch, in the world conventions of `Vec3`.
    public static func direction(yawDegrees: Float, pitchDegrees: Float) -> Vec3 {
        let yaw = Angle.radians(yawDegrees)
        let pitch = Angle.radians(pitchDegrees)
        return Vec3(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
    }

    /// Number of evenly spaced shots needed to cover 360 degrees of yaw with at
    /// least `minimumOverlap` (fraction of the field of view) between neighbours.
    public static func shotsPerRing(fovAcrossYawDegrees: Float, minimumOverlap: Float) -> Int {
        let usable = max(1, fovAcrossYawDegrees * (1 - minimumOverlap))
        return max(3, Int((360 / usable).rounded(.up)))
    }

    /// Milestone 1: a single horizontal ring starting at `startYawDegrees`.
    ///
    /// `fovAcrossYawDegrees` is the camera's field of view across the direction
    /// of rotation. With the phone in portrait that is the field of view across
    /// the sensor's short side.
    public static func ring(startYawDegrees: Float,
                            pitchDegrees: Float = 0,
                            fovAcrossYawDegrees: Float,
                            minimumOverlap: Float = 0.4) -> CapturePlan {
        let count = shotsPerRing(fovAcrossYawDegrees: fovAcrossYawDegrees, minimumOverlap: minimumOverlap)
        let step = 360 / Float(count)
        let targets = (0..<count).map { i in
            CaptureTarget(id: i,
                          yawDegrees: Angle.wrapDegrees180(startYawDegrees + step * Float(i)),
                          pitchDegrees: pitchDegrees)
        }
        return CapturePlan(targets: targets, yawStepDegrees: step)
    }

    /// Milestone 2: a full sphere as a stack of rings plus zenith and nadir.
    /// Rings nearer the poles need fewer shots because the effective field of
    /// view across yaw grows by 1 / cos(pitch).
    public static func sphere(startYawDegrees: Float,
                              fovAcrossYawDegrees: Float,
                              fovAcrossPitchDegrees: Float,
                              minimumOverlap: Float = 0.4) -> CapturePlan {
        let pitchStep = max(10, fovAcrossPitchDegrees * (1 - minimumOverlap))
        var pitches: [Float] = [0]
        var p = pitchStep
        while p + fovAcrossPitchDegrees / 2 < 90 {
            pitches.append(p)
            pitches.append(-p)
            p += pitchStep
        }
        // Order rings from the horizon outwards so the user does the easy ring first.
        pitches.sort { abs($0) == abs($1) ? $0 > $1 : abs($0) < abs($1) }

        var targets: [CaptureTarget] = []
        var horizonStep: Float = 0
        for pitch in pitches {
            let effectiveFOV = min(360, fovAcrossYawDegrees / max(0.2, cos(Angle.radians(pitch))))
            let count = shotsPerRing(fovAcrossYawDegrees: effectiveFOV, minimumOverlap: minimumOverlap)
            let step = 360 / Float(count)
            if pitch == 0 { horizonStep = step }
            for i in 0..<count {
                targets.append(CaptureTarget(id: targets.count,
                                             yawDegrees: Angle.wrapDegrees180(startYawDegrees + step * Float(i)),
                                             pitchDegrees: pitch))
            }
        }
        targets.append(CaptureTarget(id: targets.count, yawDegrees: startYawDegrees, pitchDegrees: 90))
        targets.append(CaptureTarget(id: targets.count, yawDegrees: startYawDegrees, pitchDegrees: -90))
        return CapturePlan(targets: targets, yawStepDegrees: horizonStep)
    }
}
