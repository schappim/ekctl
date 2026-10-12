import EventKit
import Foundation
import XCTest
import ekctlCore

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Offset-less ISO 8601 (local wall-clock time)
// ─────────────────────────────────────────────────────────────────────────────

/// `2026-02-23T14:00` and friends: ISO 8601 with no offset, read on the wall
/// clock of the calendar passed to `DateParsing.parse`. Everything here is
/// pinned to named zones and fixed dates so it passes on any machine.
final class LocalISODateTimeTests: XCTestCase {

    private func calendar(_ zone: String, _ identifier: Calendar.Identifier = .gregorian) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    /// Wednesday 2026-03-11 14:23 UTC. Irrelevant to absolute input, but pinned
    /// so a stray fall-through to the shorthand can't depend on the clock.
    private let now = Date(timeIntervalSince1970: 1_773_238_980)

    private func parse(_ input: String, in zone: String = "America/New_York") -> Date? {
        DateParsing.parse(input, now: now, calendar: calendar(zone))
    }

    /// Wall clock *and* offset in `zone`, so a test sees which side of a DST
    /// change an instant landed on, not just the hour.
    private func stamp(_ date: Date?, in zone: String = "America/New_York") -> String? {
        guard let date = date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        formatter.timeZone = TimeZone(identifier: zone)
        return formatter.string(from: date)
    }

    // ── Accepted shapes ──────────────────────────────────────────────────────

    func testMinutePrecision() {
        XCTAssertEqual(stamp(parse("2026-02-23T14:00")), "2026-02-23T14:00:00-05:00")
    }

    func testSecondPrecision() {
        XCTAssertEqual(stamp(parse("2026-02-23T14:05:09")), "2026-02-23T14:05:09-05:00")
    }

    func testFractionalSecondsAreKept() throws {
        let whole = try XCTUnwrap(parse("2026-02-23T14:00:00"))
        XCTAssertEqual(parse("2026-02-23T14:00:00.5"), whole.addingTimeInterval(0.5))
        XCTAssertEqual(parse("2026-02-23T14:00:00.250"), whole.addingTimeInterval(0.25))
        let micro = try XCTUnwrap(parse("2026-02-23T14:00:00.123456"))
        XCTAssertEqual(micro.timeIntervalSince(whole), 0.123456, accuracy: 1e-6)
        XCTAssertEqual(parse("2026-02-23T14:00:00.000"), whole)
    }

    /// RFC 3339 §5.6 allows a space or a lower-case `t` in place of `T`. The
    /// space form with seconds is what `date '+%F %T'` and databases print.
    func testSeparatorVariants() {
        let expected = "2026-02-23T14:00:00-05:00"
        XCTAssertEqual(stamp(parse("2026-02-23t14:00")), expected)
        XCTAssertEqual(stamp(parse("2026-02-23 14:00:00")), expected)
        XCTAssertEqual(stamp(parse("2026-02-23 14:00")), expected)
        XCTAssertEqual(stamp(parse("  2026-02-23T14:00  ")), expected)
    }

    /// The other "plain date + time" spellings already parsed through the
    /// shorthand; they must still, to the same instant.
    func testShorthandDayPlusTimeStillWorks() {
        let expected = "2026-02-23T14:00:00-05:00"
        XCTAssertEqual(stamp(parse("2026-02-23 2pm")), expected)
        XCTAssertEqual(stamp(parse("2026-02-23 at 14:00")), expected)
        XCTAssertEqual(stamp(parse("2026-02-23 9:15am")), "2026-02-23T09:15:00-05:00")
        // Single-digit hours aren't ISO, but the shorthand has always read them.
        XCTAssertEqual(stamp(parse("2026-02-23 9:15")), "2026-02-23T09:15:00-05:00")
    }

    func testBoundariesOfTheDay() {
        XCTAssertEqual(stamp(parse("2026-02-23T00:00")), "2026-02-23T00:00:00-05:00")
        XCTAssertEqual(stamp(parse("2026-02-23T00:00:00")), "2026-02-23T00:00:00-05:00")
        XCTAssertEqual(stamp(parse("2026-02-23T23:59")), "2026-02-23T23:59:00-05:00")
        XCTAssertEqual(stamp(parse("2026-02-23T23:59:59")), "2026-02-23T23:59:59-05:00")
        XCTAssertEqual(stamp(parse("2026-12-31T23:59:59")), "2026-12-31T23:59:59-05:00")
        XCTAssertEqual(stamp(parse("2027-01-01T00:00")), "2027-01-01T00:00:00-05:00")
    }

