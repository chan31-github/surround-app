import Foundation
import SwiftData
import SurroundCore

/// Index row for one stored sphere. The files in the sphere's folder are the
/// source of truth; this exists so the library can query without reading them.
@Model
final class SphereRecord {
    @Attribute(.unique) var id: UUID
    var capturedAt: Date
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
