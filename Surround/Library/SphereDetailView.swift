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
    @State private var isDownloading = false
    @State private var downloadFailed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                SphereViewer(image: image, frontHeadingDegrees: sphere.frontHeadingDegrees)
            } else if downloadFailed {
                ContentUnavailableView {
                    Label("Still in iCloud", systemImage: "icloud.slash")
                } description: {
                    Text("This sphere has not finished downloading. Check the connection and try again.")
                } actions: {
                    Button("Try again") {
                        downloadFailed = false
                        Task { await load() }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    if isDownloading {
                        Text("Downloading from iCloud")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
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
        let imageURL = SphereStore.files(for: id).image
        // A sphere kept on another device arrives here as metadata and
        // thumbnail first; the full image is fetched when it is opened.
        if !SphereStore.isDownloaded(imageURL) {
            isDownloading = true
            let arrived = (try? await SphereStore.ensureDownloaded(imageURL)) ?? false
            isDownloading = false
            if !arrived {
                downloadFailed = true
                return
            }
        }
        let loaded = await Self.loadFiles(id: id, path: imageURL.path)
        image = loaded.0
        exportURL = loaded.1
    }

    @concurrent
    private nonisolated static func loadFiles(id: UUID, path: String) async -> (UIImage?, URL?) {
        let img = UIImage(contentsOfFile: path)
        let url = try? SphereStore.exportJPEG(id: id)
        return (img, url)
    }
}

private struct SphereInfoView: View {
    let sphere: SphereRecord
    // Optional: the review screen has no library behind it.
    @Environment(LibraryNavigation.self) private var navigation: LibraryNavigation?
    @Environment(\.dismiss) private var dismiss
    @Query private var allSpheres: [SphereRecord]
    @State private var title: String
    @State private var tagsText: String
    @State private var saveError: String?

    init(sphere: SphereRecord) {
        self.sphere = sphere
        _title = State(initialValue: sphere.title)
        _tagsText = State(initialValue: sphere.tags.joined(separator: ", "))
    }

    /// Tags used anywhere in the library that this sphere does not have yet.
    private var suggestedTags: [String] {
        let current = Set(currentTags.map { $0.lowercased() })
        var counts: [String: Int] = [:]
        for s in allSpheres { for t in s.tags { counts[t, default: 0] += 1 } }
        return counts.keys
            .filter { !current.contains($0.lowercased()) }
            .sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
            .prefix(8)
            .map { $0 }
    }

    private var currentTags: [String] {
        tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func save() {
        do {
            try sphere.setTitle(title)
            try sphere.setTags(currentTags)
        } catch {
            saveError = error.localizedDescription
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name this sphere", text: $title)
                        .submitLabel(.done)
                        .onSubmit(save)
                    TextField("Tags, separated by commas", text: $tagsText)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit(save)
                    if !suggestedTags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(suggestedTags, id: \.self) { tag in
                                    Button(tag) {
                                        tagsText = (currentTags + [tag]).joined(separator: ", ")
                                        save()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                } footer: {
                    Text("Search finds spheres by title, tag and trip name.")
                }
                Section {
                    if let lat = sphere.latitude, let lon = sphere.longitude {
                        Button {
                            dismiss()
                            navigation?.showOnMap(sphere.id)
                        } label: {
                            SphereMapSnippet(id: sphere.id, latitude: lat, longitude: lon, headingDegrees: sphere.frontHeadingDegrees)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                        .disabled(navigation == nil)
                        .accessibilityLabel("Show on map")
                        if sphere.isManualPosition {
                            Label("Position placed by hand", systemImage: "hand.point.up.left")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Label("No position recorded. Long-press the map to place this sphere.", systemImage: "mappin.slash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
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
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear(perform: save)
            .alert("Could not save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }
}