    func testLeapDay() {
        XCTAssertEqual(stamp(parse("2028-02-29T10:00")), "2028-02-29T10:00:00-05:00")
        XCTAssertNil(parse("2026-02-29T10:00"), "2026 is not a leap year")
        XCTAssertNil(parse("2100-02-29T10:00"), "2100 is not a leap year")
        XCTAssertNotNil(parse("2000-02-29T10:00"), "2000 is")
    }

    // ── Which zone ───────────────────────────────────────────────────────────

    func testReadInTheCalendarsZone() {
        XCTAssertEqual(stamp(parse("2026-02-23T14:00", in: "Australia/Sydney"), in: "Australia/Sydney"),
                       "2026-02-23T14:00:00+11:00")
        XCTAssertEqual(parse("2026-02-23T14:00", in: "UTC"), parse("2026-02-23T14:00:00Z"))
        XCTAssertEqual(parse("2026-02-23T14:00", in: "Asia/Kolkata"),
                       parse("2026-02-23T14:00:00+05:30"))
    }

    func testSameInstantAsTheMatchingOffsetForm() {
        XCTAssertEqual(parse("2026-02-23T14:00:00"), parse("2026-02-23T14:00:00-05:00"))
        XCTAssertEqual(parse("2026-07-23T14:00:00"), parse("2026-07-23T14:00:00-04:00"))
    }

    /// The year is Gregorian whatever the Mac's region calendar is — the same
    /// guarantee `RelativeDates.isoDate` makes for a plain date.
    func testRegionCalendarDoesNotMoveTheYear() {
        let reference = parse("2026-02-23T14:00:00")
        XCTAssertNotNil(reference)
        for identifier in [Calendar.Identifier.buddhist, .japanese, .hebrew, .persian,
                           .islamicUmmAlQura, .republicOfChina, .iso8601, .coptic] {
            XCTAssertEqual(
                DateParsing.parse("2026-02-23T14:00:00", now: now,
                                  calendar: calendar("America/New_York", identifier)),
                reference, "drifted under the \(identifier) calendar")
        }
    }

    // ── Offset-bearing ISO is untouched ──────────────────────────────────────

    /// An explicit offset or `Z` names an instant outright; the calendar's
    /// zone must not leak into it.
    func testOffsetFormsIgnoreTheCalendarZone() {
        let inputs = ["2026-03-08T02:30:00-05:00", "2026-03-08T02:30:00Z",
                      "2026-03-08T02:30:00+1100", "2026-03-08T02:30:00.250+11:00"]
        let strict = ISO8601DateFormatter()
        let strictFractional = ISO8601DateFormatter()
        strictFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let compact = ISO8601DateFormatter()
        compact.formatOptions = [.withFullDate, .withFullTime, .withDashSeparatorInDate,
                                 .withColonSeparatorInTime]
        for input in inputs {
            let expected = strict.date(from: input) ?? strictFractional.date(from: input)
                ?? compact.date(from: input)
            XCTAssertNotNil(expected, input)
            for zone in ["America/New_York", "Australia/Sydney", "UTC", "Pacific/Kiritimati"] {
                XCTAssertEqual(parse(input, in: zone), expected, "\(input) in \(zone)")
            }
        }
    }

    // ── Rejected ─────────────────────────────────────────────────────────────

    /// Out-of-range fields are errors, not rolled into the next hour, day or
    /// month the way `DateComponents` would.
    func testRejectsOutOfRangeFields() {
        for input in [
            "2026-02-23T24:00", "2026-02-23T24:00:00", "2026-02-23T25:00",
            "2026-02-23T99:00", "2026-02-23T14:60", "2026-02-23T14:00:60",
            "2026-02-23T14:00:61", "2026-02-31T10:00", "2026-04-31T10:00",
            "2026-13-01T10:00", "2026-00-10T10:00", "2026-01-00T10:00",
            "2026-01-32T10:00", "0000-01-01T10:00",
        ] {
            XCTAssertNil(parse(input), "should reject \(input)")
        }
    }

