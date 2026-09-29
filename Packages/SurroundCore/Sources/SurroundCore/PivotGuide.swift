import Foundation

/// How far the camera has moved from where a capture started, which is what
/// parallax comes from: a rotation-only stitch assumes every shot is taken
/// from one point. Turning on the spot with the phone held in front of you
/// swings the lens around a circle about 25 cm in radius, half a metre
/// across, and anything within a few metres then fails to line up.
public struct PivotOffset: Equatable, Sendable {
    /// Metres the camera has moved from the start, in any direction.
    public var distance: Float
    /// The horizontal movement seen from above, relative to the way the user
    /// faces: metres to the right and forward.
    public var right: Float
    public var forward: Float
    /// Vertical movement in metres, positive up.
    public var up: Float
}

public enum PivotGuide {
    /// Within this the stitch is unaffected for anything but the ground.
    public static let comfortableDistance: Float = 0.10
    /// Beyond this, objects a few metres away visibly split at the seams.
    public static let warningDistance: Float = 0.25

    /// Offset of `position` from `start`, with the horizontal part expressed
    /// against `heading`, the horizontal direction the user faces.
    public static func offset(start: Vec3, position: Vec3, heading: Vec3) -> PivotOffset {
        let d = position - start
        var f = Vec3(heading.x, 0, heading.z)
        f = f.length > 1e-4 ? f.normalized : Vec3.forward
        // Compass sense: at yaw 0 forward is -Z and right is +X.
        let r = Vec3(-f.z, 0, f.x)
        return PivotOffset(distance: d.length, right: d.dot(r), forward: d.dot(f), up: d.y)
    }

    /// The horizontal direction a camera faces, or nil when it looks nearly
    /// straight up or down and has no useful heading.
    public static func heading(of rotation: Mat3) -> Vec3? {
        let f = -rotation.c2
        let horizontal = Vec3(f.x, 0, f.z)
        return horizontal.length > 0.3 ? horizontal.normalized : nil
    }

    /// Largest distance of any position from `start`.
    public static func maxDrift(from start: Vec3, positions: [Vec3]) -> Float {
        positions.map { ($0 - start).length }.max() ?? 0
    }

    /// Steeper than this the camera sees mostly sky or ground, and ARKit's
    /// position estimate, which comes from tracking visual features, can
    /// wander: on the owner's hilltop sphere it read 0.97 m at the zenith and
    /// 1.8 m on the next shot, then came back, while rotation was unaffected.
    public static let steepPitchDegrees: Float = 55
    /// Someone standing on one spot cannot move the phone this far from it,
    /// so a reading beyond it is a tracking error, not drift.
    public static let implausibleDistance: Float = 0.9

    /// Whether a position reading can be trusted for the pivot gauge.
    public static func isReliable(distance: Float, pitchDegrees: Float) -> Bool {
        abs(pitchDegrees) < steepPitchDegrees && distance < implausibleDistance
    }

    /// Largest drift over the shots whose position can be trusted, or nil
    /// when none can.
    public static func maxReliableDrift(from start: Vec3, shots: [(position: Vec3, pitchDegrees: Float)]) -> Float? {
        shots.map { (distance: ($0.position - start).length, pitch: $0.pitchDegrees) }
            .filter { isReliable(distance: $0.distance, pitchDegrees: $0.pitch) }
            .map { $0.distance }
            .max()
    }
}

extension ShotPose {
    /// Where the camera was, in the capture's world frame.
    public var position: Vec3 {
        Vec3(transformColumnMajor[12], transformColumnMajor[13], transformColumnMajor[14])
    }
}
