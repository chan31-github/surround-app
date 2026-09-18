import XCTest
@testable import SurroundCore

final class GeometryTests: XCTestCase {
    func testForwardIsMinusZAtYawZero() {
        let pose = CameraPose(rotation: .identity)
        XCTAssertEqual(pose.yawDegrees, 0, accuracy: 1e-4)
        XCTAssertEqual(pose.pitchDegrees, 0, accuracy: 1e-4)
        XCTAssertEqual(pose.forward, Vec3.forward)
    }

    func testRotationYDecreasesCompassYaw() {
        let pose = CameraPose(rotation: Mat3.rotationY(Angle.radians(90)))
        XCTAssertEqual(pose.yawDegrees, -90, accuracy: 1e-3)
        let pose2 = CameraPose(rotation: Mat3.rotationY(Angle.radians(-90)))
        XCTAssertEqual(pose2.yawDegrees, 90, accuracy: 1e-3)
    }

    func testYawShift() {
        let pose = CameraPose(rotation: Mat3.rotationY(Angle.radians(-30)))
        XCTAssertEqual(pose.yawDegrees, 30, accuracy: 1e-3)
        let shifted = pose.yawShifted(byDegrees: -30)
        XCTAssertEqual(shifted.yawDegrees, 0, accuracy: 1e-3)
        XCTAssertEqual(shifted.pitchDegrees, 0, accuracy: 1e-3)
    }

    func testPitchFromRotationX() {
        // Rotating about +X by +30 degrees tilts the -Z forward vector upwards.
        let pose = CameraPose(rotation: Mat3.rotationX(Angle.radians(30)))
        XCTAssertEqual(pose.pitchDegrees, 30, accuracy: 1e-3)
        XCTAssertEqual(pose.yawDegrees, 0, accuracy: 1e-3)
    }

    func testDirectionMatchesYawPitch() {
        let d = CapturePlan.direction(yawDegrees: 90, pitchDegrees: 0)
        XCTAssertEqual(d.x, 1, accuracy: 1e-5)
        XCTAssertEqual(d.z, 0, accuracy: 1e-5)
        let up = CapturePlan.direction(yawDegrees: 45, pitchDegrees: 90)
        XCTAssertEqual(up.y, 1, accuracy: 1e-5)
    }

    func testQuaternionMatchesMatrix() {
        let q = Quat(axis: Vec3(0, 1, 0), radians: Angle.radians(40))
        let m = Mat3.rotationY(Angle.radians(40))
        let v = Vec3(0.3, -0.2, 0.9)
        let a = q.rotationMatrix * v
        let b = m * v
        XCTAssertEqual(a.x, b.x, accuracy: 1e-5)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-5)
        XCTAssertEqual(a.z, b.z, accuracy: 1e-5)
    }

    func testQuaternionProductAppliesRightFirst() {
        let a = Quat(axis: Vec3(1, 0, 0), radians: Angle.radians(-90))
        let b = Quat(axis: Vec3(1, 0, 0), radians: Angle.radians(90))
        let m = (a * b).rotationMatrix
        let v = m * Vec3(0.2, 0.5, -0.7)
        XCTAssertEqual(v.x, 0.2, accuracy: 1e-5)
        XCTAssertEqual(v.y, 0.5, accuracy: 1e-5)
        XCTAssertEqual(v.z, -0.7, accuracy: 1e-5)
    }

    func testViewerOrientationFromCoreMotionAttitude() {
        // CoreMotion reference frame: Z up. Phone flat on a table, screen up,
        // has identity attitude; the camera on its back looks straight down.
        let sceneFromRef = Quat(axis: Vec3(1, 0, 0), radians: -.pi / 2)
        let flat = (sceneFromRef * Quat.identity).rotationMatrix
        let lookFlat = CameraPose(rotation: flat).forward
        XCTAssertEqual(lookFlat.y, -1, accuracy: 1e-5)

        // Phone held upright in portrait: attitude is +90 degrees about X.
        // The camera then looks along the horizon and the scene camera is upright.
        let upright = (sceneFromRef * Quat(axis: Vec3(1, 0, 0), radians: .pi / 2)).rotationMatrix
        XCTAssertEqual(CameraPose(rotation: upright).pitchDegrees, 0, accuracy: 1e-3)
        let up = upright * Vec3.up
        XCTAssertEqual(up.y, 1, accuracy: 1e-5)
    }

    func testWrap() {
        XCTAssertEqual(Angle.wrapDegrees180(190), -170, accuracy: 1e-5)
        XCTAssertEqual(Angle.wrapDegrees180(-190), 170, accuracy: 1e-5)
        XCTAssertEqual(Angle.wrapDegrees360(-10), 350, accuracy: 1e-5)
    }

    func testMat3FromColumnMajor4x4() {
        var m = [Float](repeating: 0, count: 16)
        for i in 0..<16 { m[i] = Float(i) }
        let r = Mat3(columnMajor4x4: m)
        XCTAssertEqual(r.c0, Vec3(0, 1, 2))
        XCTAssertEqual(r.c1, Vec3(4, 5, 6))
        XCTAssertEqual(r.c2, Vec3(8, 9, 10))
    }
}
