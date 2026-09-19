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
/// that still need a position (spec 6.6, "unplaced"). Search narrows any of them.
enum LibraryFilter: Hashable {
    case all
    case trip(String)
    case unplaced
}

/// The spheres of one trip, for the sectioned list.
struct TripSection: Identifiable {
    let day: String
    let spheres: [SphereRecord]
    var id: String { day }
}

/// The library as a trip-sectioned grid or a map, with one filter and one
/// search shared by both (spec 6.6: the map is a toggle in the library).
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SphereRecord.capturedAt, order: .reverse) private var spheres: [SphereRecord]
    @Query private var tripNames: [TripRecord]
    @AppStorage("library.mode") private var modeRaw = LibraryMode.list.rawValue
    @AppStorage("library.satellite") private var satellite = false
    @State private var filter: LibraryFilter = .all
    @State private var query = ""
    @State private var path = NavigationPath()
    @State private var showCapture = false
    @State private var showTrips = false
    @State private var renamingTrip: String?
    @State private var renameText = ""
    @State private var clusterSelection: ClusterSelection?
    @State private var placement: PlacementRequest?
    @State private var placementError: String?
    @State private var navigation = LibraryNavigation()
    @State private var mapFocus: MapFocus?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    private var mode: Binding<LibraryMode> {
        Binding(get: { LibraryMode(rawValue: modeRaw) ?? .list }, set: { modeRaw = $0.rawValue })
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            // iPad, and the largest iPhones in landscape: trips in the sidebar,
            // the library beside them (spec 6.7).
            NavigationSplitView(columnVisibility: $columnVisibility) {
                TripSidebar(trips: tripSummaries,
                            unplacedCount: unplacedSpheres.count,
                            selection: Binding(get: { filter }, set: { filter = $0 ?? .all }),
                            tripName: tripName,
                            onRename: { day in
                                renameText = namesByDay[day] ?? ""
                                renamingTrip = day
                            })
                    .navigationTitle("Surround")
            } detail: {
                libraryStack
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            libraryStack
        }
    }

    private var libraryStack: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarTitleDisplayMode(.inline)
                .navigationDestination(for: SphereRecord.self) { sphere in
                    SphereDetailView(sphere: sphere)
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Title, tag or trip")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        filterMenu
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
                    SyncCoordinator.shared.start()
                    await SphereStore.reconcileIndex(in: context)
                }
                .task(id: SyncCoordinator.shared.changeCount) {
                    // Spheres arriving from another device, or edits to them.
                    await SphereStore.reconcileIndex(in: context)
                    ThumbnailRefresh.shared.bump()
                }
                .onChange(of: navigation.focus) { _, focus in
                    guard let focus else { return }
                    Task {
                        // Let the info sheet finish dismissing before the stack pops.
                        try? await Task.sleep(for: .milliseconds(350))
                        path = NavigationPath()
                        if case .unplaced = filter { filter = .all }
                        query = ""
                        modeRaw = LibraryMode.map.rawValue
                        mapFocus = focus
                    }
                }
                .sheet(isPresented: $showTrips) {
                    TripsView(trips: tripSummaries,
                              selected: selectedTripDay,
                              onSelect: { day in filter = day.map { .trip($0) } ?? .all },
                              onRename: { day, name in rename(day, to: name) })
                }
                .sheet(item: $placement) { request in
                    PlacementSheet(request: request,
                                   candidates: placementCandidates,
                                   tripName: tripName) { sphere in
                        place(sphere, at: request)
                    }
                    .presentationDetents([.medium, .large])
                }
                .sheet(item: $clusterSelection) { selection in
                    ClusterListView(spheres: selection.spheres, tripName: tripName) { sphere in
                        clusterSelection = nil
                        path.append(sphere)
                    }
                    .presentationDetents([.medium, .large])
                }
                .alert("Could not save the position", isPresented: Binding(get: { placementError != nil }, set: { if !$0 { placementError = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(placementError ?? "")
                }
                .alert("Rename trip", isPresented: Binding(get: { renamingTrip != nil }, set: { if !$0 { renamingTrip = nil } })) {
                    TextField("Trip name", text: $renameText)
                    Button("Save") {
                        if let day = renamingTrip { rename(day, to: renameText) }
                        renamingTrip = nil
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Leave the name empty to show the date again.")
                }
        }
        // On the stack itself so pushed screens and their sheets see it too.
        .environment(navigation)
    }

    // MARK: Trips and filter

    private var title: String {
        switch filter {
        case .all: return "Surround"
        case .trip(let day): return tripName(day)
        case .unplaced: return "Without a position"
        }
    }

    private var selectedTripDay: String? {
        if case .trip(let day) = filter { return day }
        return nil
    }

    private var namesByDay: [String: String] {
        Dictionary(tripNames.map { ($0.dayKey, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private func tripName(_ day: String) -> String {
        if let named = namesByDay[day], !named.isEmpty { return named }
        return TripSummary(day: day, name: nil, count: 0, placedCount: 0, coverSphere: UUID()).dateText
    }

    /// Every trip in the library, newest first, regardless of filter or search.
    private var tripSummaries: [TripSummary] {
        let names = namesByDay
        var order: [String] = []
        var members: [String: [SphereRecord]] = [:]
        for sphere in spheres {
            if members[sphere.tripDayKey] == nil { order.append(sphere.tripDayKey) }
            members[sphere.tripDayKey, default: []].append(sphere)
        }
        return order.map { day in
            let group = members[day] ?? []
            let name = names[day].flatMap { $0.isEmpty ? nil : $0 }
            return TripSummary(day: day, name: name, count: group.count,
                               placedCount: group.filter { $0.latitude != nil && $0.longitude != nil }.count,
                               coverSphere: group.first?.id ?? UUID())
        }
    }

    private var unplacedSpheres: [SphereRecord] {
        spheres.filter { $0.latitude == nil || $0.longitude == nil }
    }

    /// The filter applied, then the search: title, tags and trip name.
    private var filtered: [SphereRecord] {
        let base: [SphereRecord]
        switch filter {
        case .all: base = spheres
        case .trip(let day): base = spheres.filter { $0.tripDayKey == day }
        case .unplaced: base = unplacedSpheres
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        let names = namesByDay
        return base.filter { sphere in
            sphere.title.localizedStandardContains(q)
                || sphere.tags.contains { $0.localizedStandardContains(q) }
                || (names[sphere.tripDayKey]?.localizedStandardContains(q) ?? false)
        }
    }

    private func sections(of list: [SphereRecord]) -> [TripSection] {
        var order: [String] = []
        var members: [String: [SphereRecord]] = [:]
        for sphere in list {
            if members[sphere.tripDayKey] == nil { order.append(sphere.tripDayKey) }
            members[sphere.tripDayKey, default: []].append(sphere)
        }
        return order.map { TripSection(day: $0, spheres: members[$0] ?? []) }
    }

    private var filterMenu: some View {
        Menu {
            Button {
                filter = .all
            } label: {
                Label("All spheres", systemImage: filter == .all ? "checkmark" : "")
            }
            Button {
                showTrips = true
            } label: {
                Label(selectedTripDay == nil ? "Trips" : "Trips (\(tripName(selectedTripDay!)))", systemImage: "calendar")
            }
            if !unplacedSpheres.isEmpty {
                Button {
                    filter = .unplaced
                } label: {
                    Label("Without a position (\(unplacedSpheres.count))", systemImage: filter == .unplaced ? "checkmark" : "mappin.slash")
                }
            }
            if let day = selectedTripDay {
                Divider()
                Button("Rename trip", systemImage: "pencil") {
                    renameText = namesByDay[day] ?? ""
                    renamingTrip = day
                }
            }
            Divider()
            Text(syncStatus)
            Text(BuildInfo.summary)
        } label: {
            Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private var syncStatus: String {
        switch SyncCoordinator.shared.state {
        case .starting: return "iCloud: checking"
        case .unavailable: return "iCloud: off, spheres stay on this device"
        case .syncing:
            let pending = SyncCoordinator.shared.pendingDownloads
            return pending > 0 ? "iCloud: fetching \(pending) files" : "iCloud: in sync"
        }
    }

    private func rename(_ day: String, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        // The file is the source of truth and is what syncs; the row follows.
        try? SphereStore.setTripName(name, forDay: day)
        if let existing = tripNames.first(where: { $0.dayKey == day }) {
            if name.isEmpty {
                context.delete(existing)
            } else {
                existing.name = name
            }
        } else if !name.isEmpty {
            context.insert(TripRecord(dayKey: day, name: name))
        }
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

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if spheres.isEmpty {
            ContentUnavailableView {
                Label("No spheres yet", systemImage: "globe")
            } description: {
                Text("Tap + at a viewpoint to capture your first one.")
            }
            .overlay(alignment: .bottom) { versionFooter }
        } else if mode.wrappedValue == .map {
            mapContent
        } else {
            let shown = filtered
            if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                grid(sections(of: shown))
            }
        }
    }

    private func grid(_ sections: [TripSection]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(sections) { section in
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                            ForEach(section.spheres) { sphere in
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
                        .padding(.horizontal)
                        .padding(.bottom, 20)
                    } header: {
                        tripHeader(section)
                    }
                }
                versionFooter
            }
        }
    }

    private var versionFooter: some View {
        Text(BuildInfo.summary)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    private func tripHeader(_ section: TripSection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tripName(section.day))
                    .font(.headline)
                    .lineLimit(1)
                if namesByDay[section.day].map({ !$0.isEmpty }) ?? false {
                    Text(TripSummary(day: section.day, name: nil, count: 0, placedCount: 0, coverSphere: UUID()).dateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(section.spheres.count == 1 ? "1 sphere" : "\(section.spheres.count) spheres")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                if selectedTripDay != section.day {
                    Button("Only this trip", systemImage: "line.3.horizontal.decrease.circle") {
                        filter = .trip(section.day)
                    }
                }
                Button("Show on map", systemImage: "map") {
                    filter = .trip(section.day)
                    modeRaw = LibraryMode.map.rawValue
                }
                Button("Rename trip", systemImage: "pencil") {
                    renameText = namesByDay[section.day] ?? ""
                    renamingTrip = section.day
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .padding(.leading, 6)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var mapContent: some View {
        let shown = filtered
        let placed = shown.compactMap(mapSphere)
        let unplaced = shown.count - placed.count
        return SphereMapView(spheres: placed,
                             paths: tripPaths(shown),
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

    /// One dashed line per trip in the shown set, through its placed spheres
    /// in capture order, when there are at least two.
    private func tripPaths(_ shown: [SphereRecord]) -> [MapPath] {
        let placed = shown.filter { $0.latitude != nil && $0.longitude != nil }
        let byTrip = Dictionary(grouping: placed) { $0.tripDayKey }
        return byTrip.compactMap { day, members -> MapPath? in
            guard members.count >= 2 else { return nil }
            let ordered = members.sorted { $0.capturedAt < $1.capturedAt }
            return MapPath(id: day, coordinates: ordered.map { [$0.latitude!, $0.longitude!] })
        }
        .sorted { $0.id < $1.id }
    }

    private func mapSphere(_ sphere: SphereRecord) -> MapSphere? {
        guard let lat = sphere.latitude, let lon = sphere.longitude else { return nil }
        let day = sphere.tripDayKey
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

/// A grid card: the section header carries the date, so an untitled sphere
/// shows its time.
private struct SphereCard: View {
    let sphere: SphereRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SphereThumbnail(id: sphere.id)
                .aspectRatio(2, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if !SphereStore.isDownloaded(SphereStore.files(for: sphere.id).image) {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.caption.weight(.semibold))
                            .padding(5)
                            .background(.thinMaterial, in: Circle())
                            .padding(6)
                            .accessibilityLabel("Not downloaded yet")
                    }
                }
            Text(sphere.title.isEmpty ? sphere.capturedAt.formatted(date: .omitted, time: .shortened) : sphere.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(sphere.tags.isEmpty ? "\(sphere.shotCount) shots" : sphere.tags.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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

/// A row for the picker sheets: thumbnail, title or date, and a detail line.
private struct SphereRow: View {
    let sphere: SphereRecord
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            SphereThumbnail(id: sphere.id)
                .frame(width: 88, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(sphere.title.isEmpty ? sphere.capturedAt.formatted(date: .abbreviated, time: .shortened) : sphere.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
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
                            Button { onPlace(sphere) } label: { SphereRow(sphere: sphere, detail: tripName(sphere.tripDayKey)) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                if !movable.isEmpty {
                    Section("Move here (placed by hand before)") {
                        ForEach(movable) { sphere in
                            Button { onPlace(sphere) } label: { SphereRow(sphere: sphere, detail: tripName(sphere.tripDayKey)) }
                                .buttonStyle(.plain)
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
                Button { onOpen(sphere) } label: { SphereRow(sphere: sphere, detail: detail(for: sphere)) }
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

    private func detail(for sphere: SphereRecord) -> String {
        var parts = [tripName(sphere.tripDayKey)]
        if !sphere.title.isEmpty {
            parts.append(sphere.capturedAt.formatted(date: .omitted, time: .shortened))
        }
        if let altitude = sphere.altitudeMetres {
            parts.append(String(format: "%.0f m", altitude))
        }
        return parts.joined(separator: " · ")
    }
}

/// The split view's sidebar: the same choices as the filter menu and the
/// Trips screen, as a persistent list with the current filter selected.
private struct TripSidebar: View {
    let trips: [TripSummary]
    let unplacedCount: Int
    @Binding var selection: LibraryFilter?
    let tripName: (String) -> String
    let onRename: (String) -> Void

    private var years: [(year: String, trips: [TripSummary])] {
        let grouped = Dictionary(grouping: trips) { String($0.day.prefix(4)) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!) }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("All spheres", systemImage: "globe")
                    .tag(LibraryFilter.all)
                if unplacedCount > 0 {
                    Label("Without a position (\(unplacedCount))", systemImage: "mappin.slash")
                        .tag(LibraryFilter.unplaced)
                }
            }
            ForEach(years, id: \.year) { group in
                Section(group.year) {
                    ForEach(group.trips) { trip in
                        HStack(spacing: 10) {
                            SphereThumbnail(id: trip.coverSphere)
                                .frame(width: 56, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(trip.displayName)
                                    .lineLimit(1)
                                Text(trip.name == nil ? (trip.count == 1 ? "1 sphere" : "\(trip.count) spheres") : "\(trip.dateText) · \(trip.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .tag(LibraryFilter.trip(trip.day))
                        .contextMenu {
                            Button("Rename trip", systemImage: "pencil") { onRename(trip.day) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
