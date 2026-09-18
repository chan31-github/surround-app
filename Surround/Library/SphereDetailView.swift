import SwiftData
import SwiftUI
import UIKit

struct SphereDetailView: View {
    let sphere: SphereRecord

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var exportURL: URL?
    @State private var showInfo = false
    @State private var confirmDelete = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                SphereViewer(image: image, frontHeadingDegrees: sphere.frontHeadingDegrees)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let exportURL {
                    ShareLink(item: exportURL)
                }
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialog("Delete this sphere?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                SphereStore.delete(id: sphere.id)
                context.delete(sphere)
                dismiss()
            }
        }
        .sheet(isPresented: $showInfo) {
            SphereInfoView(sphere: sphere)
                .presentationDetents([.medium])
        }
        .task {
            await load()
        }
    }

    private var title: String {
        sphere.title.isEmpty ? sphere.capturedAt.formatted(date: .abbreviated, time: .shortened) : sphere.title
    }

    private func load() async {
        let id = sphere.id
        let path = SphereStore.files(for: id).image.path
        let loaded = await Task.detached(priority: .userInitiated) { () -> (UIImage?, URL?) in
            let img = UIImage(contentsOfFile: path)
            let url = try? SphereStore.exportJPEG(id: id)
            return (img, url)
        }.value
        image = loaded.0
        exportURL = loaded.1
    }
}

private struct SphereInfoView: View {
    let sphere: SphereRecord

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Captured", value: sphere.capturedAt.formatted(date: .long, time: .shortened))
                LabeledContent("Shots", value: "\(sphere.shotCount)")
                if let lat = sphere.latitude, let lon = sphere.longitude {
                    LabeledContent("Position", value: String(format: "%.5f, %.5f", lat, lon))
                }
                if let alt = sphere.altitudeMetres {
                    LabeledContent("Altitude", value: String(format: "%.0f m", alt))
                }
                if let heading = sphere.frontHeadingDegrees {
                    LabeledContent("Front heading", value: String(format: "%.0f°", heading))
                }
                if let lo = sphere.coveredPitchMinDegrees, let hi = sphere.coveredPitchMaxDegrees {
                    LabeledContent("Covered pitch", value: String(format: "%.0f° to %.0f°", lo, hi))
                }
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(sphere.fileSizeBytes), countStyle: .file))
                if !sphere.tags.isEmpty {
                    LabeledContent("Tags", value: sphere.tags.joined(separator: ", "))
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
