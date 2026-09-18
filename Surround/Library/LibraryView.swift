import SwiftData
import SwiftUI
import UIKit

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SphereRecord.capturedAt, order: .reverse) private var spheres: [SphereRecord]
    @State private var showCapture = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Surround")
                .navigationDestination(for: SphereRecord.self) { sphere in
                    SphereDetailView(sphere: sphere)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showCapture = true
                        } label: {
                            Label("Capture", systemImage: "plus")
                        }
                    }
                }
                .fullScreenCover(isPresented: $showCapture) {
                    CaptureView()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if spheres.isEmpty {
            ContentUnavailableView {
                Label("No spheres yet", systemImage: "globe")
            } description: {
                Text("Tap + at a viewpoint to capture your first one.")
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(spheres) { sphere in
                        NavigationLink(value: sphere) {
                            SphereCard(sphere: sphere)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                delete(sphere)
                            }
                        }
                    }
                }
                .padding()
            }
        }
    }

    private func delete(_ sphere: SphereRecord) {
        SphereStore.delete(id: sphere.id)
        context.delete(sphere)
    }
}

private struct SphereCard: View {
    let sphere: SphereRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.secondary.opacity(0.2)
                if let thumb = UIImage(contentsOfFile: SphereStore.files(for: sphere.id).thumbnail.path) {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                }
            }
            .aspectRatio(2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(sphere.title.isEmpty ? sphere.capturedAt.formatted(date: .abbreviated, time: .shortened) : sphere.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text("\(sphere.shotCount) shots")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