    func testRejectsMalformedShapes() {
        for input in [
            "2026-02-23T9:00",          // ISO hours are two digits
            "2026-02-23T14",            // no minutes
            "2026-02-23T1400",          // basic format isn't supported
            "2026-02-23T14:0",
            "2026-02-23T14:00:0",
            "2026-02-23T14:00:00.",     // a dot needs digits after it
            "2026-02-23T14:00:00.5x",
            "2026-02-23T14:00.5",       // fractions only on seconds
            "2026-02-23T14:00x",
            "2026-02-23T14:00:00:00",
            "2026-02-23X14:00",
            "2026-02-23TT14:00",
            "2026-02-23T+4:00",
            "2026-02-23T١٤:00",         // non-ASCII digits
            "2026-2-23T14:00",
            "+026-02-23T14:00",
            "2026-02-23T",
            "2026-02-23 14:00:00 extra",
            "2026-02-23  14:00:00",     // the shorthand has no seconds
        ] {
            XCTAssertNil(parse(input), "should reject \(input)")
        }
    }

    // ── DST: gaps move forward, repeats take the first occurrence ────────────

    /// New York springs forward at 02:00 on 2026-03-08: 01:59:59 EST is
    /// followed by 03:00:00 EDT. A time in the gap moves forward by the gap.
    func testSpringForwardGapNewYork() {
        XCTAssertEqual(stamp(parse("2026-03-08T01:59:59")), "2026-03-08T01:59:59-05:00")
        XCTAssertEqual(stamp(parse("2026-03-08T02:00")), "2026-03-08T03:00:00-04:00")
        XCTAssertEqual(stamp(parse("2026-03-08T02:30")), "2026-03-08T03:30:00-04:00")
        XCTAssertEqual(stamp(parse("2026-03-08T02:59:59")), "2026-03-08T03:59:59-04:00")
        XCTAssertEqual(stamp(parse("2026-03-08T03:00")), "2026-03-08T03:00:00-04:00")
        // Two different readings, one instant: 02:30 (skipped) and 03:30.
        XCTAssertEqual(parse("2026-03-08T02:30"), parse("2026-03-08T03:30"))
    }

    /// New York falls back at 02:00 on 2026-11-01: 01:00–01:59 happens twice.
    /// The first (EDT, -04:00) wins.
    func testFallBackRepeatNewYork() {
        XCTAssertEqual(stamp(parse("2026-11-01T00:59:59")), "2026-11-01T00:59:59-04:00")
        XCTAssertEqual(stamp(parse("2026-11-01T01:00")), "2026-11-01T01:00:00-04:00")
        XCTAssertEqual(stamp(parse("2026-11-01T01:30")), "2026-11-01T01:30:00-04:00")
        XCTAssertEqual(stamp(parse("2026-11-01T01:59:59")), "2026-11-01T01:59:59-04:00")
        XCTAssertEqual(stamp(parse("2026-11-01T02:00")), "2026-11-01T02:00:00-05:00")
        XCTAssertEqual(parse("2026-11-01T01:30"), parse("2026-11-01T01:30:00-04:00"))
    }

    /// Southern hemisphere, so spring is in October: Sydney skips 02:00–02:59
    /// on 2026-10-04 and repeats it on 2026-04-05.
    func testSydneyGapAndRepeat() {
        let sydney = "Australia/Sydney"
        XCTAssertEqual(stamp(parse("2026-10-04T02:30", in: sydney), in: sydney),
                       "2026-10-04T03:30:00+11:00")
        XCTAssertEqual(stamp(parse("2026-04-05T02:30", in: sydney), in: sydney),
                       "2026-04-05T02:30:00+11:00")
        XCTAssertEqual(stamp(parse("2026-04-05T03:00", in: sydney), in: sydney),
                       "2026-04-05T03:00:00+10:00")
    }

    /// Lord Howe Island shifts by 30 minutes, which catches any code assuming
    /// DST is always an hour.
    func testHalfHourShiftLordHowe() {
        let lordHowe = "Australia/Lord_Howe"
        XCTAssertEqual(stamp(parse("2026-10-04T02:15", in: lordHowe), in: lordHowe),
                       "2026-10-04T02:45:00+11:00")
        XCTAssertEqual(stamp(parse("2026-04-05T01:45", in: lordHowe), in: lordHowe),
                       "2026-04-05T01:45:00+11:00")
        XCTAssertEqual(stamp(parse("2026-04-05T02:00", in: lordHowe), in: lordHowe),
                       "2026-04-05T02:00:00+10:30")
    }

