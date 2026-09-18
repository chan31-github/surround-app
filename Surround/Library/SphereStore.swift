import Foundation
import SwiftData
import SurroundCore
import UIKit

/// File layout of one sphere inside the app's Documents folder:
///
///     Documents/spheres/<uuid>/
///         sphere.jpg       stitched equirectangular image
///         thumb.jpg        512 x 256 preview
///         metadata.json    SphereMetadata
///         shots/           source stills, one pose file each, plus capture.json
nonisolated struct SphereFiles: Sendable {
    let directory: URL

    var image: URL { directory.appendingPathComponent("sphere.jpg") }
    var thumbnail: URL { directory.appendingPathComponent("thumb.jpg") }
    var metadata: URL { directory.appendingPathComponent("metadata.json") }
    var shots: URL { directory.appendingPathComponent("shots", isDirectory: true) }
    var manifest: URL { shots.appendingPathComponent("capture.json") }
}

nonisolated enum SphereStoreError: LocalizedError {
    case imageEncoding

    var errorDescription: String? {
        switch self {
        case .imageEncoding: return "Could not encode the stitched image."
        }
    }
}

nonisolated enum SphereStore {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("spheres", isDirectory: true)
    }

    static func files(for id: UUID) -> SphereFiles {
        SphereFiles(directory: root.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    static func newSphereDirectory() -> (id: UUID, files: SphereFiles) {
        let id = UUID()
        let f = files(for: id)
        try? FileManager.default.createDirectory(at: f.shots, withIntermediateDirectories: true)
        return (id, f)
    }

    /// Writes the stitched image, its thumbnail and metadata. Returns the
    /// decoded image so the caller can show it without re-reading the file.
    @discardableResult
    static func save(image: RGBAImage, metadata: SphereMetadata, to files: SphereFiles) throws -> UIImage {
        guard let cg = ImageConversion.cgImage(from: image) else { throw SphereStoreError.imageEncoding }
        let ui = UIImage(cgImage: cg)
        guard let jpeg = ui.jpegData(compressionQuality: 0.9) else { throw SphereStoreError.imageEncoding }
        try jpeg.write(to: files.image, options: .atomic)
        if let thumb = ImageConversion.thumbnailJPEG(from: ui, width: 512, height: 256) {
            try thumb.write(to: files.thumbnail, options: .atomic)
        }
        try MetadataCoding.encode(metadata).write(to: files.metadata, options: .atomic)
        return ui
    }

    /// Every sphere folder that has a metadata file, whatever the index says.
    static func storedMetadata() -> [SphereMetadata] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("metadata.json")),
                  let meta = try? MetadataCoding.decode(SphereMetadata.self, from: data),
                  folder.lastPathComponent == meta.id.uuidString else { return nil }
            return meta
        }
    }

    /// Makes the index match the folders: files are the source of truth, so a
    /// folder without a row gets one and a row without a folder is dropped.
    /// Cheap enough to run at every launch; later this is also how spheres
    /// synced from another device appear.
    @MainActor
    static func reconcileIndex(in context: ModelContext) {
        let stored = storedMetadata()
        let onDisk = Set(stored.map { $0.id })
        let records = (try? context.fetch(FetchDescriptor<SphereRecord>())) ?? []
        let indexed = Set(records.map { $0.id })
        for record in records where !onDisk.contains(record.id) {
            context.delete(record)
        }
        for meta in stored where !indexed.contains(meta.id) {
            context.insert(SphereRecord(metadata: meta, fileSizeBytes: directorySize(files(for: meta.id).directory)))
        }
    }

    static func loadMetadata(id: UUID) throws -> SphereMetadata {
        try MetadataCoding.decode(SphereMetadata.self, from: Data(contentsOf: files(for: id).metadata))
    }

    /// Reads, changes and rewrites a sphere's metadata file atomically.
    static func updateMetadata(id: UUID, _ change: (inout SphereMetadata) -> Void) throws {
        var meta = try loadMetadata(id: id)
        change(&meta)
        try MetadataCoding.encode(meta).write(to: files(for: id).metadata, options: .atomic)
    }

    static func delete(id: UUID) {
        try? FileManager.default.removeItem(at: files(for: id).directory)
    }

    static func directorySize(_ url: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let file as URL in e {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Writes a copy of the sphere image with Photo Sphere XMP metadata into a
    /// temporary file suitable for the share sheet.
    static func exportJPEG(id: UUID) throws -> URL {
        let metadata = try loadMetadata(id: id)
        let jpeg = try Data(contentsOf: files(for: id).image)
        let xmp = PhotoSphereXMP(fullEquirectangularWidth: metadata.widthPx,
                                 height: metadata.heightPx,
                                 poseHeadingDegrees: metadata.frontHeadingDegrees)
        let data = JPEGXMPEmbedder.embed(xmp.packet, in: jpeg) ?? jpeg
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let name = "Surround-\(formatter.string(from: metadata.capturedAt)).jpg"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}
