import SceneKit
import SurroundCore

/// A UV sphere whose texture coordinates follow Surround's equirectangular
/// layout exactly: u = (yaw + 180) / 360, v = (90 - pitch) / 180, with the
/// camera at the origin looking at the inside. Built by hand rather than using
/// SCNSphere so the seam and mirroring are deterministic.
enum SphereGeometry {
    static func make(radius: Float = 10, segments: Int = 96, rings: Int = 48) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var uvs: [CGPoint] = []
        var indices: [Int32] = []
        vertices.reserveCapacity((rings + 1) * (segments + 1))
        uvs.reserveCapacity((rings + 1) * (segments + 1))

        for r in 0...rings {
            let v = Float(r) / Float(rings)
            let pitchDegrees = 90 - v * 180
            for s in 0...segments {
                let u = Float(s) / Float(segments)
                let yawDegrees = u * 360 - 180
                let d = CapturePlan.direction(yawDegrees: yawDegrees, pitchDegrees: pitchDegrees)
                vertices.append(SCNVector3(x: d.x * radius, y: d.y * radius, z: d.z * radius))
                // SceneKit texture coordinates have (0, 0) at the image's top-left.
                // If the sky ever renders at the bottom, flip v here.
                uvs.append(CGPoint(x: CGFloat(u), y: CGFloat(v)))
            }
        }

        let stride = Int32(segments + 1)
        for r in 0..<rings {
            for s in 0..<segments {
                let a = Int32(r) * stride + Int32(s)
                let b = a + 1
                let c = a + stride
                let d = c + 1
                // Wound to face inwards; the material is double-sided anyway.
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }

        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(textureCoordinates: uvs)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .clamp
        material.diffuse.mipFilter = .linear
        geometry.materials = [material]
        return geometry
    }
}
