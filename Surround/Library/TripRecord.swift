import Foundation
import SwiftData

/// A trip is a calendar day (see `TripDay`); this row exists only when the
/// user has given that day a name. Days without a row show their date.
@Model
final class TripRecord {
    @Attribute(.unique) var dayKey: String
    var name: String

    init(dayKey: String, name: String) {
        self.dayKey = dayKey
        self.name = name
    }
}
