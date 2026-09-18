import Foundation
import Observation

/// What the viewer's overlay needs from the sphere view: where the user is
/// looking relative to the sphere's front, and a way to recentre.
@Observable
final class ViewerState {
    /// Yaw of the view direction relative to the sphere's front, compass
    /// sense (positive when looking to the right of the front), in (-180, 180].
    private(set) var viewYawDegrees: Float = 0
    private(set) var fieldOfViewDegrees: Float = 75
    /// Compass heading of the sphere's front, when it was recorded.
    var frontHeadingDegrees: Double?

    @ObservationIgnored var recentreAction: (() -> Void)?

    init(frontHeadingDegrees: Double? = nil) {
        self.frontHeadingDegrees = frontHeadingDegrees
    }

    /// Called by the sphere view at up to 60 Hz; only publishes visible changes.
    func report(viewYawDegrees yaw: Float, fieldOfViewDegrees fov: Float) {
        if abs(yaw - viewYawDegrees) >= 0.5 || abs(yaw - viewYawDegrees) > 180 {
            viewYawDegrees = yaw
        }
        if abs(fov - fieldOfViewDegrees) >= 0.5 {
            fieldOfViewDegrees = fov
        }
    }

    /// Faces the sphere's front again, at the default zoom.
    func recentre() {
        recentreAction?()
    }
}
