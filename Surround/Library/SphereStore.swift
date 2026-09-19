import Foundation
import os
import SwiftData
import SurroundCore
import UIKit

/// File layout of one sphere inside the spheres folder, which lives in the
/// app's Documents folder until iCloud Drive is available and in the app's
/// ubiquity container after that (spec 6.7, F17):
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
    /// The spheres folder inside the app's own Documents.
    static var localRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("spheres", isDirectory: true)
    }

    private static let syncedRoot = OSAllocatedUnfairLock<URL?>(initialState: nil)

    /// Where spheres live now: the iCloud container once `SyncCoordinator`
    /// has found it and moved the local spheres there, otherwise Documents.
    static var root: URL {
        syncedRoot.withLock { $0 } ?? localRoot
    }

    /// Switches every path the store hands out to the synced folder.
    static func useSyncedRoot(_ url: URL) {
        syncedRoot.withLock { $0 = url }
    }

    /// Trip names by day key, kept as a file beside the spheres so they sync
    /// like everything else; the TripRecord rows are rebuilt from it.
    static var tripNamesFile: URL { root.appendingPathComponent("trips.json") }

    static func loadTripNames() -> [String: String] {
        guard let data = try? Data(contentsOf: tripNamesFile),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return names
    }

    /// Sets or, with an empty name, removes a trip's name in the file.
    static func setTripName(_ name: String, forDay day: String) throws {
        var names = loadTripNames()
        if name.isEmpty { names[day] = nil } else { names[day] = name }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(names).write(to: tripNamesFile, options: .atomic)
    }

    // MARK: iCloud state of a file

    /// True when the file's bytes are on this device (always true for a
    /// file outside iCloud). A file that is still in the cloud is listed as
    /// a placeholder and cannot be read.
    static func isDownloaded(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) else {
            return FileManager.default.fileExists(atPath: url.path)
        }
        guard values.isUbiquitousItem == true else { return FileManager.default.fileExists(atPath: url.path) }
        return values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded
    }

    /// Asks iCloud for the file if needed and waits until it is readable, or
    /// gives up after `timeout` seconds.
    @concurrent
    static func ensureDownloaded(_ url: URL, timeout: TimeInterval = 90) async throws -> Bool {
        if isDownloaded(url) { return true }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(400))
            if isDownloaded(url) { return true }
        }
        return false
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

    /// Which thumbnail layout the files on disk were written with. Bumped
    /// when the layout changes so existing spheres are regenerated once.
    static let thumbnailFormat = 2
    private static let thumbnailFormatKey = "thumbnails.format"

    /// Rewrites a sphere's thumbnail from its stitched image.
    static func regenerateThumbnail(id: UUID) {
        let f = files(for: id)
        guard let image = UIImage(contentsOfFile: f.image.path),
              let thumb = ImageConversion.thumbnailJPEG(from: image, width: 512, height: 256) else { return }
        try? thumb.write(to: f.thumbnail, options: .atomic)
        ThumbnailCache.shared.remove(id)
    }

    /// Regenerates every thumbnail once after the layout changes, off the
    /// main actor. Returns true when anything was rewritten.
    @concurrent
    static func migrateThumbnailsIfNeeded() async -> Bool {
        guard UserDefaults.standard.integer(forKey: thumbnailFormatKey) < thumbnailFormat else { return false }
        for meta in storedMetadata() {
            regenerateThumbnail(id: meta.id)
        }
        UserDefaults.standard.set(thumbnailFormat, forKey: thumbnailFormatKey)
        return true
    }

    /// One sphere folder as the scan saw it.
    struct StoredSphere: Sendable {
        let metadata: SphereMetadata
        /// Modification date of metadata.json, for spotting edits made on
        /// another device.
        let metadataModifiedAt: Date?
    }

    /// Every sphere folder whose metadata file is readable, whatever the
    /// index says. A folder whose metadata is still in the cloud is skipped
    /// until it arrives; the sync coordinator asks for it.
    static func storedSpheres() -> [StoredSphere] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder in
            let metaURL = folder.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? MetadataCoding.decode(SphereMetadata.self, from: data),
                  folder.lastPathComponent == meta.id.uuidString else { return nil }
            let modified = try? metaURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return StoredSphere(metadata: meta, metadataModifiedAt: modified)
        }
    }

    static func storedMetadata() -> [SphereMetadata] {
        storedSpheres().map { $0.metadata }
    }

    /// What a scan of the folders found, relative to what the index had.
    struct IndexScan: Sendable {
        var onDisk: Set<UUID>
        var missingFromIndex: [(sphere: StoredSphere, fileSizeBytes: Int)]
        /// Rows whose metadata file changed since they were indexed.
        var changed: [StoredSphere]
        var tripNames: [String: String]
    }

    /// Reads every metadata file and sizes the folders the index lacks. Runs
    /// off the main actor; the file reading grows with the library.
    @concurrent
    static func scanFolders(indexed: [UUID: Date?]) async -> IndexScan {
        let stored = storedSpheres()
        var missing: [(sphere: StoredSphere, fileSizeBytes: Int)] = []
        var changed: [StoredSphere] = []
        for sphere in stored {
            if let indexedAt = indexed[sphere.metadata.id] {
                if let modified = sphere.metadataModifiedAt, modified != indexedAt { changed.append(sphere) }
            } else {
                missing.append((sphere, directorySize(files(for: sphere.metadata.id).directory)))
            }
        }
        return IndexScan(onDisk: Set(stored.map { $0.metadata.id }), missingFromIndex: missing,
                         changed: changed, tripNames: loadTripNames())
    }

    /// Makes the index match the folders: files are the source of truth, so a
    /// folder without a row gets one, a row without a folder is dropped, and
    /// a row whose metadata file changed (an edit synced from another device)
    /// is refreshed. Trip names come from trips.json the same way. Runs at
    /// launch and whenever the sync coordinator sees the folder change. Only
    /// the SwiftData work touches the main actor.
    @MainActor
    static func reconcileIndex(in context: ModelContext) async {
        let records = (try? context.fetch(FetchDescriptor<SphereRecord>())) ?? []
        // Rows written before the trip key existed get it now.
        for record in records where record.tripDayKey.isEmpty {
            record.tripDayKey = TripDay.key(for: record.capturedAt)
        }
        var indexed: [UUID: Date?] = [:]
        for record in records { indexed[record.id] = record.metadataModifiedAt }
        let scan = await scanFolders(indexed: indexed)
        var byID: [UUID: SphereRecord] = [:]
        for record in records { byID[record.id] = record }
        for record in records where !scan.onDisk.contains(record.id) {
            context.delete(record)
        }
        for entry in scan.missingFromIndex {
            let record = SphereRecord(metadata: entry.sphere.metadata, fileSizeBytes: entry.fileSizeBytes)
            record.metadataModifiedAt = entry.sphere.metadataModifiedAt
            context.insert(record)
        }
        for sphere in scan.changed {
            byID[sphere.metadata.id]?.apply(sphere.metadata, modifiedAt: sphere.metadataModifiedAt)
        }

        // Trip names: the file wins when it exists; rows the file lacks go.
        if FileManager.default.fileExists(atPath: tripNamesFile.path) {
            let rows = (try? context.fetch(FetchDescriptor<TripRecord>())) ?? []
            var rowsByDay: [String: TripRecord] = [:]
            for row in rows { rowsByDay[row.dayKey] = row }
            for (day, name) in scan.tripNames {
                if let row = rowsByDay[day] {
                    if row.name != name { row.name = name }
                } else {
                    context.insert(TripRecord(dayKey: day, name: name))
                }
            }
            for row in rows where scan.tripNames[row.dayKey] == nil {
                context.delete(row)
            }
        }

        if await migrateThumbnailsIfNeeded() {
            ThumbnailRefresh.shared.bump()
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
        ThumbnailCache.shared.remove(id)
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