    /// The defining property for every reading on every transition day: the
    /// result shows that wall-clock time (unless the clocks skipped it), and
    /// no earlier instant within two hours shows it too, so a repeat always
    /// resolves to its first occurrence.
    func testEveryReadingOnTransitionDaysIsTheFirstMatchingInstant() throws {
        let days = [
            ("America/New_York", "2026-03-08"), ("America/New_York", "2026-11-01"),
            ("Australia/Sydney", "2026-10-04"), ("Australia/Sydney", "2026-04-05"),
            ("Australia/Lord_Howe", "2026-10-04"), ("Australia/Lord_Howe", "2026-04-05"),
            ("Europe/London", "2026-03-29"), ("Europe/London", "2026-10-25"),
        ]
        for (zone, day) in days {
            for minutes in stride(from: 0, to: 24 * 60, by: 5) {
                let reading = String(format: "%@T%02d:%02d:00", day, minutes / 60, minutes % 60)
                let result = try XCTUnwrap(parse(reading, in: zone), reading)
                let rendered = try XCTUnwrap(stamp(result, in: zone))
                if rendered.hasPrefix(reading) {
                    for earlier in [1800.0, 3600.0, 5400.0, 7200.0] {
                        XCTAssertFalse(
                            stamp(result.addingTimeInterval(-earlier), in: zone)!.hasPrefix(reading),
                            "\(reading) in \(zone) is not the first occurrence")
                    }
                } else {
                    // Skipped: it must have moved *forward*, by less than an hour.
                    let naive = try XCTUnwrap(parse(reading, in: "UTC"))
                    let offset = TimeInterval(TimeZone(identifier: zone)!.secondsFromGMT(for: result))
                    let shift = result.addingTimeInterval(offset).timeIntervalSince(naive)
                    XCTAssertTrue(shift > 0 && shift <= 3600,
                                  "\(reading) in \(zone) moved by \(shift)s to \(rendered)")
                }
            }
        }
    }

    // ── Parity with the shorthand ────────────────────────────────────────────

    /// The ISO form and the shorthand's "date time" form must resolve every
    /// reading identically, including the ones DST makes awkward. The
    /// shorthand is called directly: `DateParsing` now routes the space form
    /// through the ISO parser first.
    func testISOAndShorthandAgreeAcrossTransitionDays() {
        let days = [
            ("America/New_York", "2026-03-08"), ("America/New_York", "2026-11-01"),
            ("Australia/Sydney", "2026-10-04"), ("Australia/Sydney", "2026-04-05"),
            ("Australia/Lord_Howe", "2026-10-04"), ("Australia/Lord_Howe", "2026-04-05"),
        ]
        for (zone, day) in days {
            for minutes in stride(from: 0, to: 24 * 60, by: 15) {
                let time = String(format: "%02d:%02d", minutes / 60, minutes % 60)
                let iso = parse("\(day)T\(time)", in: zone)
                XCTAssertNotNil(iso)
                XCTAssertEqual(iso, RelativeDates.parse("\(day) \(time)", now: now, calendar: calendar(zone)),
                               "\(day) \(time) in \(zone)")
            }
        }
    }

