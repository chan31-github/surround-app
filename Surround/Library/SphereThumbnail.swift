import SwiftUI
import UIKit

/// A sphere's thumbnail from the shared cache: a cache hit shows at once,
/// otherwise a placeholder while it decodes off the main actor.
struct SphereThumbnail: View {
    let id: UUID
    var variant: ThumbnailCache.Variant = .card
    @State private var image: UIImage?

    init(id: UUID, variant: ThumbnailCache.Variant = .card) {
        self.id = id
        self.variant = variant
        _image = State(initialValue: ThumbnailCache.shared.cached(id, variant))
    }

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.2)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: id) {
            if image == nil {
                image = await ThumbnailCache.shared.load(id, variant)
            }
        }
    }
}
