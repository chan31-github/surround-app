import Foundation
import SurroundCore

/// Input to a stitcher: the shot files on disk with their poses, and the yaw
/// that should become the sphere's front.
nonisolated struct StitchJob: Sendable {
    struct Shot: Sendable {
        let imageURL: URL
        let pose: ShotPose
    }

    var shots: [Shot]
    var frontYawDegrees: Float
    var outputWidth: Int
}

nonisolated enum StitchError: LocalizedError {
    case noShots
    case cannotLoad(URL)

    var errorDescription: String? {
        switch self {
        case .noShots: return "No shots were captured."
        case .cannotLoad(let url): return "Could not load \(url.lastPathComponent)."
        }
    }
}

/// Every stitching engine sits behind this so the projection baseline can be
/// swapped for a feature-matching engine (OpenCV) without touching capture,
/// storage or the viewer.
nonisolated protocol SphereStitcher: Sendable {
    var name: String { get }
    var version: String { get }
    /// Runs synchronously; call it off the main actor. `progress` is in 0...1
    /// and may be called from any thread.
    func stitch(job: StitchJob, progress: @escaping @Sendable (Float) -> Void) throws -> StitchResult
}

/// Projection stitcher from SurroundCore, wired to files on disk.
nonisolated struct ProjectionSphereStitcher: SphereStitcher {
    var name: String { ProjectionStitcher.name }
    var version: String { ProjectionStitcher.version }

    func stitch(job: StitchJob, progress: @escaping @Sendable (Float) -> Void) throws -> StitchResult {
        guard !job.shots.isEmpty else { throw StitchError.noShots }
        var shots: [StitchShot] = []
        shots.reserveCapacity(job.shots.count)
        for shot in job.shots {
            // Load each still at roughly 1.5x the resolution the output needs
            // along the sensor's long side, to keep memory bounded.
            let fovLong = shot.pose.intrinsics.fovAcrossWidthDegrees
            let needed = Int(Float(job.outputWidth) * fovLong / 360 * 1.5)
            let maxPixelSize = min(4096, max(800, needed))
            guard let image = ImageConversion.loadRGBA(from: shot.imageURL, maxPixelSize: maxPixelSize) else {
                throw StitchError.cannotLoad(shot.imageURL)
            }
            let intrinsics = shot.pose.intrinsics.scaled(toWidth: image.width, height: image.height)
            let rotation = shot.pose.cameraPose.yawShifted(byDegrees: -job.frontYawDegrees).rotation
            shots.append(StitchShot(image: image, intrinsics: intrinsics, rotation: rotation))
        }
        var options = StitchOptions()
        options.outputWidth = job.outputWidth
        var result = ProjectionStitcher.stitch(shots: shots, options: options, progress: progress)
        result.image.fillTransparentPixels(with: RGBAImage.skyGroundGradient(height: result.image.height))
        return result
    }
}
