import Foundation
import Observation
import os

/// Keeps the spheres folder in iCloud Drive when the account allows it
/// (spec 6.7, F17). On launch it looks for the app's ubiquity container,
/// moves any local spheres into it, points `SphereStore` at it, and watches
/// it with a metadata query so spheres kept on another device appear here:
/// their metadata and thumbnail are fetched straight away, the full image
/// when the sphere is opened. Every change triggers an index reconcile.
/// Without iCloud (no entitlement, no account, or Drive off) nothing changes
/// and the app keeps using Documents.
@Observable
final class SyncCoordinator: NSObject {
    enum State: Equatable {
        case starting
        case unavailable
        case syncing
    }

    static let shared = SyncCoordinator()
    private nonisolated static let log = Logger(subsystem: "com.chan31.surround", category: "sync")

    private(set) var state: State = .starting
    /// Bumped whenever the folder changed under us; the library reconciles on it.
    private(set) var changeCount = 0
    /// Files iCloud is still bringing down, for a status line.
    private(set) var pendingDownloads = 0

    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task {
            // The container lookup can block, so it stays off the main actor.
            guard let container = await Self.findContainer() else {
                state = .unavailable
                Self.log.notice("iCloud Drive unavailable; spheres stay in Documents")
                return
            }
            let root = container.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent("spheres", isDirectory: true)
            await Self.migrateLocalSpheres(to: root)
            SphereStore.useSyncedRoot(root)
            state = .syncing
            changeCount += 1
            Self.log.notice("Spheres folder is \(root.path, privacy: .public)")
            startQuery()
        }
    }

    @concurrent
    private static func findContainer() async -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)
    }

    /// Moves every sphere folder from Documents into the container. A folder
    /// that already exists there (this device ran the migration before, or the
    /// same sphere arrived from another device) is left alone.
    @concurrent
    private static func migrateLocalSpheres(to root: URL) async {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let local = SphereStore.localRoot
        guard let entries = try? fm.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let destination = root.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
            if fm.fileExists(atPath: destination.path) { continue }
            do {
                try fm.setUbiquitous(true, itemAt: entry, destinationURL: destination)
                log.notice("Moved \(entry.lastPathComponent, privacy: .public) into iCloud")
            } catch {
                log.error("Could not move \(entry.lastPathComponent, privacy: .public) into iCloud: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Watching

    private func startQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        query.notificationBatchingInterval = 1
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(queryUpdated(_:)), name: .NSMetadataQueryDidFinishGathering, object: query)
        center.addObserver(self, selector: #selector(queryUpdated(_:)), name: .NSMetadataQueryDidUpdate, object: query)
        self.query = query
        query.start()
    }

    @objc private func queryUpdated(_ note: Notification) {
        guard let query else { return }
        query.disableUpdates()
        var pending = 0
        for case let item as NSMetadataItem in query.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            let name = url.lastPathComponent
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let downloaded = status == NSMetadataUbiquitousItemDownloadingStatusCurrent || status == NSMetadataUbiquitousItemDownloadingStatusDownloaded
            if downloaded { continue }
            // Small files first so the library fills in; images and shots wait
            // until they are needed.
            if name == "metadata.json" || name == "thumb.jpg" || name == "trips.json" {
                pending += 1
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
        query.enableUpdates()
        pendingDownloads = pending
        changeCount += 1
    }
}
