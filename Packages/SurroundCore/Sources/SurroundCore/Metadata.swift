import Foundation

/// Pose and intrinsics of one captured shot, stored next to its image file.
public struct ShotPose: Codable, Equatable {
    public var index: Int
    /// Session-relative timestamp, seconds.
    public var timestamp: TimeInterval
    /// ARKit `camera.transform` as 16 column-major floats.
    public var transformColumnMajor: [Float]
    /// Intrinsics for the stored image's pixel size.
    public var intrinsics: CameraIntrinsics
    public var exposureDurationSeconds: Double?
    public var exposureOffset: Float?
    public var targetYawDegrees: Float?
    public var targetPitchDegrees: Float?

    public init(index: Int,
                timestamp: TimeInterval,
                transformColumnMajor: [Float],
                intrinsics: CameraIntrinsics,
                exposureDurationSeconds: Double? = nil,
                exposureOffset: Float? = nil,
                targetYawDegrees: Float? = nil,
                targetPitchDegrees: Float? = nil) {
        self.index = index
        self.timestamp = timestamp
        self.transformColumnMajor = transformColumnMajor
        self.intrinsics = intrinsics
        self.exposureDurationSeconds = exposureDurationSeconds
        self.exposureOffset = exposureOffset
        self.targetYawDegrees = targetYawDegrees
        self.targetPitchDegrees = targetPitchDegrees
    }

    public var cameraPose: CameraPose {
        CameraPose(rotation: Mat3(columnMajor4x4: transformColumnMajor))
    }

    public var imageFileName: String { String(format: "%03d.jpg", index) }
    public var poseFileName: String { String(format: "%03d.json", index) }
}

/// Everything recorded during one capture session, written as `capture.json`
/// in the shots folder so a sphere can be re-stitched later.
public struct CaptureManifest: Codable, Equatable {
    public var formatVersion: Int = 1
    public var startedAt: Date
    /// ARKit yaw of the first shot; the sphere's front (yaw 0) in stitched output.
    public var frontYawDegrees: Float
    public var poses: [ShotPose]
    public var planYawStepDegrees: Float

    public init(startedAt: Date, frontYawDegrees: Float, poses: [ShotPose], planYawStepDegrees: Float) {
        self.startedAt = startedAt
        self.frontYawDegrees = frontYawDegrees
        self.poses = poses
        self.planYawStepDegrees = planYawStepDegrees
    }
}

/// `metadata.json` for a stored sphere. Files are the source of truth; the
/// app's database index can be rebuilt from these.
public struct SphereMetadata: Codable, Equatable {
    public var formatVersion: Int = 1
    public var id: UUID
    public var capturedAt: Date
    public var latitude: Double?
    public var longitude: Double?
    public var altitudeMetres: Double?
    public var horizontalAccuracyMetres: Double?
    /// Compass heading of the sphere's front (image centre), degrees from true north.
    public var frontHeadingDegrees: Double?
    public var coveredPitchMinDegrees: Float?
    public var coveredPitchMaxDegrees: Float?
    public var projection: String = "equirectangular"
    public var widthPx: Int
    public var heightPx: Int
    public var stitcher: String
    public var stitcherVersion: String
    public var deviceModel: String?
    public var shotCount: Int
    public var title: String = ""
    public var tags: [String] = []
    public var notes: String = ""

    public init(id: UUID,
                capturedAt: Date,
                widthPx: Int,
                heightPx: Int,
                stitcher: String,
                stitcherVersion: String,
                shotCount: Int) {
        self.id = id
        self.capturedAt = capturedAt
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.stitcher = stitcher
        self.stitcherVersion = stitcherVersion
        self.shotCount = shotCount
    }
}

public enum MetadataCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }
}