    func testRelativeShorthandAgreesWithISOInTheGapAndTheRepeat() {
        let newYork = calendar("America/New_York")
        let dayBeforeSpring = newYork.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
        XCTAssertEqual(RelativeDates.parse("tomorrow 2:30am", now: dayBeforeSpring, calendar: newYork),
                       parse("2026-03-08T02:30"))
        let dayBeforeFall = newYork.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12))!
        XCTAssertEqual(RelativeDates.parse("tomorrow 1:30am", now: dayBeforeFall, calendar: newYork),
                       parse("2026-11-01T01:30"))
        XCTAssertEqual(stamp(RelativeDates.parse("tomorrow 1:30am", now: dayBeforeFall, calendar: newYork)),
                       "2026-11-01T01:30:00-04:00")
    }

    // ── Documentation ────────────────────────────────────────────────────────

    /// Help and error text must advertise the new form, and every example it
    /// gives must itself parse.
    func testAcceptedFormatsAdvertisesLocalTimeAndItsExamplesParse() {
        let text = DateParsing.acceptedFormats
        for example in ["2026-02-01T09:30", "2026-02-01T09:30:00", "2026-02-01 09:30:00",
                        "2026-02-01T09:30:00Z", "2026-02-01T09:30:00+11:00", "2026-02-01T09:30:00+1100"] {
            XCTAssertTrue(text.contains(example), "acceptedFormats should mention \(example)")
            XCTAssertNotNil(parse(example), "advertised example \(example) must parse")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Alarm units and strict alarm parsing
// ─────────────────────────────────────────────────────────────────────────────

final class AlarmUnitParsingTests: XCTestCase {

    private func parse(_ input: String) throws -> [Double] {
        try XCTUnwrap(AlarmParsing.parse(input))
    }

    private func assertError(_ input: String, _ expected: AlarmParsingError,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try AlarmParsing.parse(input), file: file, line: line) { error in
            XCTAssertEqual(error as? AlarmParsingError, expected, "for input \(input)",
                           file: file, line: line)
        }
    }

    // ── Units ────────────────────────────────────────────────────────────────

    func testEachUnit() throws {
        XCTAssertEqual(try parse("15m"), [-900])
        XCTAssertEqual(try parse("1h"), [-3600])
        XCTAssertEqual(try parse("2d"), [-172_800])
        XCTAssertEqual(try parse("1w"), [-604_800])
    }

    func testUnitsAreCaseInsensitive() throws {
        XCTAssertEqual(try parse("15M"), [-900])
        XCTAssertEqual(try parse("1H"), [-3600])
        XCTAssertEqual(try parse("2D"), [-172_800])
        XCTAssertEqual(try parse("1W"), [-604_800])
    }

    /// Same vocabulary as the date offsets (`+2h`, `+3days`), so one spelling
    /// works on every flag.
    func testLongerUnitSpellingsMatchTheDateOffsets() throws {
        XCTAssertEqual(try parse("15min,15mins,15minute,15minutes"), [-900, -900, -900, -900])
        XCTAssertEqual(try parse("2hr,2hrs,2hour,2HOURS"), Array(repeating: -7200, count: 4))
        XCTAssertEqual(try parse("1day,1days"), [-86_400, -86_400])
        XCTAssertEqual(try parse("1wk,1wks,1week,1weeks"), Array(repeating: -604_800, count: 4))
    }

    /// A bare number is still minutes, so every pre-units script is unchanged.
    func testBareNumberIsMinutes() throws {
        XCTAssertEqual(try parse("10"), try parse("10m"))
        XCTAssertEqual(try parse("+10"), try parse("+10m"))
        XCTAssertEqual(try parse("-10"), try parse("-10m"))
        XCTAssertEqual(try parse("1440"), try parse("1d"))
    }

    func testSigns() throws {
        XCTAssertEqual(try parse("+30m"), [1800], "+ is after the start")
        XCTAssertEqual(try parse("-1h"), [-3600], "- is before, same as bare")
        XCTAssertEqual(try parse("1h"), [-3600])
        XCTAssertEqual(try parse("+1w"), [604_800])
    }

    func testZeroIsAtTheStartAndNeverNegativeZero() throws {
        for input in ["0", "+0", "-0", "0m", "0h", "-0d", "+0w", "0.0h", "000"] {
            let offsets = try parse(input)
            XCTAssertEqual(offsets, [0], input)
            XCTAssertEqual(offsets.first?.sign, .plus, "\(input) produced -0.0")
        }
    }

    func testLeadingZeros() throws {
        XCTAssertEqual(try parse("010"), [-600])
        XCTAssertEqual(try parse("0000000000000000000000001h"), [-3600])
    }

    // ── Decimals ─────────────────────────────────────────────────────────────

    func testDecimalsThatComeOutToWholeMinutes() throws {
        XCTAssertEqual(try parse("1.5h"), [-5400])
        XCTAssertEqual(try parse("+1.5h"), [5400])
        XCTAssertEqual(try parse("0.5d"), [-43_200])
        XCTAssertEqual(try parse("0.25h"), [-900])
        XCTAssertEqual(try parse("1.1h"), [-3960], "exact, not 66.00000000000001 minutes")
        XCTAssertEqual(try parse("0.125d"), [-10_800])
        XCTAssertEqual(try parse("1.50000000000000000000h"), [-5400], "trailing zeros are harmless")
        XCTAssertEqual(try parse("2.0"), [-120])
    }

    /// Event output reports alarms as whole `minutesBeforeStart`, so anything
    /// finer can't be read back. That includes whole numbers of seconds.
    func testDecimalsThatAreNotWholeMinutesAreRejected() {
        for input in ["1.5", "0.5", "1.5m", "+0.5m", "1.01h", "0.001d", "1.0000001w",
                      "0.00000000000000000001h", "1.000000000000000000001w"] {
            assertError(input, .notWholeMinutes(entry: input))
        }
    }

    // ── none / empty ─────────────────────────────────────────────────────────

    func testNilMeansNotPassed() throws {
        XCTAssertNil(try AlarmParsing.parse(nil))
    }

    func testNoneAndEmptyMeanNoAlarms() throws {
        for input in ["none", "NONE", "None", " none ", "\tnone", "", " ", "\t"] {
            XCTAssertEqual(try parse(input), [], "\"\(input)\" should mean no alarms")
        }
    }

    func testNoneCannotBeMixedIn() {
        assertError("none,10", .noneInList(input: "none,10"))
        assertError("10, NONE", .noneInList(input: "10, NONE"))
    }

    // ── Lists and whitespace ─────────────────────────────────────────────────

    func testMixedUnitList() throws {
        XCTAssertEqual(try parse("10, 1h, +30m, 2d, -15m, 1w, 1.5h, +0"),
                       [-600, -3600, 1800, -172_800, -900, -604_800, -5400, 0])
    }

    func testWhitespaceAroundEntriesIsTrimmed() throws {
        XCTAssertEqual(try parse(" 15m , 1h "), [-900, -3600])
        XCTAssertEqual(try parse("\t15m,\t+1h\t"), [-900, 3600])
    }

    func testOrderAndDuplicatesArePreserved() throws {
        // parse reports what was asked for; dedupe is the caller's choice.
        XCTAssertEqual(try parse("60,1h,10"), [-3600, -3600, -600])
    }

    func testEmptyEntriesAreErrors() {
        assertError("10,,20", .emptyEntry(input: "10,,20"))
        assertError("10,", .emptyEntry(input: "10,"))
        assertError(",10", .emptyEntry(input: ",10"))
        assertError("10, ,20", .emptyEntry(input: "10, ,20"))
        assertError(",", .emptyEntry(input: ","))
    }

    // ── Rejected entries ─────────────────────────────────────────────────────

    func testUnrecognisedEntries() {
        for input in ["abc", "inf", "+inf", "nan", "infinity", ".5h", "5.h", "1.2.3",
                      "++5", "+-5", "--5", "+ 5", "15 m", "1h30m", "0x10", "1_000", "1e3",
                      "٣m", "５m", "+", "-", "h", "1h!", "1/2h"] {
            assertError(input, .unrecognised(entry: input))
        }
    }

    /// A decimal comma can't be told apart from a list separator: "1,5h" is
    /// two valid alarms (1 minute and 5 hours). Pinned so nobody assumes it's
    /// caught.
    func testDecimalCommaIsAList() throws {
        XCTAssertEqual(try parse("1,5h"), [-60, -18_000])
    }

    func testUnknownUnits() {
        assertError("3mo", .unknownUnit(entry: "3mo", unit: "mo"))
        assertError("1y", .unknownUnit(entry: "1y", unit: "y"))
        assertError("2X", .unknownUnit(entry: "2X", unit: "x"))
    }

    /// Seconds are refused outright, with the reason, rather than rounded.
    func testSecondsAreNotSupported() {
        for input in ["30s", "30S", "+30s", "60sec", "60secs", "60second", "120seconds", "1.5s"] {
            assertError(input, .secondsUnsupported(entry: input))
        }
    }

    /// The first bad entry is reported, named as typed (trimmed).
    func testFirstBadEntryIsTheOneNamed() {
        assertError("10, bogus ,30s", .unrecognised(entry: "bogus"))
    }

    // ── Range ────────────────────────────────────────────────────────────────

    func testOneYearEitherSideIsAccepted() throws {
        XCTAssertEqual(AlarmParsing.maximumOffsetMinutes, 525_600)
        XCTAssertEqual(try parse("365d"), [-31_536_000])
        XCTAssertEqual(try parse("+365d"), [31_536_000])
        XCTAssertEqual(try parse("-365d"), [-31_536_000])
        XCTAssertEqual(try parse("525600"), [-31_536_000])
        XCTAssertEqual(try parse("8760h"), [-31_536_000])
        XCTAssertEqual(try parse("52w"), [-31_449_600])
        XCTAssertEqual(try parse("364.5d"), [-31_492_800])
    }

    func testBeyondAYearIsRejected() {
        for input in ["366d", "+366d", "-366d", "53w", "525601", "+525601m", "8761h",
                      "365.5d", "52.5w", "10080h",
                      "99999999999999999999999", "+99999999999999999999h",
                      "9223372036854775807", "9223372036854775808w"] {
            assertError(input, .outOfRange(entry: input))
        }
    }

    // ── Messages ─────────────────────────────────────────────────────────────

    func testMessagesNameTheEntryAndSayWhatIsAccepted() {
        let unrecognised = AlarmParsingError.unrecognised(entry: "abc").description
        XCTAssertTrue(unrecognised.contains("\"abc\""))
        XCTAssertTrue(unrecognised.contains(AlarmParsing.acceptedFormats))

        let unit = AlarmParsingError.unknownUnit(entry: "3mo", unit: "mo").description
        XCTAssertTrue(unit.contains("\"3mo\"") && unit.contains("\"mo\""))
        XCTAssertTrue(unit.contains("m, h, d, or w"))

        let seconds = AlarmParsingError.secondsUnsupported(entry: "30s").description
        XCTAssertTrue(seconds.contains("\"30s\""))
        XCTAssertTrue(seconds.contains("whole minutes"), "must say why: \(seconds)")
        XCTAssertTrue(seconds.contains("1m"), "must say what to use instead")

        let fraction = AlarmParsingError.notWholeMinutes(entry: "1.5m").description
        XCTAssertTrue(fraction.contains("\"1.5m\"") && fraction.contains("whole minutes"))

        let range = AlarmParsingError.outOfRange(entry: "400d").description
        XCTAssertTrue(range.contains("\"400d\"") && range.contains("365 days"))

        let empty = AlarmParsingError.emptyEntry(input: "10,,20").description
        XCTAssertTrue(empty.contains("\"10,,20\"") && empty.contains("none"))

        let none = AlarmParsingError.noneInList(input: "none,10").description
        XCTAssertTrue(none.contains("\"none,10\""))
    }

    /// The message is shared by every alarm flag, so it mustn't name one.
    func testMessagesDoNotHardcodeAFlag() {
        let errors: [AlarmParsingError] = [
            .emptyEntry(input: "1,"), .noneInList(input: "none,1"), .unrecognised(entry: "x"),
            .unknownUnit(entry: "1y", unit: "y"), .secondsUnsupported(entry: "1s"),
            .notWholeMinutes(entry: "1.5"), .outOfRange(entry: "999d"),
        ]
        for error in errors {
            XCTAssertFalse(error.description.contains("--"), error.description)
        }
    }

    func testAcceptedFormatsCoversTheGrammar() {
        let text = AlarmParsing.acceptedFormats
        for fragment in ["comma-separated", "15m", "1.5h", "2d", "1w", "+30m", "none", "before", "after"] {
            XCTAssertTrue(text.contains(fragment), "acceptedFormats should mention \(fragment)")
        }
    }

    /// Every example the help text gives must parse.
    func testAcceptedFormatsExamplesParse() throws {
        XCTAssertEqual(try parse("10, 15m, 1.5h, 2d, 1w, +30m"),
                       [-600, -900, -5400, -172_800, -604_800, 1800])
    }

    // ── dedupe ───────────────────────────────────────────────────────────────

    func testDedupeKeepsFirstOccurrenceOrder() {
        XCTAssertEqual(AlarmParsing.dedupe([-600, -3600, -600, 300, -3600, 0, 300]),
                       [-600, -3600, 300, 0])
    }

    func testDedupeEdgeCases() {
        XCTAssertEqual(AlarmParsing.dedupe([]), [])
        XCTAssertEqual(AlarmParsing.dedupe([-600]), [-600])
        XCTAssertEqual(AlarmParsing.dedupe([5, 5, 5]), [5])
        XCTAssertEqual(AlarmParsing.dedupe([0, -0.0]), [0])
    }

    /// Different spellings of one offset collapse, because parse normalises
    /// them all to the same whole number of seconds.
    func testDedupeAfterParseCollapsesEquivalentSpellings() throws {
        XCTAssertEqual(AlarmParsing.dedupe(try parse("60, 1h, 60m, 0.5d, 720, +5, 10, -1h")),
                       [-3600, -43_200, 300, -600])
    }

    // ── Round trip through event output ──────────────────────────────────────

    private func minutesBeforeStart(_ offsets: [Double]) -> [Int?] {
        EventKitManager.alarmDicts(offsets.map { EKAlarm(relativeOffset: $0) }) { _ in "" }
            .map { $0["minutesBeforeStart"] as? Int }
    }

    /// The flag spelling for a rendered value: positive is a bare number, and
    /// negative (after the start) is written with `+`.
    private func flagValue(_ minutesBeforeStart: Int) -> String {
        minutesBeforeStart >= 0 ? "\(minutesBeforeStart)" : "+\(-minutesBeforeStart)"
    }

    /// An alarm rendered as `minutesBeforeStart` parses back to the same offset,
    /// as a bare number and with the `m` unit.
    func testRenderedAlarmsParseBackToTheSameOffset() throws {
        for minutes in [0, 1, 5, 10, 15, 59, 60, 90, 1440, 10_080, 525_600,
                        -1, -15, -60, -1440, -525_600] {
            let offset = Double(-minutes * 60)
            let rendered = try XCTUnwrap(minutesBeforeStart([offset]).first ?? nil)
            XCTAssertEqual(rendered, minutes)
            XCTAssertEqual(try parse(flagValue(rendered)), [offset], "bare \(minutes)")
            XCTAssertEqual(try parse(flagValue(rendered) + "m"), [offset], "\(minutes)m")
        }
    }

    /// Every unit spelling produces an offset that renders as a whole number
    /// of minutes and reads back to itself, so units never introduce drift.
    func testUnitFlagsRoundTripThroughOutput() throws {
        let flags = ["15m", "1h", "1.5h", "2d", "+30m", "1w", "0.25h", "+1.5d", "52w", "-2h"]
        let offsets = try parse(flags.joined(separator: ","))
        let rendered = minutesBeforeStart(offsets).map { $0! }
        XCTAssertEqual(try parse(rendered.map(flagValue).joined(separator: ",")), offsets)
        for (offset, minutes) in zip(offsets, rendered) {
            XCTAssertEqual(Double(-minutes * 60), offset, "lossy render of \(offset)s")
        }
    }

    /// A negative `minutesBeforeStart` goes back in with `+`. Passed as `-15`
    /// it means 15 minutes *before*, as it always has; pin that so a change
    /// to it is deliberate.
    func testNegativeRenderedValueNeedsThePlusForm() throws {
        let afterStart = try parse("+15")
        XCTAssertEqual(minutesBeforeStart(afterStart), [-15])
        XCTAssertEqual(try parse("+15"), [900])
        XCTAssertEqual(try parse("-15"), [-900])
    }
}

/// Offset-bearing ISO input is parsed field by field, as strictly as the
/// offset-less form. `ISO8601DateFormatter`, which used to do it, rolled
/// impossible dates forward and ignored what it couldn't read.
final class StrictOffsetDateTimeTests: XCTestCase {
    private func parse(_ string: String) -> Date? {
        DateParsing.parse(string, now: Date(timeIntervalSince1970: 0),
                          calendar: Calendar(identifier: .gregorian))
    }

    private func utc(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testEveryFormEkctlEmitsStillParses() {
        XCTAssertEqual(parse("2026-02-23T14:00:00Z"), utc("2026-02-23T14:00:00Z"))
        XCTAssertEqual(parse("2026-02-23T14:00:00+11:00"), utc("2026-02-23T03:00:00Z"))
        XCTAssertEqual(parse("2026-02-23T14:00:00+1100"), utc("2026-02-23T03:00:00Z"))
        XCTAssertEqual(parse("2026-02-23T14:00:00+0000"), utc("2026-02-23T14:00:00Z"))
        XCTAssertEqual(parse("2026-02-23T14:00:00-05:00"), utc("2026-02-23T19:00:00Z"))
        XCTAssertEqual(parse("2026-02-23T14:00:00.500Z")!.timeIntervalSince(utc("2026-02-23T14:00:00Z")), 0.5)
    }

    func testHalfHourAndHourOnlyOffsetsAreExact() {
        XCTAssertEqual(parse("2026-02-23T14:00:00+05:30"), utc("2026-02-23T08:30:00Z"))
        XCTAssertEqual(parse("2026-02-23T14:00:00+0545"), utc("2026-02-23T08:15:00Z"))
        XCTAssertEqual(parse("2026-02-23T14:00:00+11"), utc("2026-02-23T03:00:00Z"))
        XCTAssertEqual(parse("2026-02-23T14:00+11:00"), utc("2026-02-23T03:00:00Z"))
    }

    func testMalformedInputIsRejectedNotRolledOver() {
        for input in [
            "2026-02-30T10:00:00Z", "2026-02-23T24:00:00Z", "2026-02-23T14:00:00+5:30",
            "2026-02-23T14:00:00+05:3", "2026-02-23T14:00:00+99:99", "2026-02-23T14:00:00+111",
            "12026-02-23T14:00:00Z", "26-02-23T14:00:00Z", "0000-01-01T00:00:00Z",
            "2026-02-23T14:00:00Z oops", "2026-02-23T14:00:00+11:00junk", "2026-02-23T14:00:00ZZ",
            "2026-2-3T14:00:00Z", "2026-02-23T1:00:00Z", "2026-02-23T14:00:00 Z",
            "2026-02-23T14:00:00UTC", "2026-02-23T14:00:00+1:00",
        ] {
            XCTAssertNil(parse(input), input)
        }
    }
}
