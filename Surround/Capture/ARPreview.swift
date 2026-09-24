import ARKit
import ImageIO
import SceneKit
import SurroundCore
import SwiftUI

/// Camera preview backed by the capture session's ARSession, with every
/// captured still pasted into the scene at the pose it was taken from. ARKit
/// tracks the world, so the stills stay where they were shot as the phone
/// turns: the sphere is visibly growing behind the live view, gaps are
/// obvious, and the next frame can be lined up against its neighbours.
struct ARPreview: UIViewRepresentable {
    let session: ARSession
    var shots: [CapturedShot] = []
    /// A shot being retaken is lifted out so the live view shows through.
    var retakingIndex: Int? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.rendersContinuously = true
        context.coordinator.root = view.scene.rootNode
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.sync(shots, retaking: retakingIndex)
    }

    @MainActor
    final class Coordinator {
        weak var root: SCNNode?
        /// Distance the planes are placed at; only their angular size matters.
        private let radius: Float = 6
        private var nodes: [Int: (node: SCNNode, url: URL)] = [:]
        private var loading: Set<Int> = []

        func sync(_ shots: [CapturedShot], retaking: Int?) {
            guard root != nil else { return }
            var wanted: [Int: CapturedShot] = [:]
            for shot in shots where shot.pose.index != retaking { wanted[shot.pose.index] = shot }
            // Remove stills that are gone (undo, retake in progress) or replaced.
            for (index, entry) in nodes where wanted[index]?.fileURL != entry.url {
                entry.node.removeFromParentNode()
                nodes[index] = nil
            }
            for (index, shot) in wanted where nodes[index] == nil && !loading.contains(index) {
                loading.insert(index)
                Task {
                    let image = await Self.decode(shot.fileURL)
                    loading.remove(index)
                    guard let image, let root = self.root, self.nodes[index] == nil else { return }
                    let node = Self.makeNode(for: shot, image: image, radius: self.radius)
                    root.addChildNode(node)
                    self.nodes[index] = (node, shot.fileURL)
                }
            }
        }

        /// A plane facing the camera that took the shot, sized to its field of
        /// view. The still is stored in the sensor's frame (+X image right,
        /// +Y image up, looking along -Z), which is also the camera frame, so
        /// the texture maps straight onto the plane.
        private static func makeNode(for shot: CapturedShot, image: UIImage, radius: Float) -> SCNNode {
            let k = shot.pose.intrinsics
            let width = CGFloat(radius * Float(k.width) / k.fx)
            let height = CGFloat(radius * Float(k.height) / k.fy)
            let plane = SCNPlane(width: width, height: height)
            let material = SCNMaterial()
            material.diffuse.contents = image
            material.lightingModel = .constant
            material.isDoubleSided = true
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            material.transparency = 0.85
            plane.materials = [material]
            let node = SCNNode(geometry: plane)
            node.renderingOrder = 100 + shot.pose.index
            // Camera-from-world is the recorded transform; the plane sits `radius` ahead.
            let m = shot.pose.transformColumnMajor
            var transform = simd_float4x4(columns: (
                SIMD4(m[0], m[1], m[2], m[3]),
                SIMD4(m[4], m[5], m[6], m[7]),
                SIMD4(m[8], m[9], m[10], m[11]),
                SIMD4(m[12], m[13], m[14], m[15])))
            transform = transform * simd_float4x4(translation: SIMD3(0, 0, -radius))
            node.simdTransform = transform
            return node
        }

        @concurrent
        private static func decode(_ url: URL) async -> UIImage? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }
    }
}

private extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t.x, t.y, t.z, 1)
    }
}
