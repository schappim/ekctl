import XCTest
@testable import ekctlCore

final class WallClockShiftTests: XCTestCase {
    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: iso)!
    }

    private let sydney = TimeZone(identifier: "Australia/Sydney")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    func testSameDayShiftIsMeasuredInClockTime() {
        // 01:30 AEDT to 03:30 AEST on 6 April 2031, the night clocks go back:
        // three hours elapse, but the clock moves two.
        let shift = WallClockShift(
            from: date("2031-04-05T14:30:00Z"), to: date("2031-04-05T17:30:00Z"), in: sydney)
        XCTAssertEqual(shift.seconds, 2 * 3600)
        // Applied to the next day's 01:30 AEST it lands at 03:30 AEST.
        XCTAssertEqual(shift.applied(to: date("2031-04-06T15:30:00Z")), date("2031-04-06T17:30:00Z"))
    }

    func testDayShiftAcrossTheUsersOwnDSTChangeKeepsTheEventsClockTime() {
        // A New York series at 10:00 moved a day later stays at 10:00 in New
        // York, whatever the Mac's zone did that weekend.
        let shift = WallClockShift(
            from: date("2031-04-19T14:00:00Z"), to: date("2031-04-20T14:00:00Z"), in: newYork)
        XCTAssertEqual(shift.seconds, 86_400)
        XCTAssertEqual(shift.applied(to: date("2031-04-05T14:00:00Z")), date("2031-04-06T14:00:00Z"))
    }

    func testShiftAcrossSpringForwardKeepsClockTime() {
        // 10:00 EST on 2031-03-08 → 10:00 EDT on 2031-03-15: one week on the
        // clock, an hour less in elapsed time.
        let shift = WallClockShift(
            from: date("2031-03-08T15:00:00Z"), to: date("2031-03-15T14:00:00Z"), in: newYork)
        XCTAssertEqual(shift.seconds, 7 * 86_400)
        XCTAssertEqual(shift.applied(to: date("2031-03-01T15:00:00Z")), date("2031-03-08T15:00:00Z"))
    }

    func testZeroShift() {
        let start = date("2031-06-02T00:00:00Z")  // 10:00 AEST
        XCTAssertTrue(WallClockShift(from: start, to: start, in: sydney).isZero)
    }
}
