import SwiftUI
import SurroundCore

/// One trip as the Trips screen and section headers show it.
struct TripSummary: Identifiable, Equatable {
    let day: String
    /// The user's name for the day, when given.
    let name: String?
    let count: Int
    let placedCount: Int
    let coverSphere: UUID

    var id: String { day }

    var dateText: String {
        guard let date = TripDay.start(ofKey: day) else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }

    var displayName: String { name ?? dateText }
}

/// Every trip, newest first, grouped by year, searchable by name or date.
/// Replaces a popup menu that stopped working past a few dozen trips.
struct TripsView: View {
    let trips: [TripSummary]
    let selected: String?
    let onSelect: (String?) -> Void
    let onRename: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var renaming: TripSummary?
    @State private var renameText = ""

    private var shown: [TripSummary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return trips }
        return trips.filter { $0.displayName.localizedStandardContains(q) || $0.dateText.localizedStandardContains(q) }
    }

    private var years: [(year: String, trips: [TripSummary])] {
        let grouped = Dictionary(grouping: shown) { String($0.day.prefix(4)) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!) }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Button {
                        onSelect(nil)
                        dismiss()
                    } label: {
                        Label("All spheres", systemImage: selected == nil ? "checkmark.circle.fill" : "circle")
                    }
                }
                ForEach(years, id: \.year) { group in
                    Section(group.year) {
                        ForEach(group.trips) { trip in
                            Button {
                                onSelect(trip.day)
                                dismiss()
                            } label: {
                                row(trip)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button("Rename", systemImage: "pencil") {
                                    renameText = trip.name ?? ""
                                    renaming = trip
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Trip name or date")
            .navigationTitle("Trips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename trip", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Trip name", text: $renameText)
                Button("Save") {
                    if let trip = renaming { onRename(trip.day, renameText) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Leave the name empty to show the date again.")
            }
        }
    }

    private func row(_ trip: TripSummary) -> some View {
        HStack(spacing: 12) {
            SphereThumbnail(id: trip.coverSphere)
                .frame(width: 88, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle(trip))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if trip.day == selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private func subtitle(_ trip: TripSummary) -> String {
        var parts: [String] = []
        if trip.name != nil { parts.append(trip.dateText) }
        parts.append(trip.count == 1 ? "1 sphere" : "\(trip.count) spheres")
        if trip.placedCount < trip.count {
            parts.append("\(trip.count - trip.placedCount) without a position")
        }
        return parts.joined(separator: " · ")
    }
}
