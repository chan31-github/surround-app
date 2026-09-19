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
    ///
    /// The order is a serpentine so the user turns around once instead of
    /// once per ring: every target is assigned to the nearest horizon column,
    /// and consecutive columns are walked top-down then bottom-up. The first
    /// shot is the horizon front, because it locks exposure (F7) and the sky
    /// would be the wrong reference; the first column then goes down to the
    /// nadir, back up to the zenith, and the serpentine continues from the top.
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

        struct Planned {
            let yaw: Float
            let pitch: Float
        }
        var horizonStep: Float = 0
        var horizonCount = 0
        var ringShots: [Planned] = []
        for pitch in pitches {
            let effectiveFOV = min(360, fovAcrossYawDegrees / max(0.2, cos(Angle.radians(pitch))))
            let count = shotsPerRing(fovAcrossYawDegrees: effectiveFOV, minimumOverlap: minimumOverlap)
            let step = 360 / Float(count)
            if pitch == 0 {
                horizonStep = step
                horizonCount = count
            }
            for i in 0..<count {
                ringShots.append(Planned(yaw: Angle.wrapDegrees180(startYawDegrees + step * Float(i)), pitch: pitch))
            }
        }

        // Nearest horizon column for every ring shot.
        var columns = [[Planned]](repeating: [], count: max(1, horizonCount))
        for shot in ringShots {
            let offset = Angle.wrapDegrees360(shot.yaw - startYawDegrees)
            let column = Int((offset / horizonStep).rounded()) % max(1, horizonCount)
            columns[column].append(shot)
        }

        var ordered: [Planned] = []
        for (k, column) in columns.enumerated() {
            let byPitchDescending = column.sorted { $0.pitch > $1.pitch }
            if k == 0 {
                // Front first, then down to the nadir, then up to the zenith.
                let below = byPitchDescending.filter { $0.pitch < 0 }
                let above = byPitchDescending.filter { $0.pitch > 0 }.reversed()
                ordered.append(contentsOf: byPitchDescending.filter { $0.pitch == 0 })
                ordered.append(contentsOf: below)
                ordered.append(Planned(yaw: startYawDegrees, pitch: -90))
                ordered.append(contentsOf: above)
                ordered.append(Planned(yaw: startYawDegrees, pitch: 90))
            } else if k % 2 == 1 {
                ordered.append(contentsOf: byPitchDescending)
            } else {
                ordered.append(contentsOf: byPitchDescending.reversed())
            }
        }

        let targets = ordered.enumerated().map { index, shot in
            CaptureTarget(id: index, yawDegrees: Angle.wrapDegrees180(shot.yaw), pitchDegrees: shot.pitch)
        }
        return CapturePlan(targets: targets, yawStepDegrees: horizonStep)
    }
}
