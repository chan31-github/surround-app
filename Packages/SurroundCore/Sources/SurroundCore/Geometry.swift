import Foundation

/// Small, dependency-free 3D maths so the core package builds and tests anywhere.
///
/// Conventions used throughout Surround:
/// - World frame is right-handed with +Y up.
/// - "Forward" at yaw 0 is -Z. Yaw increases clockwise when seen from above
///   (compass sense), so +X is yaw +90 degrees.
/// - Pitch is positive upwards.
public struct Vec3: Equatable, Codable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(_ x: Float, _ y: Float, _ z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)
    public static let up = Vec3(0, 1, 0)
    public static let forward = Vec3(0, 0, -1)

    public func dot(_ o: Vec3) -> Float { x * o.x + y * o.y + z * o.z }

    public func cross(_ o: Vec3) -> Vec3 {
        Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }

    public var length: Float { (x * x + y * y + z * z).squareRoot() }

    public var normalized: Vec3 {
        let l = length
        return l > 0 ? Vec3(x / l, y / l, z / l) : self
    }

    /// Angle in radians between two vectors (not required to be unit length).
    public func angle(to o: Vec3) -> Float {
        let denom = length * o.length
        guard denom > 0 else { return 0 }
        let c = max(-1, min(1, dot(o) / denom))
        return acos(c)
    }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Float) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }
}

/// Column-major 3x3 matrix.
public struct Mat3: Equatable {
    public var c0: Vec3
    public var c1: Vec3
    public var c2: Vec3

    public init(columns c0: Vec3, _ c1: Vec3, _ c2: Vec3) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
    }

    /// Upper-left 3x3 of a column-major 4x4 (16 floats), as ARKit's `simd_float4x4` lays it out.
    public init(columnMajor4x4 m: [Float]) {
        precondition(m.count == 16, "expected 16 floats")
        c0 = Vec3(m[0], m[1], m[2])
        c1 = Vec3(m[4], m[5], m[6])
        c2 = Vec3(m[8], m[9], m[10])
    }

    public static let identity = Mat3(columns: Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1))

    /// Right-handed rotation about +X.
    public static func rotationX(_ r: Float) -> Mat3 {
        let c = cos(r), s = sin(r)
        return Mat3(columns: Vec3(1, 0, 0), Vec3(0, c, s), Vec3(0, -s, c))
    }

    /// Right-handed rotation about +Y. Note this *decreases* compass yaw by `r`.
    public static func rotationY(_ r: Float) -> Mat3 {
        let c = cos(r), s = sin(r)
        return Mat3(columns: Vec3(c, 0, -s), Vec3(0, 1, 0), Vec3(s, 0, c))
    }

    /// Right-handed rotation about +Z.
    public static func rotationZ(_ r: Float) -> Mat3 {
        let c = cos(r), s = sin(r)
        return Mat3(columns: Vec3(c, s, 0), Vec3(-s, c, 0), Vec3(0, 0, 1))
    }

    public var transposed: Mat3 {
        Mat3(columns: Vec3(c0.x, c1.x, c2.x), Vec3(c0.y, c1.y, c2.y), Vec3(c0.z, c1.z, c2.z))
    }

    public static func * (m: Mat3, v: Vec3) -> Vec3 {
        m.c0 * v.x + m.c1 * v.y + m.c2 * v.z
    }

    public static func * (a: Mat3, b: Mat3) -> Mat3 {
        Mat3(columns: a * b.c0, a * b.c1, a * b.c2)
    }
}

/// Unit quaternion (x, y, z, w), same component order as CoreMotion and SceneKit.
public struct Quat: Equatable {
    public var x: Float
    public var y: Float
    public var z: Float
    public var w: Float

    public init(x: Float, y: Float, z: Float, w: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public static let identity = Quat(x: 0, y: 0, z: 0, w: 1)

    public init(axis: Vec3, radians: Float) {
        let a = axis.normalized
        let h = radians / 2
        let s = sin(h)
        self.init(x: a.x * s, y: a.y * s, z: a.z * s, w: cos(h))
    }

    /// Hamilton product. `a * b` applies `b` first, then `a`.
    public static func * (a: Quat, b: Quat) -> Quat {
        Quat(
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
        )
    }

    public var normalized: Quat {
        let l = (x * x + y * y + z * z + w * w).squareRoot()
        guard l > 0 else { return .identity }
        return Quat(x: x / l, y: y / l, z: z / l, w: w / l)
    }

    public var rotationMatrix: Mat3 {
        let q = normalized
        let xx = q.x * q.x, yy = q.y * q.y, zz = q.z * q.z
        let xy = q.x * q.y, xz = q.x * q.z, yz = q.y * q.z
        let wx = q.w * q.x, wy = q.w * q.y, wz = q.w * q.z
        return Mat3(
            columns: Vec3(1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy)),
            Vec3(2 * (xy - wz), 1 - 2 * (xx + zz), 2 * (yz + wx)),
            Vec3(2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy))
        )
    }
}

public enum Angle {
    public static func radians(_ degrees: Float) -> Float { degrees * .pi / 180 }
    public static func degrees(_ radians: Float) -> Float { radians * 180 / .pi }

    /// Wraps to (-180, 180].
    public static func wrapDegrees180(_ d: Float) -> Float {
        var v = d.truncatingRemainder(dividingBy: 360)
        if v <= -180 { v += 360 }
        if v > 180 { v -= 360 }
        return v
    }

    /// Wraps to [0, 360).
    public static func wrapDegrees360(_ d: Float) -> Float {
        var v = d.truncatingRemainder(dividingBy: 360)
        if v < 0 { v += 360 }
        if v >= 360 { v -= 360 }
        return v
    }
}
