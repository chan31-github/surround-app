import SwiftUI
import UIKit

/// The sphere view with its overlay: a compass rose that shows the current
/// view direction against the recorded front and recentres on tap.
struct SphereViewer: View {
    let image: UIImage
    let frontHeadingDegrees: Double?
    @State private var state: ViewerState

    init(image: UIImage, frontHeadingDegrees: Double?) {
        self.image = image
        self.frontHeadingDegrees = frontHeadingDegrees
        _state = State(initialValue: ViewerState(frontHeadingDegrees: frontHeadingDegrees))
    }

    var body: some View {
        SphereViewerView(image: image, state: state)
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                CompassRose(state: state)
                    .padding(.trailing, 16)
                    .padding(.top, 8)
            }
            .onChange(of: frontHeadingDegrees) { _, heading in
                state.frontHeadingDegrees = heading
            }
    }
}
