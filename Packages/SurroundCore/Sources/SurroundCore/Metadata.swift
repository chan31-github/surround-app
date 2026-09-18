import Foundation

/// Pose and intrinsics of one captured shot, stored next to its image file.
public struct ShotPose: Codable, Equatable, Sendable {
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

    /// False when the transform or intrinsics contain NaN or infinity, which
    /// ARKit can deliver while tracking is not established.
    public var hasFiniteGeometry: Bool {
        transformColumnMajor.count == 16
            && transformColumnMajor.allSatisfy { $0.isFinite }
            && [intrinsics.fx, intrinsics.fy, intrinsics.cx, intrinsics.cy].allSatisfy { $0.isFinite }
            && intrinsics.fx > 0 && intrinsics.fy > 0
    }

    public var imageFileName: String { String(format: "%03d.jpg", index) }
    public var poseFileName: String { String(format: "%03d.json", index) }
}

/// Everything recorded during one capture session, written as `capture.json`
/// in the shots folder so a sphere can be re-stitched later.
public struct CaptureManifest: Codable, Equatable, Sendable {
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
public struct SphereMetadata: Codable, Equatable, Sendable {
    public var formatVersion: Int = 1
    public var id: UUID
    public var capturedAt: Date
    public var latitude: Double?
    public var longitude: Double?
    public var altitudeMetres: Double?
    public var horizontalAccuracyMetres: Double?
    /// True when the user placed the sphere on the map by hand rather than
    /// the position coming from GPS at capture.
    public var isManualPosition: Bool = false
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

    /// Fields added after a file was written, and fields with defaults, are
    /// optional when decoding so older metadata files keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        altitudeMetres = try c.decodeIfPresent(Double.self, forKey: .altitudeMetres)
        horizontalAccuracyMetres = try c.decodeIfPresent(Double.self, forKey: .horizontalAccuracyMetres)
        isManualPosition = try c.decodeIfPresent(Bool.self, forKey: .isManualPosition) ?? false
        frontHeadingDegrees = try c.decodeIfPresent(Double.self, forKey: .frontHeadingDegrees)
        coveredPitchMinDegrees = try c.decodeIfPresent(Float.self, forKey: .coveredPitchMinDegrees)
        coveredPitchMaxDegrees = try c.decodeIfPresent(Float.self, forKey: .coveredPitchMaxDegrees)
        projection = try c.decodeIfPresent(String.self, forKey: .projection) ?? "equirectangular"
        widthPx = try c.decode(Int.self, forKey: .widthPx)
        heightPx = try c.decode(Int.self, forKey: .heightPx)
        stitcher = try c.decode(String.self, forKey: .stitcher)
        stitcherVersion = try c.decode(String.self, forKey: .stitcherVersion)
        deviceModel = try c.decodeIfPresent(String.self, forKey: .deviceModel)
        shotCount = try c.decode(Int.self, forKey: .shotCount)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

public enum MetadataCoding {
    /// JSON has no NaN or infinity; encoding one throws "The data couldn't be
    /// written because it isn't in the correct format". Sensor values can be
    /// non-finite, so they are written as strings instead of failing the save.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }
}
