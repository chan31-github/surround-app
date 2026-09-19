import CoreMotion
import Foundation
import SceneKit
import SurroundCore
import UIKit

/// Turns CoreMotion device attitude into a SceneKit camera orientation.
///
/// CoreMotion's `xArbitraryCorrectedZVertical` frame has Z up; SceneKit has
/// Y up with the camera looking along -Z. The scene orientation is therefore
/// (rotate -90 degrees about X) * (device attitude) * (screen rotation),
/// so that a phone held upright gives an upright camera looking at the
/// horizon, tilting the phone tilts the horizon, and turning the phone to
/// landscape keeps the horizon level with the screen: the camera's frame is
/// the interface's, which differs from the device's by a rotation about the
/// screen normal (spec 6.7).
final class MotionController {
    private let manager = CMMotionManager()

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    /// Called on the main actor at up to 60 Hz.
    var onUpdate: ((Quat) -> Void)?
    /// The interface orientation the view is currently shown in; the owner
    /// keeps it current.
    var interfaceOrientation: UIInterfaceOrientation = .portrait

    func start() {
        guard isAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        // Updates are delivered on the main queue, which is the main actor.
        manager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let orientation = Self.sceneOrientation(from: motion.attitude.quaternion,
                                                        screenRotationRadians: Self.screenRotation(for: self.interfaceOrientation))
                self.onUpdate?(orientation)
            }
        }
    }

    /// Rotation about the screen normal from the device frame (portrait, top
    /// of the device up) to the interface frame. Interface `landscapeLeft`
    /// has the home indicator on the left, so the device's top points right
    /// and interface-up is the device's -X.
    nonisolated static func screenRotation(for orientation: UIInterfaceOrientation) -> Float {
        switch orientation {
        case .landscapeLeft: return .pi / 2
        case .landscapeRight: return -.pi / 2
        case .portraitUpsideDown: return .pi
        default: return 0
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    nonisolated static func sceneOrientation(from q: CMQuaternion, screenRotationRadians: Float = 0) -> Quat {
        let device = Quat(x: Float(q.x), y: Float(q.y), z: Float(q.z), w: Float(q.w))
        let sceneFromReference = Quat(axis: Vec3(1, 0, 0), radians: -.pi / 2)
        // Applied first: camera (interface) frame to device frame.
        let deviceFromInterface = Quat(axis: Vec3(0, 0, 1), radians: screenRotationRadians)
        return (sceneFromReference * device * deviceFromInterface).normalized
    }
}
