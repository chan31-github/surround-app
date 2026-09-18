import SwiftData
import SwiftUI
import SurroundCore
import UIKit

enum LibraryMode: String {
    case list
    case map
}

/// The library as a grid or a map, with one trip filter shared by both
/// (spec 6.6: the map is a toggle in the library, not a separate tab).
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SphereRecord.capturedAt, order: .reverse) private var spheres: [SphereRecord]
    @Query private var tripNames: [TripRecord]
    @AppStorage("library.mode") private var modeRaw = LibraryMode.list.rawValue
    @AppStorage("library.satellite") private var satellite = false
    @State private var selectedTrip: String?
    @State private var path = NavigationPath()
    @State private var showCapture = false
    @State private var renamingTrip: String?
    @State private var renameText = ""
    @State private var clusterSelection: ClusterSelection?

    private var mode: Binding<LibraryMode> {
        Binding(get: { LibraryMode(rawValue: modeRaw) ?? .list }, set: { modeRaw = $0.rawValue })
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(selectedTrip.map(tripName) ?? "Surround")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: SphereRecord.self) { sphere in
                    SphereDetailView(sphere: sphere)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        tripMenu
                    }
                    ToolbarItem(placement: .principal) {
                        Picker("View", selection: mode) {
                            Image(systemName: "square.grid.2x2").tag(LibraryMode.list)
                            Image(systemName: "map").tag(LibraryMode.map)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                    }
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
                .task {
                    SphereStore.reconcileIndex(in: context)
                }
                .sheet(item: $clusterSelection) { selection in
                    ClusterListView(spheres: selection.spheres, tripName: tripName) { sphere in
                        clusterSelection = nil
                        path.append(sphere)
                    }
                    .presentationDetents([.medium, .large])
                }
                .alert("Rename trip", isPresented: Binding(get: { renamingTrip != nil }, set: { if !$0 { renamingTrip = nil } })) {
                    TextField("Trip name", text: $renameText)
                    Button("Save") { saveRename() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Leave the name empty to show the date again.")
                }
        }
    }

    // MARK: Trips

    /// Day keys of every trip, newest first.
    private var tripDays: [String] {
        Array(Set(spheres.map { TripDay.key(for: $0.capturedAt) })).sorted(by: >)
    }

    private func tripName(_ day: String) -> String {
        if let named = tripNames.first(where: { $0.dayKey == day }), !named.name.isEmpty {
            return named.name
        }
        return tripDate(day)
    }

    private func tripDate(_ day: String) -> String {
        guard let date = TripDay.start(ofKey: day) else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }

    private var filtered: [SphereRecord] {
        guard let selectedTrip else { return spheres }
        return spheres.filter { TripDay.key(for: $0.capturedAt) == selectedTrip }
    }

    private var tripMenu: some View {
        Menu {
            Picker("Trip", selection: $selectedTrip) {
                Text("All spheres").tag(String?.none)
                ForEach(tripDays, id: \.self) { day in
                    Text(tripName(day)).tag(String?.some(day))
                }
            }
            if let selectedTrip {
                Divider()
                Button("Rename trip", systemImage: "pencil") {
                    renameText = tripNames.first(where: { $0.dayKey == selectedTrip })?.name ?? ""
                    renamingTrip = selectedTrip
                }
            }
        } label: {
            Label("Trips", systemImage: selectedTrip == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .disabled(spheres.isEmpty)
    }

    private func saveRename() {
        guard let day = renamingTrip else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = tripNames.first(where: { $0.dayKey == day }) {
            if name.isEmpty {
                context.delete(existing)
            } else {
                existing.name = name
            }
        } else if !name.isEmpty {
            context.insert(TripRecord(dayKey: day, name: name))
        }
        renamingTrip = nil
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if spheres.isEmpty {
            ContentUnavailableView {
                Label("No spheres yet", systemImage: "globe")
            } description: {
                Text("Tap + at a viewpoint to capture your first one.")
            }
        } else if mode.wrappedValue == .map {
            mapContent
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(filtered) { sphere in
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

    private var mapContent: some View {
        let placed = filtered.compactMap(mapSphere)
        let unplaced = filtered.count - placed.count
        return SphereMapView(spheres: placed, satellite: satellite, onOpen: { id in
            if let sphere = spheres.first(where: { $0.id == id }) {
                path.append(sphere)
            }
        }, onSelectCluster: { ids in
            let members = spheres.filter { ids.contains($0.id) }
            if !members.isEmpty {
                clusterSelection = ClusterSelection(spheres: members)
            }
        })
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .topTrailing) {
            Button {
                satellite.toggle()
            } label: {
                Image(systemName: satellite ? "map" : "globe.americas")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel(satellite ? "Standard map" : "Satellite")
            .padding(12)
        }
        .overlay(alignment: .top) {
            if unplaced > 0 {
                Text(unplaced == 1 ? "1 sphere has no position" : "\(unplaced) spheres have no position")
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
            }
        }
    }

    private func mapSphere(_ sphere: SphereRecord) -> MapSphere? {
        guard let lat = sphere.latitude, let lon = sphere.longitude else { return nil }
        let day = TripDay.key(for: sphere.capturedAt)
        var details: [String] = []
        if let altitude = sphere.altitudeMetres {
            details.append(String(format: "%.0f m", altitude))
        }
        details.append(tripName(day))
        return MapSphere(id: sphere.id,
                         latitude: lat,
                         longitude: lon,
                         headingDegrees: sphere.frontHeadingDegrees,
                         isLowAccuracy: (sphere.horizontalAccuracyMetres ?? 0) > 100,
                         title: sphere.title.isEmpty ? sphere.capturedAt.formatted(date: .abbreviated, time: .shortened) : sphere.title,
                         subtitle: details.joined(separator: " · "),
                         tripKey: day,
                         tripName: tripName(day))
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

/// The members of a tapped cluster, for the picker sheet.
struct ClusterSelection: Identifiable {
    let id = UUID()
    let spheres: [SphereRecord]
}

/// Picker for spheres that share a spot: what the map shows when zooming in
/// would not separate a cluster.
private struct ClusterListView: View {
    let spheres: [SphereRecord]
    let tripName: (String) -> String
    let onOpen: (SphereRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(spheres) { sphere in
                Button {
                    onOpen(sphere)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Color.secondary.opacity(0.2)
                            if let thumb = UIImage(contentsOfFile: SphereStore.files(for: sphere.id).thumbnail.path) {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .scaledToFill()
                            }
                        }
                        .frame(width: 88, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sphere.title.isEmpty ? sphere.capturedAt.formatted(date: .abbreviated, time: .shortened) : sphere.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(subtitle(for: sphere))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(spheres.count == 1 ? "1 sphere here" : "\(spheres.count) spheres here")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func subtitle(for sphere: SphereRecord) -> String {
        var parts = [tripName(TripDay.key(for: sphere.capturedAt))]
        if !sphere.title.isEmpty {
            parts.append(sphere.capturedAt.formatted(date: .omitted, time: .shortened))
        }
        if let altitude = sphere.altitudeMetres {
            parts.append(String(format: "%.0f m", altitude))
        }
        return parts.joined(separator: " · ")
    }
}
