import Combine
import CoreLocation
import Foundation
import SwiftData
import SurroundCore
import UIKit

@MainActor
final class CaptureViewModel: ObservableObject {
    enum Stage: Equatable {
        case preview
        case capturing
        case stitching(Float)
        case review
        case failed(String)
    }

    @Published private(set) var stage: Stage = .preview
    @Published private(set) var reviewImage: UIImage?
    @Published private(set) var metadata: SphereMetadata?

    let capture = CaptureSession()
    let location = LocationService()
    var stitcher: SphereStitcher = ProjectionSphereStitcher()
    var outputWidth = 4096

    private let sphereID: UUID
    private let files: SphereFiles
    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false
    private var kept = false
    private var frontLocation: CLLocation?
    private var frontHeadingDegrees: Double?

    init() {
        let created = SphereStore.newSphereDirectory()
        sphereID = created.id
        files = created.files

        capture.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                switch phase {
                case .capturing: self.stage = .capturing
                case .finished: self.stitch()
                default: break
                }
            }
            .store(in: &cancellables)

        capture.$errorMessage
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] message in self?.stage = .failed(message) }
            .store(in: &cancellables)
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
        let report: (Float) -> Void = { [weak self] fraction in
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
                result = try await Task.detached(priority: .userInitiated) {
                    try stitcher.stitch(job: job, progress: report)
                }.value
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
}

enum CaptureError: LocalizedError {
    case step(String, Error)

    var errorDescription: String? {
        switch self {
        case .step(let name, let underlying):
            return "\(name): \(underlying.localizedDescription)"
        }
    }
}

enum DeviceInfo {
    /// Hardware identifier such as "iPhone14,4".
    static var machineIdentifier: String {
        var info = utsname()
        uname(&info)
        let data = Data(bytes: &info.machine, count: Int(_SYS_NAMELEN))
        let text = String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
}
