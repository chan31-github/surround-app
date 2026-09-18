import XCTest
@testable import SurroundCore

final class TripsTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    func testKeyUsesLocalCalendarDay() {
        // 17:30 UTC on 18 September is 01:30 on the 19th in Hong Kong.
        let date = ISO8601DateFormatter().date(from: "2026-09-18T17:30:00Z")!
        XCTAssertEqual(TripDay.key(for: date, calendar: calendar("Asia/Hong_Kong")), "2026-09-19")
        XCTAssertEqual(TripDay.key(for: date, calendar: calendar("UTC")), "2026-09-18")
    }

    func testKeysSortChronologically() {
        let keys = ["2026-09-18", "2025-12-31", "2026-01-05"]
        XCTAssertEqual(keys.sorted(), ["2025-12-31", "2026-01-05", "2026-09-18"])
    }

    func testStartOfKeyRoundTrips() {
        let cal = calendar("Asia/Hong_Kong")
        let start = TripDay.start(ofKey: "2026-09-19", calendar: cal)!
        XCTAssertEqual(TripDay.key(for: start, calendar: cal), "2026-09-19")
        XCTAssertEqual(TripDay.key(for: start.addingTimeInterval(-1), calendar: cal), "2026-09-18")
        XCTAssertNil(TripDay.start(ofKey: "yesterday", calendar: cal))
    }
}
