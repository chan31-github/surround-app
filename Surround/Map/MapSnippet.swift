import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// A static map of where a sphere was taken, with its pin and heading wedge,
/// for the detail view's info sheet. Rendered once per position and cached.
struct SphereMapSnippet: View {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let headingDegrees: Double?
    var height: CGFloat = 150

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.secondary.opacity(0.15)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .task(id: "\(latitude),\(longitude),\(Int(geo.size.width)),\(colorScheme)") {
                image = await MapSnippetRenderer.image(id: id, latitude: latitude, longitude: longitude,
                                                       headingDegrees: headingDegrees,
                                                       size: CGSize(width: geo.size.width, height: height),
                                                       dark: colorScheme == .dark)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

enum MapSnippetRenderer {
    private static var cacheDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("map-snippets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func image(id: UUID, latitude: Double, longitude: Double, headingDegrees: Double?,
                      size: CGSize, dark: Bool) async -> UIImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let name = String(format: "%@-%.5f-%.5f-%.0f-%dx%d-%@.png", id.uuidString, latitude, longitude,
                          headingDegrees ?? -1, Int(size.width), Int(size.height), dark ? "dark" : "light")
        let file = cacheDirectory.appendingPathComponent(name)
        if let cached = UIImage(contentsOfFile: file.path) { return cached }

        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: coordinate,
                                            latitudinalMeters: 700,
                                            longitudinalMeters: 700 * size.width / size.height)
        options.size = size
        options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
        let scale = UITraitCollection.current.displayScale
        options.traitCollection = UITraitCollection { traits in
            traits.userInterfaceStyle = dark ? .dark : .light
            traits.displayScale = scale
        }
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        let point = snapshot.point(for: coordinate)
        let rendered = UIGraphicsImageRenderer(size: size).image { ctx in
            snapshot.image.draw(at: .zero)
            let cg = ctx.cgContext
            if let heading = headingDegrees {
                let radius: CGFloat = 26
                let angle = CGFloat(heading) * .pi / 180 - .pi / 2
                cg.move(to: point)
                cg.addArc(center: point, radius: radius, startAngle: angle - 0.42, endAngle: angle + 0.42, clockwise: false)
                cg.closePath()
                cg.setFillColor(UIColor.systemBlue.withAlphaComponent(0.75).cgColor)
                cg.fillPath()
            }
            let circle = CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)
            cg.setFillColor(UIColor.systemBlue.cgColor)
            cg.fillEllipse(in: circle)
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(2.5)
            cg.strokeEllipse(in: circle)
        }
        try? rendered.pngData()?.write(to: file, options: .atomic)
        return rendered
    }
}
