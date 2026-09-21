import Foundation
import Observation

/// Progress of the one-time still re-encode, for the library's menu.
@Observable
final class StorageStatus {
    static let shared = StorageStatus()
    private(set) var migrating: (done: Int, total: Int)?
    private(set) var reclaimedBytes = 0

    func update(done: Int, total: Int) {
        migrating = done < total ? (done, total) : nil
    }

    func finished(reclaimed: Int) {
        migrating = nil
        reclaimedBytes = reclaimed
    }
}
