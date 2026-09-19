import SwiftUI
import UIKit

/// A sphere's thumbnail from the shared cache: a cache hit shows at once,
/// otherwise a placeholder while it decodes off the main actor. Reloads when
/// thumbnails are regenerated.
struct SphereThumbnail: View {
    let id: UUID
    var variant: ThumbnailCache.Variant = .card
    @State private var image: UIImage?

    init(id: UUID, variant: ThumbnailCache.Variant = .card) {
        self.id = id
        self.variant = variant
        _image = State(initialValue: ThumbnailCache.shared.cached(id, variant))
    }

    private struct Key: Equatable {
        let id: UUID
        let generation: Int
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
        .task(id: Key(id: id, generation: ThumbnailRefresh.shared.generation)) {
            if let cached = ThumbnailCache.shared.cached(id, variant) {
                image = cached
            } else {
                image = await ThumbnailCache.shared.load(id, variant)
            }
        }
    }
}
