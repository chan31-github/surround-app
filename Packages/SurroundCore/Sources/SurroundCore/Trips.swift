import Foundation

/// Trips are automatic: every sphere captured on the same calendar day, in
/// the local time zone, belongs to the same trip (F9). A trip is identified
/// by its day key, which sorts chronologically as a string.
public enum TripDay {
    /// "2026-09-18" for the calendar day containing `date`.
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Midnight at the start of the day a key names, or nil for a malformed key.
    public static func start(ofKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
