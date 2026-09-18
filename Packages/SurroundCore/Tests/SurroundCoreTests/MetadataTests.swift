import XCTest
@testable import SurroundCore

final class MetadataTests: XCTestCase {
    func testSphereMetadataRoundTrip() throws {
        var m = SphereMetadata(id: UUID(), capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                               widthPx: 4096, heightPx: 2048, stitcher: "projection", stitcherVersion: "0.1", shotCount: 13)
        m.latitude = 22.27
        m.longitude = 114.15
        m.frontHeadingDegrees = 123.4
        m.coveredPitchMinDegrees = -33
        m.coveredPitchMaxDegrees = 34
        m.tags = ["Lantau Peak"]
        let data = try MetadataCoding.encode(m)
        let back = try MetadataCoding.decode(SphereMetadata.self, from: data)
        XCTAssertEqual(back, m)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"projection\" : \"equirectangular\""))
    }

    func testShotPoseRoundTripAndCameraPose() throws {
        var t = [Float](repeating: 0, count: 16)
        let r = Mat3.rotationY(Angle.radians(-45))
        t[0] = r.c0.x; t[1] = r.c0.y; t[2] = r.c0.z
        t[4] = r.c1.x; t[5] = r.c1.y; t[6] = r.c1.z
        t[8] = r.c2.x; t[9] = r.c2.y; t[10] = r.c2.z
        t[15] = 1
        let pose = ShotPose(index: 3, timestamp: 1.5, transformColumnMajor: t,
                            intrinsics: CameraIntrinsics(fx: 3000, fy: 3000, cx: 2016, cy: 1512, width: 4032, height: 3024))
        let data = try MetadataCoding.encode(pose)
        let back = try MetadataCoding.decode(ShotPose.self, from: data)
        XCTAssertEqual(back, pose)
        XCTAssertEqual(back.cameraPose.yawDegrees, 45, accuracy: 1e-3)
        XCTAssertEqual(back.imageFileName, "003.jpg")
    }

    func testIntrinsicsScalingKeepsFOV() {
        let i = CameraIntrinsics(fx: 3000, fy: 3000, cx: 2016, cy: 1512, width: 4032, height: 3024)
        let s = i.scaled(toWidth: 1008, height: 756)
        XCTAssertEqual(s.fovAcrossWidthDegrees, i.fovAcrossWidthDegrees, accuracy: 1e-3)
        XCTAssertEqual(s.fovAcrossHeightDegrees, i.fovAcrossHeightDegrees, accuracy: 1e-3)
        XCTAssertEqual(s.cx, 504, accuracy: 1e-3)
    }

    func testProjectionOfCentreAndBehind() {
        let i = CameraIntrinsics(fx: 100, fy: 100, cx: 50, cy: 40, width: 100, height: 80)
        let c = i.project(Vec3(0, 0, -1))
        XCTAssertEqual(c?.u ?? -1, 50, accuracy: 1e-5)
        XCTAssertEqual(c?.v ?? -1, 40, accuracy: 1e-5)
        XCTAssertNil(i.project(Vec3(0, 0, 1)))
        // A point above the axis (+Y) lands in the upper half of the image (smaller v).
        let up = i.project(Vec3(0, 0.5, -1))
        XCTAssertLessThan(up?.v ?? 100, 40)
    }

    func testXMPPacketAndEmbedding() throws {
        let xmp = PhotoSphereXMP(fullEquirectangularWidth: 4096, height: 2048, poseHeadingDegrees: -10)
        let packet = xmp.packet
        XCTAssertTrue(packet.contains("<GPano:ProjectionType>equirectangular</GPano:ProjectionType>"))
        XCTAssertTrue(packet.contains("<GPano:PoseHeadingDegrees>350.00</GPano:PoseHeadingDegrees>"))
        XCTAssertTrue(packet.contains("<GPano:FullPanoWidthPixels>4096</GPano:FullPanoWidthPixels>"))

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let out = try XCTUnwrap(JPEGXMPEmbedder.embed(packet, in: jpeg))
        XCTAssertEqual(Array(out.prefix(4)), [0xFF, 0xD8, 0xFF, 0xE1])
        let length = Int(out[4]) << 8 | Int(out[5])
        XCTAssertEqual(length, 2 + JPEGXMPEmbedder.xmpNamespace.utf8.count + 1 + packet.utf8.count)
        XCTAssertEqual(Array(out.suffix(2)), [0xFF, 0xD9])
        XCTAssertNil(JPEGXMPEmbedder.embed(packet, in: Data([0x00, 0x01, 0x02, 0x03])))
    }
}

final class NonFiniteMetadataTests: XCTestCase {
    private func pose(exposureOffset: Float?, transform: [Float]) -> ShotPose {
        ShotPose(index: 0, timestamp: 0, transformColumnMajor: transform,
                 intrinsics: CameraIntrinsics(fx: 3000, fy: 3000, cx: 2016, cy: 1512, width: 4032, height: 3024),
                 exposureOffset: exposureOffset)
    }

    private var identityTransform: [Float] {
        var t = [Float](repeating: 0, count: 16)
        t[0] = 1; t[5] = 1; t[10] = 1; t[15] = 1
        return t
    }

    func testNaNExposureOffsetStillEncodes() throws {
        let p = pose(exposureOffset: .nan, transform: identityTransform)
        let data = try MetadataCoding.encode(p)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"nan\""))
        let back = try MetadataCoding.decode(ShotPose.self, from: data)
        XCTAssertTrue(back.exposureOffset?.isNaN ?? false)
        XCTAssertTrue(back.hasFiniteGeometry)
    }

    func testNonFiniteTransformIsDetected() {
        var t = identityTransform
        t[3] = .infinity
        XCTAssertFalse(pose(exposureOffset: nil, transform: t).hasFiniteGeometry)
        XCTAssertFalse(pose(exposureOffset: nil, transform: [1, 2, 3]).hasFiniteGeometry)
        XCTAssertTrue(pose(exposureOffset: nil, transform: identityTransform).hasFiniteGeometry)
    }

    func testSphereMetadataDecodesFilesWrittenBeforeNewFields() throws {
        // A v0.1 metadata file: no isManualPosition, no title/tags/notes.
        let json = """
        {"id":"345BB39A-25DA-4609-AA44-34064D2AB4FC","capturedAt":"2026-09-18T08:11:09Z",
         "latitude":22.48,"longitude":114.157,"widthPx":4096,"heightPx":2048,
         "stitcher":"projection","stitcherVersion":"0.1","shotCount":12}
        """
        let meta = try MetadataCoding.decode(SphereMetadata.self, from: Data(json.utf8))
        XCTAssertFalse(meta.isManualPosition)
        XCTAssertEqual(meta.projection, "equirectangular")
        XCTAssertEqual(meta.title, "")
        XCTAssertEqual(meta.tags, [])
        XCTAssertEqual(meta.latitude, 22.48)

        var placed = meta
        placed.isManualPosition = true
        let again = try MetadataCoding.decode(SphereMetadata.self, from: MetadataCoding.encode(placed))
        XCTAssertTrue(again.isManualPosition)
        XCTAssertEqual(again, placed)
    }
}
