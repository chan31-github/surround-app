import CoreLocation
import SwiftData
import SwiftUI
import SurroundCore
import UIKit

enum LibraryMode: String {
    case list
    case map
}

/// What the list and the map show: everything, one trip, or the spheres
/// that still need a position (spec 6.6, "unplaced").
enum LibraryFilter: Hashable {
    case all
    case trip(String)
    case unplaced
}

/// The library as a grid or a map, with one trip filter shared by both
/// (spec 6.6: the map is a toggle in the library, not a separate tab).
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SphereRecord.capturedAt, order: .reverse) private var spheres: [SphereRecord]
    @Query private var tripNames: [TripRecord]
    @AppStorage("library.mode") private var modeRaw = LibraryMode.list.rawValue
    @AppStorage("library.satellite") private var satellite = false
    @State private var filter: LibraryFilter = .all
    @State private var path = NavigationPath()
    @State private var showCapture = false
    @State private var renamingTrip: String?
    @State private var renameText = ""
    @State private var clusterSelection: ClusterSelection?
    @State private var placement: PlacementRequest?
    @State private var placementError: String?
    @State private var navigation = LibraryNavigation()
    @State private var mapFocus: MapFocus?

    private var mode: Binding<LibraryMode> {
        Binding(get: { LibraryMode(rawValue: modeRaw) ?? .list }, set: { modeRaw = $0.rawValue })
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(title)
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
                    await SphereStore.reconcileIndex(in: context)
                }
                .onChange(of: navigation.focus) { _, focus in
                    guard let focus else { return }
                    Task {
                        // Let the info sheet finish dismissing before the stack pops.
                        try? await Task.sleep(for: .milliseconds(350))
                        path = NavigationPath()
                        if case .unplaced = filter { filter = .all }
                        modeRaw = LibraryMode.map.rawValue
                        mapFocus = focus
                    }
                }
                .sheet(item: $placement) { request in
                    PlacementSheet(request: request,
                                   candidates: placementCandidates,
                                   tripName: tripName) { sphere in
                        place(sphere, at: request)
                    }
                    .presentationDetents([.medium, .large])
                }
                .alert("Could not save the position", isPresented: Binding(get: { placementError != nil }, set: { if !$0 { placementError = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(placementError ?? "")
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
        // On the stack itself so pushed screens and their sheets see it too.
        .environment(navigation)
    }

    // MARK: Filter and trips

    private var title: String {
        switch filter {
        case .all: return "Surround"
        case .trip(let day): return tripName(day)
        case .unplaced: return "Without a position"
        }
    }

    private var unplacedSpheres: [SphereRecord] {
        spheres.filter { $0.latitude == nil || $0.longitude == nil }
    }

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
        switch filter {
        case .all: return spheres
        case .trip(let day): return spheres.filter { TripDay.key(for: $0.capturedAt) == day }
        case .unplaced: return unplacedSpheres
        }
    }

    private var tripMenu: some View {
        Menu {
            Picker("Filter", selection: $filter) {
                Text("All spheres").tag(LibraryFilter.all)
                if !unplacedSpheres.isEmpty {
                    Text("Without a position (\(unplacedSpheres.count))").tag(LibraryFilter.unplaced)
                }
            }
            Picker("Trip", selection: $filter) {
                ForEach(tripDays, id: \.self) { day in
                    Text(tripName(day)).tag(LibraryFilter.trip(day))
                }
            }
            if case .trip(let day) = filter {
                Divider()
                Button("Rename trip", systemImage: "pencil") {
                    renameText = tripNames.first(where: { $0.dayKey == day })?.name ?? ""
                    renamingTrip = day
                }
            }
        } label: {
            Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .disabled(spheres.isEmpty)
    }

    // MARK: Placement

    /// Spheres a long press can place: those without a position, and those
    /// placed by hand before, so a wrong guess can be corrected.
    private var placementCandidates: [SphereRecord] {
        spheres.filter { $0.latitude == nil || $0.longitude == nil || $0.isManualPosition }
    }

    private func place(_ sphere: SphereRecord, at request: PlacementRequest) {
        do {
            try sphere.setManualPosition(latitude: request.latitude, longitude: request.longitude)
            placement = nil
            if case .unplaced = filter, unplacedSpheres.isEmpty { filter = .all }
        } catch {
            placementError = error.localizedDescription
        }
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
        return SphereMapView(spheres: placed,
                             paths: tripPaths,
                             satellite: satellite,
                             pendingDrop: placement.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                             focus: mapFocus,
                             onOpen: { id in
                                 if let sphere = spheres.first(where: { $0.id == id }) {
                                     path.append(sphere)
                                 }
                             },
                             onSelectCluster: { ids in
                                 let members = spheres.filter { ids.contains($0.id) }
                                 if !members.isEmpty {
                                     clusterSelection = ClusterSelection(spheres: members)
                                 }
                             },
                             onLongPress: { coordinate in
                                 guard !placementCandidates.isEmpty else { return }
                                 placement = PlacementRequest(latitude: coordinate.latitude, longitude: coordinate.longitude)
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
            if case .unplaced = filter {
                Text("Long-press the map where a sphere was taken to place it.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
                    .padding(.horizontal, 60)
            } else if unplaced > 0 {
                Button {
                    filter = .unplaced
                } label: {
                    Text(unplaced == 1 ? "1 sphere has no position" : "\(unplaced) spheres have no position")
                        .font(.footnote)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
        }
    }

    /// One dashed line per trip in the current filter, through its placed
    /// spheres in capture order, when there are at least two.
    private var tripPaths: [MapPath] {
        let placed = filtered.filter { $0.latitude != nil && $0.longitude != nil }
        let byTrip = Dictionary(grouping: placed) { TripDay.key(for: $0.capturedAt) }
        return byTrip.compactMap { day, members -> MapPath? in
            guard members.count >= 2 else { return nil }
            let ordered = members.sorted { $0.capturedAt < $1.capturedAt }
            return MapPath(id: day, coordinates: ordered.map { [$0.latitude!, $0.longitude!] })
        }
        .sorted { $0.id < $1.id }
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
            SphereThumbnail(id: sphere.id)
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

/// Where a long press landed, waiting for the user to say which sphere goes there.
struct PlacementRequest: Identifiable {
    let id = UUID()
    let latitude: Double
    let longitude: Double
}

/// Picks the sphere to place at a long-pressed spot (spec 6.6, manual pins).
private struct PlacementSheet: View {
    let request: PlacementRequest
    let candidates: [SphereRecord]
    let tripName: (String) -> String
    let onPlace: (SphereRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    private var unplaced: [SphereRecord] { candidates.filter { $0.latitude == nil || $0.longitude == nil } }
    private var movable: [SphereRecord] { candidates.filter { $0.latitude != nil && $0.longitude != nil } }

    var body: some View {
        NavigationStack {
            List {
                if !unplaced.isEmpty {
                    Section("Place here") {
                        ForEach(unplaced) { sphere in
                            row(sphere)
                        }
                    }
                }
                if !movable.isEmpty {
                    Section("Move here (placed by hand before)") {
                        ForEach(movable) { sphere in
                            row(sphere)
                        }
                    }
                }
            }
            .navigationTitle("Place a sphere")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(_ sphere: SphereRecord) -> some View {
        Button {
            onPlace(sphere)
        } label: {
            HStack(spacing: 12) {
                SphereThumbnail(id: sphere.id)
                    .frame(width: 88, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(sphere.title.isEmpty ? sphere.capturedAt.formatted(date: .abbreviated, time: .shortened) : sphere.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(tripName(TripDay.key(for: sphere.capturedAt)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
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
                        SphereThumbnail(id: sphere.id)
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
