import Foundation

/// Projects world directions into one shot's pixel grid. The stitcher and the
/// alignment analysis share it so every stage uses the same camera model.
struct ShotProjector {
    let worldFromCamera: Mat3
    let cameraFromWorld: Mat3
    let forward: Vec3
    /// Cosine of the largest angle a visible direction can make with `forward`.
    let cosRadius: Float
    let fx: Float, fy: Float, cx: Float, cy: Float
    let width: Int, height: Int
    let maxU: Float, maxV: Float

    init(intrinsics: CameraIntrinsics, rotation: Mat3, width: Int, height: Int) {
        worldFromCamera = rotation
        cameraFromWorld = rotation.transposed
        forward = (-rotation.c2).normalized
        cosRadius = cos(intrinsics.cornerHalfAngleRadians + Angle.radians(1))
        fx = intrinsics.fx
        fy = intrinsics.fy
        cx = intrinsics.cx
        cy = intrinsics.cy
        self.width = width
        self.height = height
        maxU = Float(width - 1) - 0.001
        maxV = Float(height - 1) - 0.001
    }

    init(shot: StitchShot, rotation: Mat3? = nil) {
        self.init(intrinsics: shot.intrinsics,
                  rotation: rotation ?? shot.rotation,
                  width: shot.image.width,
                  height: shot.image.height)
    }

    /// Compass yaw of the optical axis, in (-180, 180].
    var centreYawDegrees: Float { Angle.degrees(atan2(forward.x, -forward.z)) }

    var centrePitchDegrees: Float { Angle.degrees(asin(max(-1, min(1, forward.y)))) }

    /// Pixel coordinates of a world direction, or nil when it falls outside the image.
    @inline(__always)
    func project(_ d: Vec3) -> (u: Float, v: Float)? {
        if d.dot(forward) < cosRadius { return nil }
        let c = cameraFromWorld * d
        if c.z >= 0 { return nil }
        let inv = 1 / -c.z
        let u = fx * c.x * inv + cx
        let v = -fy * c.y * inv + cy
        if u < 0 || v < 0 || u > maxU || v > maxV { return nil }
        return (u, v)
    }

    /// Unit world direction through a pixel.
    func direction(u: Float, v: Float) -> Vec3 {
        let x = (u - cx) / fx
        let y = -(v - cy) / fy
        return (worldFromCamera * Vec3(x, y, -1)).normalized
    }

    /// Yaw span of the image relative to its centre yaw, and its absolute pitch
    /// span, found by walking the image border. Meaningless for shots that
    /// contain a pole.
    func angularBounds() -> AngularBounds {
        let centreYaw = centreYawDegrees
        var b = AngularBounds(yawMinRelDegrees: 0, yawMaxRelDegrees: 0,
                              pitchMinDegrees: centrePitchDegrees, pitchMaxDegrees: centrePitchDegrees)
        let steps = 32
        let w = Float(width)
        let h = Float(height)
        for k in 0...steps {
            let t = Float(k) / Float(steps)
            for (u, v) in [(t * w, 0), (t * w, h), (0, t * h), (w, t * h)] {
                let d = direction(u: u, v: v)
                let yaw = Angle.wrapDegrees180(Angle.degrees(atan2(d.x, -d.z)) - centreYaw)
                let pitch = Angle.degrees(asin(max(-1, min(1, d.y))))
                b.yawMinRelDegrees = min(b.yawMinRelDegrees, yaw)
                b.yawMaxRelDegrees = max(b.yawMaxRelDegrees, yaw)
                b.pitchMinDegrees = min(b.pitchMinDegrees, pitch)
                b.pitchMaxDegrees = max(b.pitchMaxDegrees, pitch)
            }
        }
        return b
    }
}

struct AngularBounds: Equatable {
    var yawMinRelDegrees: Float
    var yawMaxRelDegrees: Float
    var pitchMinDegrees: Float
    var pitchMaxDegrees: Float
}

enum PixelSampling {
    /// Bilinear RGB sample of an RGBA8 buffer at continuous pixel coordinates,
    /// which must lie inside the image.
    @inline(__always)
    static func bilinearRGB(_ px: UnsafePointer<UInt8>, width: Int, height: Int, u: Float, v: Float) -> (r: Float, g: Float, b: Float) {
        let x0 = Int(u)
        let y0 = Int(v)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let tx = u - Float(x0)
        let ty = v - Float(y0)
        let stride = width * 4
        let i00 = y0 * stride + x0 * 4
        let i10 = y0 * stride + x1 * 4
        let i01 = y1 * stride + x0 * 4
        let i11 = y1 * stride + x1 * 4
        let w00 = (1 - tx) * (1 - ty)
        let w10 = tx * (1 - ty)
        let w01 = (1 - tx) * ty
        let w11 = tx * ty
        let r = Float(px[i00]) * w00 + Float(px[i10]) * w10 + Float(px[i01]) * w01 + Float(px[i11]) * w11
        let g = Float(px[i00 + 1]) * w00 + Float(px[i10 + 1]) * w10 + Float(px[i01 + 1]) * w01 + Float(px[i11 + 1]) * w11
        let b = Float(px[i00 + 2]) * w00 + Float(px[i10 + 2]) * w10 + Float(px[i01 + 2]) * w01 + Float(px[i11 + 2]) * w11
        return (r, g, b)
    }

    /// Luma in 0...1 from an 8-bit RGB sample.
    @inline(__always)
    static func luma(_ s: (r: Float, g: Float, b: Float)) -> Float {
        (0.299 * s.r + 0.587 * s.g + 0.114 * s.b) / 255
    }
}
