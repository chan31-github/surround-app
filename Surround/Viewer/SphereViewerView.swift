import SceneKit
import SwiftUI
import SurroundCore
import UIKit

/// Immersive viewer: the equirectangular image on the inside of a sphere,
/// steered by the phone's motion with drag as a fallback, pinch to zoom,
/// double-tap to recentre on the sphere's front.
struct SphereViewerView: UIViewRepresentable {
    let image: UIImage
    /// Receives the view direction and provides recentring; optional so the
    /// view can stand alone.
    var state: ViewerState? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.allowsCameraControl = false
        context.coordinator.attach(to: view, image: image)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.update(image: image)
        context.coordinator.state = state
        state?.recentreAction = { [weak coordinator = context.coordinator] in coordinator?.recentre() }
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject {
        private let scene = SCNScene()
        private let yawNode = SCNNode()
        private let cameraNode = SCNNode()
        private let sphereNode = SCNNode()
        private let camera = SCNCamera()
        private let motion = MotionController()
        private weak var view: SCNView?
        private var currentImage: UIImage?
        var state: ViewerState?

        private var usesMotion = false
        private var baseYawRadians: Float?
        private var dragYawRadians: Float = 0
        private var dragPitchRadians: Float = 0
        private var panStartYaw: Float = 0
        private var panStartPitch: Float = 0
        private var pinchStartFOV: CGFloat = 75

        private let minFOV: CGFloat = 30
        private let maxFOV: CGFloat = 100

        func attach(to view: SCNView, image: UIImage) {
            self.view = view
            camera.fieldOfView = 75
            camera.projectionDirection = .vertical
            camera.zNear = 0.1
            camera.zFar = 100
            cameraNode.camera = camera
            yawNode.addChildNode(cameraNode)
            scene.rootNode.addChildNode(yawNode)
            sphereNode.geometry = SphereGeometry.make()
            scene.rootNode.addChildNode(sphereNode)
            view.scene = scene
            view.pointOfView = cameraNode
            update(image: image)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(pinch)
            view.addGestureRecognizer(doubleTap)

            usesMotion = motion.isAvailable
            if usesMotion {
                motion.onUpdate = { [weak self] q in self?.apply(deviceOrientation: q) }
                motion.start()
            } else {
                applyDragOnlyOrientation()
            }
        }

        func detach() {
            motion.stop()
        }

        func update(image: UIImage) {
            guard image !== currentImage else { return }
            currentImage = image
            sphereNode.geometry?.firstMaterial?.diffuse.contents = image
        }

        // MARK: Orientation

        private func apply(deviceOrientation q: Quat) {
            let yaw = Angle.radians(CameraPose(rotation: q.rotationMatrix).yawDegrees)
            if baseYawRadians == nil { baseYawRadians = yaw }
            cameraNode.orientation = SCNQuaternion(x: q.x, y: q.y, z: q.z, w: q.w)
            // A parent rotation about +Y of b reduces compass yaw by b, so this
            // makes the view start at the sphere's front (yaw 0) plus any drag.
            yawNode.eulerAngles = SCNVector3(x: 0, y: (baseYawRadians ?? 0) - dragYawRadians, z: 0)
            report(viewYawRadians: yaw - (baseYawRadians ?? 0) + dragYawRadians)
        }

        private func applyDragOnlyOrientation() {
            yawNode.eulerAngles = SCNVector3(x: 0, y: 0, z: 0)
            cameraNode.eulerAngles = SCNVector3(x: dragPitchRadians, y: -dragYawRadians, z: 0)
            report(viewYawRadians: dragYawRadians)
        }

        private func report(viewYawRadians: Float) {
            state?.report(viewYawDegrees: Angle.wrapDegrees180(Angle.degrees(viewYawRadians)),
                          fieldOfViewDegrees: Float(camera.fieldOfView))
        }

        /// Faces the sphere's front from the phone's current direction, at the
        /// default zoom. Double-tap and the compass rose both call this.
        func recentre() {
            dragYawRadians = 0
            dragPitchRadians = 0
            baseYawRadians = nil
            camera.fieldOfView = 75
            if !usesMotion { applyDragOnlyOrientation() }
        }

        // MARK: Gestures

        @objc private func handlePan(_ g: UIPanGestureRecognizer) {
            guard let view else { return }
            let radiansPerPoint = Float(camera.fieldOfView) / Float(max(1, view.bounds.height)) * .pi / 180
            switch g.state {
            case .began:
                panStartYaw = dragYawRadians
                panStartPitch = dragPitchRadians
            case .changed:
                let t = g.translation(in: view)
                dragYawRadians = panStartYaw - Float(t.x) * radiansPerPoint
                if !usesMotion {
                    let limit = Float(80) * .pi / 180
                    dragPitchRadians = max(-limit, min(limit, panStartPitch + Float(t.y) * radiansPerPoint))
                    applyDragOnlyOrientation()
                } else {
                    yawNode.eulerAngles = SCNVector3(x: 0, y: (baseYawRadians ?? 0) - dragYawRadians, z: 0)
                }
            default:
                break
            }
        }

        @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began:
                pinchStartFOV = camera.fieldOfView
            case .changed:
                camera.fieldOfView = max(minFOV, min(maxFOV, pinchStartFOV / g.scale))
                if !usesMotion { applyDragOnlyOrientation() }
            default:
                break
            }
        }

        @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
            recentre()
        }
    }
}
