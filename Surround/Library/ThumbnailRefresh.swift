import Foundation
import Observation

/// Bumped when thumbnails on disk change under views that already show them,
/// such as after a one-time regeneration, so they reload.
@Observable
final class ThumbnailRefresh {
    static let shared = ThumbnailRefresh()
    private(set) var generation = 0

    func bump() {
        generation += 1
    }
}
