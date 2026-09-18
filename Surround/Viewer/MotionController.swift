import CoreMotion
import Foundation
import SceneKit
import SurroundCore

/// Turns CoreMotion device attitude into a SceneKit camera orientation.
///
/// CoreMotion's `xArbitraryCorrectedZVertical` frame has Z up; SceneKit has
/// Y up with the camera looking along -Z. The scene orientation is therefore
/// (rotate -90 degrees about X) * (device attitude), so that a phone held
/// upright in portrait gives an upright camera looking at the horizon, and
/// tilting the phone tilts the horizon.
final class MotionController {
    private let manager = CMMotionManager()

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    /// Called on the main actor at up to 60 Hz.
    var onUpdate: ((Quat) -> Void)?

    func start() {
        guard isAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        // Updates are delivered on the main queue, which is the main actor.
        manager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let orientation = Self.sceneOrientation(from: motion.attitude.quaternion)
            MainActor.assumeIsolated {
                self?.onUpdate?(orientation)
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    nonisolated static func sceneOrientation(from q: CMQuaternion) -> Quat {
        let device = Quat(x: Float(q.x), y: Float(q.y), z: Float(q.z), w: Float(q.w))
        let sceneFromReference = Quat(axis: Vec3(1, 0, 0), radians: -.pi / 2)
        return (sceneFromReference * device).normalized
    }
}
