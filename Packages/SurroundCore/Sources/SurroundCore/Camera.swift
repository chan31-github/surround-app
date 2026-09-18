import Foundation

/// Pinhole intrinsics in the pixel coordinates of a specific image size.
///
/// The image is in the camera's native sensor orientation (landscape, as ARKit
/// delivers `capturedImage`), with the origin at the top-left and rows
/// increasing downwards. The camera frame is ARKit's: +X image right, +Y image
/// up, looking along -Z.
public struct CameraIntrinsics: Equatable, Codable {
    public var fx: Float
    public var fy: Float
    public var cx: Float
    public var cy: Float
    public var width: Int
    public var height: Int

    public init(fx: Float, fy: Float, cx: Float, cy: Float, width: Int, height: Int) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
    }

    /// Field of view across the image's width (the long side, horizontal in landscape).
    public var fovAcrossWidthDegrees: Float {
        Angle.degrees(2 * atan(Float(width) / (2 * fx)))
    }

    /// Field of view across the image's height (the short side; this is the
    /// horizontal field of view when the phone is held in portrait).
    public var fovAcrossHeightDegrees: Float {
        Angle.degrees(2 * atan(Float(height) / (2 * fy)))
    }

    /// Largest angle between the optical axis and any image corner, in radians.
    public var cornerHalfAngleRadians: Float {
        let corners: [(Float, Float)] = [(0, 0), (Float(width), 0), (0, Float(height)), (Float(width), Float(height))]
        var best: Float = 0
        for (u, v) in corners {
            let x = (u - cx) / fx
            let y = (v - cy) / fy
            best = max(best, atan((x * x + y * y).squareRoot()))
        }
        return best
    }

    /// Intrinsics for the same camera at a different image size.
    public func scaled(toWidth w: Int, height h: Int) -> CameraIntrinsics {
        let sx = Float(w) / Float(width)
        let sy = Float(h) / Float(height)
        return CameraIntrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy, width: w, height: h)
    }

    /// Projects a camera-frame point to pixel coordinates. Returns nil when the
    /// point is not in front of the camera.
    public func project(_ p: Vec3) -> (u: Float, v: Float)? {
        guard p.z < 0 else { return nil }
        let inv = 1 / -p.z
        return (fx * p.x * inv + cx, -fy * p.y * inv + cy)
    }
}

/// Orientation of the camera in the world: `rotation` maps camera-frame
/// vectors to world-frame vectors (ARKit's `camera.transform` upper-left 3x3).
public struct CameraPose: Equatable {
    public var rotation: Mat3

    public init(rotation: Mat3) {
        self.rotation = rotation
    }

    /// World-frame viewing direction.
    public var forward: Vec3 { -rotation.c2 }

    /// Compass-sense yaw of the viewing direction, in (-180, 180].
    public var yawDegrees: Float {
        let f = forward
        return Angle.degrees(atan2(f.x, -f.z))
    }

    /// Pitch of the viewing direction, positive upwards.
    public var pitchDegrees: Float {
        let f = forward.normalized
        return Angle.degrees(asin(max(-1, min(1, f.y))))
    }

    /// Roll of the phone about the viewing axis, in degrees, positive when the
    /// top of the screen leans to the right. `screenUpInCamera` is the camera-
    /// frame axis that points to the top of the screen; in portrait with ARKit's
    /// landscape camera convention that is -X. Returns 0 when looking straight
    /// up or down, where roll is undefined.
    public func rollDegrees(screenUpInCamera: Vec3 = Vec3(-1, 0, 0)) -> Float {
        let f = forward.normalized
        let right = f.cross(Vec3.up)
        guard right.length > 1e-4 else { return 0 }
        let r = right.normalized
        let upProj = r.cross(f).normalized
        let screenUp = rotation * screenUpInCamera
        return Angle.degrees(atan2(screenUp.dot(r), screenUp.dot(upProj)))
    }

    /// The same pose with `delta` added to its yaw (pitch and roll unchanged).
    public func yawShifted(byDegrees delta: Float) -> CameraPose {
        CameraPose(rotation: Mat3.rotationY(-Angle.radians(delta)) * rotation)
    }
}
