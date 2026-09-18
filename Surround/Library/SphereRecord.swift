import Foundation
import SwiftData
import SurroundCore

/// Index row for one stored sphere. The files in the sphere's folder are the
/// source of truth; this exists so the library can query without reading them.
@Model
final class SphereRecord {
    @Attribute(.unique) var id: UUID
    var capturedAt: Date
    /// Calendar day of capture, "yyyy-MM-dd" in the local time zone (F9).
    /// Stored so trips are a field the store can filter and sort on.
    var tripDayKey: String = ""
    var title: String
    var latitude: Double?
    var longitude: Double?
    var altitudeMetres: Double?
    var horizontalAccuracyMetres: Double?
    var isManualPosition: Bool = false
    var frontHeadingDegrees: Double?
    var coveredPitchMinDegrees: Double?
    var coveredPitchMaxDegrees: Double?
    var shotCount: Int
    var fileSizeBytes: Int
    var tags: [String]

    init(metadata: SphereMetadata, fileSizeBytes: Int) {
        id = metadata.id
        capturedAt = metadata.capturedAt
        tripDayKey = TripDay.key(for: metadata.capturedAt)
        title = metadata.title
        latitude = metadata.latitude
        longitude = metadata.longitude
        altitudeMetres = metadata.altitudeMetres
        horizontalAccuracyMetres = metadata.horizontalAccuracyMetres
        isManualPosition = metadata.isManualPosition
        frontHeadingDegrees = metadata.frontHeadingDegrees
        coveredPitchMinDegrees = metadata.coveredPitchMinDegrees.map(Double.init)
        coveredPitchMaxDegrees = metadata.coveredPitchMaxDegrees.map(Double.init)
        shotCount = metadata.shotCount
        self.fileSizeBytes = fileSizeBytes
        tags = metadata.tags
    }

    /// Renames the sphere, in the file first and then in this row.
    func setTitle(_ newTitle: String) throws {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != title else { return }
        try SphereStore.updateMetadata(id: id) { $0.title = trimmed }
        title = trimmed
    }

    /// Replaces the tags, in the file first and then in this row.
    func setTags(_ newTags: [String]) throws {
        let cleaned = newTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var unique: [String] = []
        for tag in cleaned where !unique.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            unique.append(tag)
        }
        guard unique != tags else { return }
        try SphereStore.updateMetadata(id: id) { $0.tags = unique }
        tags = unique
    }

    /// Records a position the user chose on the map, in the file first and
    /// then in this row.
    func setManualPosition(latitude: Double, longitude: Double) throws {
        try SphereStore.updateMetadata(id: id) { meta in
            meta.latitude = latitude
            meta.longitude = longitude
            meta.horizontalAccuracyMetres = nil
            meta.isManualPosition = true
        }
        self.latitude = latitude
        self.longitude = longitude
        horizontalAccuracyMetres = nil
        isManualPosition = true
    }
}
