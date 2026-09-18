import Foundation
import Observation

/// Requests from deeper screens that the library must carry out, such as
/// "show this sphere on the map" from the detail view's info sheet.
@Observable
final class LibraryNavigation {
    private(set) var focus: MapFocus?

    func showOnMap(_ id: UUID) {
        focus = MapFocus(id: id, token: UUID())
    }
}
