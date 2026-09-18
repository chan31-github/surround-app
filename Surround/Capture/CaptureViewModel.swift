import CoreLocation
import Foundation
import Observation
import SwiftData
import SurroundCore
import UIKit

@Observable
final class CaptureViewModel {
    enum Stage: Equatable {
        case preview
        case capturing
        case stitching(Float)
        case review
        case failed(String)
    }

    private(set) var stage: Stage = .preview
    private(set) var reviewImage: UIImage?
    private(set) var metadata: SphereMetadata?

    let capture = CaptureSession()
    let location = LocationService()
    var stitcher: any SphereStitcher = ProjectionSphereStitcher()
    var outputWidth = 4096

    private let sphereID: UUID
    private let files: SphereFiles
    private var hasStarted = false
    private var kept = false
    private var frontLocation: CLLocation?
    private var frontHeadingDegrees: Double?

    init() {
        let created = SphereStore.newSphereDirectory()
        sphereID = created.id
        files = created.files

        capture.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            switch phase {
            case .capturing: stage = .capturing
            case .finished: stitch()
            default: break
            }
        }
        capture.onError = { [weak self] message in
            self?.stage = .failed(message)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        UIApplication.shared.isIdleTimerDisabled = true
        location.start()
        capture.startPreview(shotsDirectory: files.shots)
    }

    /// The user is facing the direction they want as the sphere's front.
    func beginRing() {
        frontLocation = location.location
        frontHeadingDegrees = location.trueHeadingDegrees
        capture.beginRing()
    }

    /// Stops everything and removes the sphere's folder unless it was kept.
    func teardown() {
        UIApplication.shared.isIdleTimerDisabled = false
        capture.stop()
        location.stop()
        if !kept {
            SphereStore.delete(id: sphereID)
        }
    }

    func keep(in context: ModelContext) {
        guard let metadata, !kept else { return }
        let record = SphereRecord(metadata: metadata, fileSizeBytes: SphereStore.directorySize(files.directory))
        context.insert(record)
        kept = true
    }

    private func stitch() {
        Task { await runStitch() }
    }

    private func runStitch() async {
        stage = .stitching(0)
        location.stop()
        let manifest = capture.manifest()
        let job = StitchJob(shots: capture.shots.map { StitchJob.Shot(imageURL: $0.fileURL, pose: $0.pose) },
                            frontYawDegrees: manifest.frontYawDegrees,
                            outputWidth: outputWidth)
        let stitcher = self.stitcher
        let report: @Sendable (Float) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.stage = .stitching(fraction) }
        }
        do {
            do {
                try MetadataCoding.encode(manifest).write(to: files.manifest, options: .atomic)
            } catch {
                throw CaptureError.step("Saving capture manifest", error)
            }
            let result: StitchResult
            do {
                result = try await Self.runStitcher(stitcher, job: job, progress: report)
            } catch {
                throw CaptureError.step("Stitching", error)
            }

            var meta = SphereMetadata(id: sphereID,
                                      capturedAt: manifest.startedAt,
                                      widthPx: result.image.width,
                                      heightPx: result.image.height,
                                      stitcher: stitcher.name,
                                      stitcherVersion: stitcher.version,
                                      shotCount: job.shots.count)
            if let loc = frontLocation ?? location.location {
                meta.latitude = loc.coordinate.latitude
                meta.longitude = loc.coordinate.longitude
                meta.altitudeMetres = loc.altitude
                meta.horizontalAccuracyMetres = loc.horizontalAccuracy
            }
            meta.frontHeadingDegrees = frontHeadingDegrees
            meta.coveredPitchMinDegrees = result.coveredPitchRangeDegrees?.lowerBound
            meta.coveredPitchMaxDegrees = result.coveredPitchRangeDegrees?.upperBound
            meta.deviceModel = DeviceInfo.machineIdentifier

            do {
                reviewImage = try SphereStore.save(image: result.image, metadata: meta, to: files)
            } catch {
                throw CaptureError.step("Saving sphere", error)
            }
            metadata = meta
            stage = .review
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// Runs the stitcher off the main actor; it is CPU-bound for seconds.
    @concurrent
    private nonisolated static func runStitcher(_ stitcher: any SphereStitcher,
                                                job: StitchJob,
                                                progress: @escaping @Sendable (Float) -> Void) async throws -> StitchResult {
        try stitcher.stitch(job: job, progress: progress)
    }
}

nonisolated enum CaptureError: LocalizedError {
    case step(String, Error)

    var errorDescription: String? {
        switch self {
        case .step(let name, let underlying):
            return "\(name): \(underlying.localizedDescription)"
        }
    }
}

nonisolated enum DeviceInfo {
    /// Hardware identifier such as "iPhone14,4".
    static var machineIdentifier: String {
        var info = utsname()
        uname(&info)
        let data = Data(bytes: &info.machine, count: Int(_SYS_NAMELEN))
        let text = String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
}
