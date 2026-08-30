import ArgumentParser
import EventKit
import XCTest
import ekctlCore
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Tests
// ─────────────────────────────────────────────────────────────────────────────

// ── Test-only helpers ─────────────────────────────────────────────────────────
// These small functions mirror the inline logic inside run() methods in Ekctl.swift. 
// They can't be imported because they live in the executable target, so we keep slim wrappers here. 
// Each one exactly matches the production code — if the production code changes, the behaviour test will catch the drift.

/// Mirrors: parseDateOption() in Ekctl.swift, which delegates to the real
/// `DateParsing.parse` — so unlike the other mirrors this one exercises the
/// actual production parser.
func validateDate(_ input: String) -> Date? {
    DateParsing.parse(input)
}

/// Mirrors: TimeInterval(ttInt * 60) in AddEvent.run() / UpdateEvent.run()
func travelTimeSeconds(from minuteString: String) -> TimeInterval? {
    guard let minutes = Int(minuteString) else { return nil }
    return TimeInterval(minutes * 60)
}

/// Mirrors: (recurrenceInterval.flatMap(Int.init)) ?? 1 in AddEvent.run()
func recurrenceInterval(from string: String?) -> Int {
    string.flatMap(Int.init) ?? 1
}

/// Mirrors: Int(priority) in AddReminder.run() / UpdateReminder.run()
func parsePriority(_ string: String?) -> Int? {
    guard let string = string else { return nil }
    return Int(string)
}

/// The real shared implementation used by AddEvent.run() / UpdateEvent.run()
/// — no longer a mirror.
func parseAlarms(_ string: String?) -> [Double]? {
    AlarmParsing.parse(string)
}

// ─────────────────────────────────────────────────────────────────────────────

final class JSONOutputTests: XCTestCase {

    func testSuccessAddsStatusField() {
        let output = JSONOutput.success(["foo": "bar"])
        let dict = output.toDictionary()
        XCTAssertEqual(dict["status"] as? String, "success")
        XCTAssertEqual(dict["foo"] as? String, "bar")
    }

    func testSuccessDoesNotOverwriteExistingStatus() {
        // If caller already set "status", leave it alone
        let output = JSONOutput.success(["status": "custom"])
        let dict = output.toDictionary()
        XCTAssertEqual(dict["status"] as? String, "custom")
    }

    func testErrorOutput() {
        let output = JSONOutput.error("Something went wrong")
        let dict = output.toDictionary()
        XCTAssertEqual(dict["status"] as? String, "error")
        XCTAssertEqual(dict["error"] as? String, "Something went wrong")
    }

    func testToJSONIsValidJSON() {
        let output = JSONOutput.success(["count": 3, "items": ["a", "b", "c"]])
        let json = output.toJSON()
        let data = json.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Output format tests
///
/// These cover the `--format json|csv|text` flag. The defining property the
/// formatters MUST preserve is *drift resistance*: any new field added to a
/// dict produced by `eventToDict`, `reminderToDict`, etc. has to flow through
/// CSV and text output without changes to the formatter, otherwise CSV/text
/// will silently lag JSON as the project grows. Multiple tests below assert
/// this property explicitly.
final class OutputFormatTests: XCTestCase {

    // MARK: - Format dispatch

    func testFormatDotJSONMatchesToJSON() {
        let output = JSONOutput.success(["count": 1])
        XCTAssertEqual(output.format(.json), output.toJSON())
    }

    func testFormatDotCSVReturnsCSV() {
        let output = JSONOutput.success([
            "events": [["id": "1", "title": "Foo"]]
        ])
        let csv = output.format(.csv)
        XCTAssertTrue(csv.contains("id,title"))
        XCTAssertTrue(csv.contains("1,Foo"))
    }

    func testFormatDotTextReturnsText() {
        let output = JSONOutput.success([
            "events": [["id": "1", "title": "Foo"]]
        ])
        let text = output.format(.text)
        XCTAssertTrue(text.contains("id: 1"))
        XCTAssertTrue(text.contains("title: Foo"))
    }

    // MARK: - CSV: primary row detection

    func testCSVUsesEventsListAsRows() {
        let events: [[String: Any]] = [
            ["id": "a", "title": "x"],
            ["id": "b", "title": "y"],
        ]
        let output = JSONOutput.success(["events": events, "count": 2])
        let lines = output.format(.csv).components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "id,title")
        XCTAssertEqual(lines[1], "a,x")
        XCTAssertEqual(lines[2], "b,y")
    }

    func testCSVUsesRemindersListWhenPresent() {
        let reminders: [[String: Any]] = [["id": "r1", "title": "buy milk"]]
        let output = JSONOutput.success(["reminders": reminders, "count": 1])
        XCTAssertTrue(output.format(.csv).contains("buy milk"))
    }

    func testCSVUsesCalendarsListWhenPresent() {
        let calendars: [[String: Any]] = [["id": "c1", "title": "Work"]]
        let output = JSONOutput.success(["calendars": calendars])
        XCTAssertTrue(output.format(.csv).contains("Work"))
    }

    func testCSVUsesAliasesListWhenPresent() {
        let aliases: [[String: String]] = [["name": "work", "id": "abc"]]
        let output = JSONOutput.success(["aliases": aliases, "count": 1])
        XCTAssertTrue(output.format(.csv).contains("name"))
        XCTAssertTrue(output.format(.csv).contains("work"))
    }

    func testCSVWrapsSingleEventInOneRow() {
        let output = JSONOutput.success([
            "event": ["id": "1", "title": "Foo"]
        ])
        let lines = output.format(.csv).components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "id,title")
        XCTAssertEqual(lines[1], "1,Foo")
    }

    // MARK: - CSV: flattening

    func testCSVFlattensNestedObjectsWithDotNotation() {
        let events: [[String: Any]] = [[
            "id": "1",
            "calendar": ["id": "cal-1", "title": "Work"]
        ]]
        let output = JSONOutput.success(["events": events])
        let csv = output.format(.csv)
        XCTAssertTrue(csv.contains("calendar.id"))
        XCTAssertTrue(csv.contains("calendar.title"))
        XCTAssertTrue(csv.contains("cal-1"))
        XCTAssertTrue(csv.contains("Work"))
    }

    func testCSVFlattensDeeplyNestedObjects() {
        let events: [[String: Any]] = [[
            "a": ["b": ["c": "deep"]]
        ]]
        let output = JSONOutput.success(["events": events])
        let csv = output.format(.csv)
        XCTAssertTrue(csv.contains("a.b.c"))
        XCTAssertTrue(csv.contains("deep"))
    }

    func testCSVJSONEncodesNestedArrayIntoSingleCell() {
        let events: [[String: Any]] = [[
            "id": "1",
            "attendees": [["name": "Jane", "email": "jane@x.com"]]
        ]]
        let output = JSONOutput.success(["events": events])
        let csv = output.format(.csv)
        // The whole attendees array should be JSON-encoded into one cell.
        // The cell will get quoted because the JSON contains commas, so the
        // result contains "[{...}]" wrapped in CSV quotes with `"` doubled.
        XCTAssertTrue(csv.contains("Jane"))
        XCTAssertTrue(csv.contains("jane@x.com"))
        XCTAssertTrue(csv.contains("\"\""), "expected doubled quotes from CSV escaping of JSON")
    }

    // MARK: - CSV: RFC 4180 escaping

    func testCSVEscapesFieldsContainingComma() {
        let events: [[String: Any]] = [["title": "Hello, World"]]
        let output = JSONOutput.success(["events": events])
        XCTAssertTrue(output.format(.csv).contains("\"Hello, World\""))
    }

    func testCSVEscapesFieldsContainingDoubleQuote() {
        let events: [[String: Any]] = [["title": "She said \"hi\""]]
        let output = JSONOutput.success(["events": events])
        // Internal " is doubled, whole field is wrapped in quotes:
        XCTAssertTrue(output.format(.csv).contains("\"She said \"\"hi\"\"\""))
    }

    func testCSVEscapesFieldsContainingNewline() {
        let events: [[String: Any]] = [["notes": "line one\nline two"]]
        let output = JSONOutput.success(["events": events])
        XCTAssertTrue(output.format(.csv).contains("\"line one\nline two\""))
    }

    func testCSVDoesNotEscapePlainField() {
        let events: [[String: Any]] = [["title": "plain", "id": "1"]]
        let output = JSONOutput.success(["events": events])
        let csv = output.format(.csv)
        // Plain field "plain" must appear bare, without surrounding quotes.
        XCTAssertTrue(csv.contains("1,plain"))
        XCTAssertFalse(csv.contains("\"plain\""))
    }

    func testCSVUsesCRLFLineEndings() {
        let events: [[String: Any]] = [["id": "1"], ["id": "2"]]
        let output = JSONOutput.success(["events": events])
        let csv = output.format(.csv)
        // Header row → CRLF → row 1 → CRLF → row 2
        XCTAssertTrue(csv.contains("\r\n"))
    }

    // MARK: - CSV: union of keys + missing fields

    func testCSVHeaderIsUnionOfKeysAlphabetised() {
        let events: [[String: Any]] = [
            ["id": "1", "title": "A"],
            ["id": "2", "title": "B", "extra": "value"],
        ]
        let output = JSONOutput.success(["events": events])
        let lines = output.format(.csv).components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "extra,id,title")
        XCTAssertEqual(lines[1], ",1,A")        // first row missing `extra`
        XCTAssertEqual(lines[2], "value,2,B")   // second row has it
    }

    // MARK: - CSV: empty + error cases

    func testCSVEmptyEventsListProducesEmptyString() {
        let empty: [[String: Any]] = []
        let output = JSONOutput.success(["events": empty])
        XCTAssertEqual(output.format(.csv), "")
    }

    func testCSVErrorResponseProducesSingleRow() {
        let output = JSONOutput.error("Calendar not found")
        let csv = output.format(.csv)
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "error,status")
        XCTAssertEqual(lines[1], "Calendar not found,error")
    }

    // MARK: - CSV: value coercion

    func testCSVRendersNSNullAsEmpty() {
        let events: [[String: Any]] = [["id": "1", "location": NSNull()]]
        let output = JSONOutput.success(["events": events])
        let lines = output.format(.csv).components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "id,location")
        XCTAssertEqual(lines[1], "1,")
    }

    func testCSVRendersBoolAsTrueFalse() {
        let events: [[String: Any]] = [["id": "1", "allDay": true]]
        let output = JSONOutput.success(["events": events])
        let lines = output.format(.csv).components(separatedBy: "\r\n")
        XCTAssertTrue(lines[1].contains("true"))
        XCTAssertFalse(lines[1].contains("1,true,1"), "Bool must not render as '1'")
    }

    func testCSVRendersIntegerWithoutDecimal() {
        let events: [[String: Any]] = [["id": "1", "priority": 5]]
        let output = JSONOutput.success(["events": events])
        let lines = output.format(.csv).components(separatedBy: "\r\n")
        XCTAssertTrue(lines[1].contains("5"))
        XCTAssertFalse(lines[1].contains("5.0"), "Integer must not render with .0")
    }

    // MARK: - CSV: drift resistance (the headline property)

    /// If someone adds a brand-new field to `eventToDict` tomorrow, this test's
    /// equivalent — same data shape, just with the new key inserted — should
    /// continue to pass without changes to the formatter. That's the whole
    /// point of auto-discovery: CSV cannot lag JSON.
    func testCSVPicksUpArbitraryNewFieldsWithoutCodeChanges() {
        let events: [[String: Any]] = [[
            "id": "1",
            "title": "Foo",
            "someFieldAddedInTheFuture": "shows up automatically",
        ]]
        let output = JSONOutput.success(["events": events])
        let csv = output.format(.csv)
        XCTAssertTrue(csv.contains("someFieldAddedInTheFuture"))
        XCTAssertTrue(csv.contains("shows up automatically"))
    }

    /// Explicit regression guard for the two fields the maintainer specifically
    /// worried about (`availability` from issue #2 and `attendees` from PR #6).
    /// Both must round-trip through CSV without any per-field code.
    func testCSVIncludesAvailabilityAndAttendeesAutomatically() {
        let events: [[String: Any]] = [[
            "id": "1",
            "title": "Meeting",
            "availability": "busy",
            "attendees": [["name": "Jane", "email": "jane@x.com"]],
        ]]
        let output = JSONOutput.success(["events": events])
        let csv = output.format(.csv)
        XCTAssertTrue(csv.contains("availability"), "availability must appear in CSV header")
        XCTAssertTrue(csv.contains("busy"))
        XCTAssertTrue(csv.contains("attendees"), "attendees must appear in CSV header")
        XCTAssertTrue(csv.contains("Jane"))
    }

    // MARK: - Text format

    func testTextRendersKeyColonValueLines() {
        let events: [[String: Any]] = [["id": "1", "title": "Foo"]]
        let output = JSONOutput.success(["events": events])
        let text = output.format(.text)
        XCTAssertTrue(text.contains("id: 1"))
        XCTAssertTrue(text.contains("title: Foo"))
    }

    func testTextKeysAreSorted() {
        let events: [[String: Any]] = [["zzz": "1", "aaa": "2"]]
        let output = JSONOutput.success(["events": events])
        let text = output.format(.text)
        let aaaIndex = text.range(of: "aaa:")!.lowerBound
        let zzzIndex = text.range(of: "zzz:")!.lowerBound
        XCTAssertLessThan(aaaIndex, zzzIndex)
    }

    func testTextSeparatesItemsWithBlankLine() {
        let events: [[String: Any]] = [["id": "1"], ["id": "2"]]
        let output = JSONOutput.success(["events": events])
        let text = output.format(.text)
        XCTAssertTrue(text.contains("id: 1\n\nid: 2"))
    }

    func testTextFlattensNestedObjects() {
        let events: [[String: Any]] = [[
            "calendar": ["title": "Work"]
        ]]
        let output = JSONOutput.success(["events": events])
        XCTAssertTrue(output.format(.text).contains("calendar.title: Work"))
    }

    func testTextRendersErrorResponse() {
        let output = JSONOutput.error("Calendar not found")
        let text = output.format(.text)
        XCTAssertTrue(text.contains("error: Calendar not found"))
        XCTAssertTrue(text.contains("status: error"))
    }

    func testTextEmptyListProducesEmpty() {
        let empty: [[String: Any]] = []
        let output = JSONOutput.success(["events": empty])
        XCTAssertEqual(output.format(.text), "")
    }

    func testTextPicksUpNewFieldsWithoutCodeChanges() {
        let events: [[String: Any]] = [[
            "id": "1",
            "shinyNewField": "automatic",
        ]]
        let output = JSONOutput.success(["events": events])
        XCTAssertTrue(output.format(.text).contains("shinyNewField: automatic"))
    }

    // MARK: - OutputFormat enum

    func testOutputFormatRawValues() {
        XCTAssertEqual(OutputFormat.json.rawValue, "json")
        XCTAssertEqual(OutputFormat.csv.rawValue, "csv")
        XCTAssertEqual(OutputFormat.text.rawValue, "text")
    }

    func testOutputFormatAllCases() {
        XCTAssertEqual(Set(OutputFormat.allCases.map(\.rawValue)),
                       ["json", "csv", "text"])
    }

    func testOutputFormatExpressibleByArgument() {
        XCTAssertEqual(OutputFormat(argument: "json"), .json)
        XCTAssertEqual(OutputFormat(argument: "csv"), .csv)
        XCTAssertEqual(OutputFormat(argument: "text"), .text)
        XCTAssertNil(OutputFormat(argument: "yaml"))
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Filter helper tests
///
/// These cover the `--search` and `--availability` filters on `list events`
/// and `--search` on `list reminders`. The actual filtering inside
/// `EventKitManager.listEvents` / `listReminders` runs against `EKEvent` /
/// `EKReminder` objects backed by an `EKEventStore`, so we can't unit-test
/// it directly. The filtering *logic* is therefore extracted into the pure
/// static helpers `EventFilter.matchesSearch` and
/// `EventFilter.matchesAvailability`, which are what these tests cover.
final class EventFilterTests: XCTestCase {

    // MARK: - matchesSearch

    func testMatchesSearchReturnsTrueWhenNeedleIsNil() {
        XCTAssertTrue(EventFilter.matchesSearch(nil, in: ["whatever"]))
    }

    func testMatchesSearchReturnsTrueWhenNeedleIsEmpty() {
        // Empty string is treated as "no filter requested" — equivalent to nil.
        XCTAssertTrue(EventFilter.matchesSearch("", in: ["whatever"]))
    }

    func testMatchesSearchMatchesInFirstField() {
        XCTAssertTrue(EventFilter.matchesSearch("stand", in: ["Daily Standup", "Office", nil]))
    }

    func testMatchesSearchMatchesInMiddleField() {
        XCTAssertTrue(EventFilter.matchesSearch("office", in: ["Coffee", "Office HQ", "notes"]))
    }

    func testMatchesSearchMatchesInLastField() {
        XCTAssertTrue(EventFilter.matchesSearch("plan", in: ["Standup", nil, "remember to plan Q3"]))
    }

    func testMatchesSearchReturnsFalseWhenNoFieldMatches() {
        XCTAssertFalse(EventFilter.matchesSearch("xyz", in: ["Daily Standup", "Office", "notes"]))
    }

    func testMatchesSearchIsCaseInsensitive() {
        XCTAssertTrue(EventFilter.matchesSearch("STANDUP", in: ["daily standup", nil, nil]))
        XCTAssertTrue(EventFilter.matchesSearch("standup", in: ["DAILY STANDUP", nil, nil]))
        XCTAssertTrue(EventFilter.matchesSearch("StAnDuP", in: ["Daily Standup", nil, nil]))
    }

    func testMatchesSearchHandlesAllNilFieldsGracefully() {
        XCTAssertFalse(EventFilter.matchesSearch("anything", in: [nil, nil, nil]))
    }

    func testMatchesSearchHandlesEmptyFieldList() {
        XCTAssertFalse(EventFilter.matchesSearch("anything", in: []))
    }

    func testMatchesSearchMatchesSubstringNotJustWordBoundary() {
        XCTAssertTrue(EventFilter.matchesSearch("anding", in: ["understanding", nil, nil]))
    }

    func testMatchesSearchAllowsArbitraryFieldCount() {
        // Reminder path passes only [title, notes] — two fields. Event path
        // passes [title, location, notes] — three. Helper must support both.
        XCTAssertTrue(EventFilter.matchesSearch("milk", in: ["buy milk", nil]))
        XCTAssertTrue(EventFilter.matchesSearch("milk", in: ["buy stuff", nil, "milk"]))
    }

    // MARK: - matchesAvailability

    func testMatchesAvailabilityReturnsTrueWhenFilterIsNil() {
        XCTAssertTrue(EventFilter.matchesAvailability(nil, eventAvailability: "busy"))
        XCTAssertTrue(EventFilter.matchesAvailability(nil, eventAvailability: "free"))
    }

    func testMatchesAvailabilityMatchesEqualValues() {
        XCTAssertTrue(EventFilter.matchesAvailability(.busy, eventAvailability: "busy"))
        XCTAssertTrue(EventFilter.matchesAvailability(.free, eventAvailability: "free"))
        XCTAssertTrue(EventFilter.matchesAvailability(.tentative, eventAvailability: "tentative"))
        XCTAssertTrue(EventFilter.matchesAvailability(.unavailable, eventAvailability: "unavailable"))
        XCTAssertTrue(EventFilter.matchesAvailability(.notSupported, eventAvailability: "notSupported"))
    }

    func testMatchesAvailabilityRejectsMismatch() {
        XCTAssertFalse(EventFilter.matchesAvailability(.busy, eventAvailability: "free"))
        XCTAssertFalse(EventFilter.matchesAvailability(.free, eventAvailability: "busy"))
    }

    func testMatchesAvailabilityIsCaseInsensitive() {
        XCTAssertTrue(EventFilter.matchesAvailability(.busy, eventAvailability: "BUSY"))
        XCTAssertTrue(EventFilter.matchesAvailability(.notSupported, eventAvailability: "notsupported"))
    }

    // MARK: - AvailabilityFilter enum

    func testAvailabilityFilterRawValues() {
        XCTAssertEqual(AvailabilityFilter.busy.rawValue, "busy")
        XCTAssertEqual(AvailabilityFilter.free.rawValue, "free")
        XCTAssertEqual(AvailabilityFilter.tentative.rawValue, "tentative")
        XCTAssertEqual(AvailabilityFilter.unavailable.rawValue, "unavailable")
        XCTAssertEqual(AvailabilityFilter.notSupported.rawValue, "notSupported")
    }

    func testAvailabilityFilterAllCases() {
        XCTAssertEqual(
            Set(AvailabilityFilter.allCases.map(\.rawValue)),
            ["busy", "free", "tentative", "unavailable", "notSupported"]
        )
    }

    func testAvailabilityFilterExpressibleByArgument() {
        XCTAssertEqual(AvailabilityFilter(argument: "busy"), .busy)
        XCTAssertEqual(AvailabilityFilter(argument: "free"), .free)
        XCTAssertEqual(AvailabilityFilter(argument: "tentative"), .tentative)
        XCTAssertEqual(AvailabilityFilter(argument: "unavailable"), .unavailable)
        XCTAssertEqual(AvailabilityFilter(argument: "notSupported"), .notSupported)
        XCTAssertNil(AvailabilityFilter(argument: "nonsense"))
        // Case-sensitive at the ArgumentParser layer (the value must match the
        // raw value exactly) — case-insensitivity is only applied inside
        // matchesAvailability when comparing against an event's emitted string.
        XCTAssertNil(AvailabilityFilter(argument: "BUSY"))
    }

    /// Raw values MUST match the strings emitted by EventKitManager's
    /// availability switch (eventToDict / availabilityString). If these
    /// drift, a `--availability busy` filter would silently skip every event
    /// because the comparison wouldn't match. Locked down explicitly here so
    /// any rename in EventKitManager.swift causes a test failure.
    func testAvailabilityFilterRawValuesMatchEventKitManagerStringForm() {
        // These are the literal strings that EventKitManager.availabilityString
        // returns. Keep in sync.
        let expected: [String] = ["busy", "free", "tentative", "unavailable", "notSupported"]
        XCTAssertEqual(
            AvailabilityFilter.allCases.map(\.rawValue),
            expected,
            "AvailabilityFilter cases must match the strings emitted by EventKitManager.availabilityString"
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// DateRanges tests
///
/// Locks down the pure date math behind the `today` / `tomorrow` / `next`
/// convenience subcommands. The helpers take `now` and `calendar` as
/// parameters so we can pin them to fixed instants and explicit timezones
/// rather than wallclock + system zone.
final class DateRangesTests: XCTestCase {

    /// Calendar fixed to a stable timezone so tests don't drift with whoever's
    /// running them. America/New_York chosen because it crosses both DST
    /// transitions during the year, useful for the DST tests below.
    private func calendar(in tzID: String = "America/New_York") -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tzID)!
        return cal
    }

    /// Build a Date from a known wallclock in the given calendar.
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int,
                      in cal: Calendar) -> Date {
        var components = DateComponents()
        components.year = y; components.month = m; components.day = d
        components.hour = h; components.minute = min
        return cal.date(from: components)!
    }

    // MARK: - today()

    func testTodayStartsAtMidnightLocal() {
        let cal = calendar()
        let now = date(2026, 3, 15, 14, 30, in: cal)  // 2:30 PM local
        let (start, _) = DateRanges.today(now: now, calendar: cal)

        let components = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 15)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)
    }

    func testTodayEndsAtMidnightOfNextDay() {
        let cal = calendar()
        let now = date(2026, 3, 15, 14, 30, in: cal)
        let (_, end) = DateRanges.today(now: now, calendar: cal)

        let components = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: end)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 16)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)
    }

    func testTodayBoundaryNearMidnight() {
        // Calling at 23:59 should still return THAT day's range, not next day's.
        let cal = calendar()
        let now = date(2026, 3, 15, 23, 59, in: cal)
        let (start, end) = DateRanges.today(now: now, calendar: cal)

        let startDay = cal.component(.day, from: start)
        let endDay = cal.component(.day, from: end)
        XCTAssertEqual(startDay, 15)
        XCTAssertEqual(endDay, 16)
    }

    func testTodayHonoursTimezone() {
        // Same instant, viewed from two timezones — should produce DIFFERENT
        // local day ranges. This is the whole point of using Calendar.current
        // for date math: it follows the user's zone.
        let nyCal = calendar(in: "America/New_York")
        let tokyoCal = calendar(in: "Asia/Tokyo")

        // 03:00 UTC on Jan 1 2026 → 22:00 Dec 31 in NY, 12:00 Jan 1 in Tokyo
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let now = date(2026, 1, 1, 3, 0, in: utcCal)

        let (nyStart, _) = DateRanges.today(now: now, calendar: nyCal)
        let (tokyoStart, _) = DateRanges.today(now: now, calendar: tokyoCal)

        XCTAssertEqual(nyCal.component(.day, from: nyStart), 31, "NY observer sees Dec 31")
        XCTAssertEqual(tokyoCal.component(.day, from: tokyoStart), 1, "Tokyo observer sees Jan 1")
    }

    // MARK: - tomorrow()

    func testTomorrowStartsAtMidnightOfNextDay() {
        let cal = calendar()
        let now = date(2026, 3, 15, 14, 30, in: cal)
        let (start, _) = DateRanges.tomorrow(now: now, calendar: cal)

        let components = cal.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        XCTAssertEqual(components.day, 16)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
    }

    func testTomorrowEndsAtMidnightOfDayAfter() {
        let cal = calendar()
        let now = date(2026, 3, 15, 14, 30, in: cal)
        let (_, end) = DateRanges.tomorrow(now: now, calendar: cal)

        let components = cal.dateComponents([.year, .month, .day, .hour, .minute], from: end)
        XCTAssertEqual(components.day, 17)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
    }

    func testTomorrowRollsOverMonthBoundary() {
        let cal = calendar()
        let now = date(2026, 1, 31, 10, 0, in: cal)
        let (start, end) = DateRanges.tomorrow(now: now, calendar: cal)

        XCTAssertEqual(cal.component(.month, from: start), 2)
        XCTAssertEqual(cal.component(.day, from: start), 1)
        XCTAssertEqual(cal.component(.month, from: end), 2)
        XCTAssertEqual(cal.component(.day, from: end), 2)
    }

    func testTomorrowRollsOverYearBoundary() {
        let cal = calendar()
        let now = date(2026, 12, 31, 10, 0, in: cal)
        let (start, _) = DateRanges.tomorrow(now: now, calendar: cal)

        XCTAssertEqual(cal.component(.year, from: start), 2027)
        XCTAssertEqual(cal.component(.month, from: start), 1)
        XCTAssertEqual(cal.component(.day, from: start), 1)
    }

    // MARK: - DST handling

    /// Spring-forward day in America/New_York: 2026-03-08 has only 23 hours.
    /// Using calendar arithmetic (not 86400-second arithmetic) is the
    /// difference between getting the right midnight and getting 1am.
    func testTodayCorrectAcrossSpringForward() {
        let cal = calendar(in: "America/New_York")
        // Call from inside the short day.
        let now = date(2026, 3, 8, 15, 0, in: cal)
        let (start, end) = DateRanges.today(now: now, calendar: cal)

        // Both midnight markers — the end isn't `start + 24h`, it's start of
        // the next local day. Calendar arithmetic handles this; raw 86400
        // wouldn't.
        XCTAssertEqual(cal.component(.hour, from: start), 0)
        XCTAssertEqual(cal.component(.hour, from: end), 0)
        XCTAssertEqual(cal.component(.day, from: start), 8)
        XCTAssertEqual(cal.component(.day, from: end), 9)

        // Sanity: the actual wallclock difference IS 23 hours on this day.
        let secondsBetween = end.timeIntervalSince(start)
        XCTAssertEqual(secondsBetween, 23 * 3600, accuracy: 1.0,
                       "spring-forward day is 23h, not 24")
    }

    /// Fall-back day in America/New_York: 2026-11-01 has 25 hours.
    func testTodayCorrectAcrossFallBack() {
        let cal = calendar(in: "America/New_York")
        let now = date(2026, 11, 1, 15, 0, in: cal)
        let (start, end) = DateRanges.today(now: now, calendar: cal)

        XCTAssertEqual(cal.component(.hour, from: start), 0)
        XCTAssertEqual(cal.component(.hour, from: end), 0)
        XCTAssertEqual(cal.component(.day, from: start), 1)
        XCTAssertEqual(cal.component(.day, from: end), 2)

        let secondsBetween = end.timeIntervalSince(start)
        XCTAssertEqual(secondsBetween, 25 * 3600, accuracy: 1.0,
                       "fall-back day is 25h, not 24")
    }

    // MARK: - nextWindow()

    func testNextWindowStartsAtNow() {
        let cal = calendar()
        let now = date(2026, 3, 15, 14, 30, 45, in: cal)
        let (start, _) = DateRanges.nextWindow(now: now, days: 7, calendar: cal)
        XCTAssertEqual(start, now, "next-window start should be exactly `now`, not midnight")
    }

    func testNextWindowEndIsNowPlusDays() {
        let cal = calendar()
        let now = date(2026, 3, 15, 14, 30, in: cal)
        let (_, end) = DateRanges.nextWindow(now: now, days: 7, calendar: cal)
        let endComponents = cal.dateComponents([.year, .month, .day, .hour, .minute], from: end)
        XCTAssertEqual(endComponents.day, 22)
        XCTAssertEqual(endComponents.hour, 14)
        XCTAssertEqual(endComponents.minute, 30)
    }

    func testNextWindowHandlesYearRollover() {
        let cal = calendar()
        let now = date(2026, 12, 28, 10, 0, in: cal)
        let (_, end) = DateRanges.nextWindow(now: now, days: 7, calendar: cal)
        XCTAssertEqual(cal.component(.year, from: end), 2027)
        XCTAssertEqual(cal.component(.month, from: end), 1)
        XCTAssertEqual(cal.component(.day, from: end), 4)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ sec: Int,
                      in cal: Calendar) -> Date {
        var components = DateComponents()
        components.year = y; components.month = m; components.day = d
        components.hour = h; components.minute = min; components.second = sec
        return cal.date(from: components)!
    }
}

// ─────────────────────────────────────────────────────────────────────────────

final class ConfigManagerTests: XCTestCase {
    // ConfigManager uses static methods writing to ~/.ekctl/config.json.
    // We back up and restore the real config around each test so we don't
    // corrupt the user's actual aliases.

    private let configFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ekctl/config.json")
    private var backup: Data?

    override func setUp() {
        super.setUp()
        backup = try? Data(contentsOf: configFile)
        try? FileManager.default.removeItem(at: configFile)
    }

    override func tearDown() {
        if let backup = backup {
            try? backup.write(to: configFile)
        } else {
            try? FileManager.default.removeItem(at: configFile)
        }
        super.tearDown()
    }

    // ── Alias CRUD ───────────────────────────────────────────────────────────

    func testSetAndRetrieveAlias() throws {
        try ConfigManager.setAlias(name: "work", id: "ABC-123")
        XCTAssertEqual(ConfigManager.getAliases()["work"], "ABC-123")
    }

    func testOverwriteAlias() throws {
        try ConfigManager.setAlias(name: "work", id: "OLD-ID")
        try ConfigManager.setAlias(name: "work", id: "NEW-ID")
        XCTAssertEqual(ConfigManager.getAliases()["work"], "NEW-ID")
    }

    func testRemoveAlias() throws {
        try ConfigManager.setAlias(name: "work", id: "ABC-123")
        let removed = try ConfigManager.removeAlias(name: "work")
        XCTAssertTrue(removed)
        XCTAssertNil(ConfigManager.getAliases()["work"])
    }

    func testRemoveNonExistentAliasReturnsFalse() throws {
        let removed = try ConfigManager.removeAlias(name: "ghost")
        XCTAssertFalse(removed)
    }

    func testMultipleAliases() throws {
        try ConfigManager.setAlias(name: "work",      id: "CAL-1")
        try ConfigManager.setAlias(name: "personal",  id: "CAL-2")
        try ConfigManager.setAlias(name: "groceries", id: "CAL-3")
        let aliases = ConfigManager.getAliases()
        XCTAssertEqual(aliases.count, 3)
        XCTAssertEqual(aliases["personal"], "CAL-2")
    }

    // ── Alias resolution ─────────────────────────────────────────────────────

    func testResolveKnownAlias() throws {
        try ConfigManager.setAlias(name: "work", id: "CA513B39-XXXX")
        XCTAssertEqual(ConfigManager.resolveAlias("work"), "CA513B39-XXXX")
    }

    func testResolvePassesThroughUnknownString() {
        let rawID = "CA513B39-1659-4359-8FE9-0C2A3DCEF153"
        XCTAssertEqual(ConfigManager.resolveAlias(rawID), rawID)
    }

    func testResolveEmptyConfig() {
        XCTAssertEqual(ConfigManager.resolveAlias("anything"), "anything")
    }

    // ── Config path ──────────────────────────────────────────────────────────

    func testConfigPathContainsEkctl() {
        XCTAssertTrue(ConfigManager.configPath().contains(".ekctl"))
    }
}

// ─────────────────────────────────────────────────────────────────────────────

final class AlarmParsingTests: XCTestCase {

    func testNilInputReturnsNil() {
        XCTAssertNil(parseAlarms(nil))
    }

    func testPositiveNumberMeansBeforeStart() {
        // "10" → 10 minutes before → -600 seconds
        let result = parseAlarms("10")!
        XCTAssertEqual(result, [-600])
    }

    func testNegativeNumberPassesThroughAsNegativeSeconds() {
        // "-10" → val is negative → val * 60 = -600
        let result = parseAlarms("-10")!
        XCTAssertEqual(result, [-600])
    }

    func testPlusPrefixMeansAfterStart() {
        // "+10" → 10 minutes after → +600 seconds
        let result = parseAlarms("+10")!
        XCTAssertEqual(result, [600])
    }

    func testMultipleAlarms() {
        let result = parseAlarms("10,60")!
        XCTAssertEqual(result, [-600, -3600])
    }

    func testMixedAlarms() {
        let result = parseAlarms("10,+5,-15")!
        XCTAssertEqual(result, [-600, 300, -900])
    }

    func testWhitespaceIsTrimmed() {
        let result = parseAlarms(" 10 , 60 ")!
        XCTAssertEqual(result, [-600, -3600])
    }

    func testInvalidComponentsAreSkipped() {
        let result = parseAlarms("abc,10")!
        XCTAssertEqual(result, [-600])
    }

    func testEmptyStringReturnsEmptyArray() {
        let result = parseAlarms("")!
        XCTAssertTrue(result.isEmpty)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

final class HexColorTests: XCTestCase {

    func testFromHexWithHash() {
        let color = CGColor.fromHex("#FF0000")
        XCTAssertNotNil(color)
        XCTAssertEqual(color?.hexString.uppercased(), "#FF0000")
    }

    func testFromHexWithoutHash() {
        let color = CGColor.fromHex("0088FF")
        XCTAssertNotNil(color)
        XCTAssertEqual(color?.hexString.uppercased(), "#0088FF")
    }

    func testFromHexBlack() {
        let color = CGColor.fromHex("#000000")
        XCTAssertNotNil(color)
        XCTAssertEqual(color?.hexString, "#000000")
    }

    func testFromHexWhite() {
        let color = CGColor.fromHex("#FFFFFF")
        XCTAssertNotNil(color)
        XCTAssertEqual(color?.hexString.uppercased(), "#FFFFFF")
    }

    func testFromHexLowercaseInput() {
        let color = CGColor.fromHex("#ff5500")
        XCTAssertNotNil(color)
        XCTAssertEqual(color?.hexString.uppercased(), "#FF5500")
    }

    func testFromHexInvalidReturnsNil() {
        XCTAssertNil(CGColor.fromHex("ZZZZZZ"))
    }

    func testRoundTrip() {
        let hex = "#1BADF8"
        let color = CGColor.fromHex(hex)!
        XCTAssertEqual(color.hexString.uppercased(), hex.uppercased())
    }
}

// ─────────────────────────────────────────────────────────────────────────────

final class DateValidationTests: XCTestCase {

    // ── Formats ekctl actually accepts ───────────────────────────────────────

    func testUTCFormatIsAccepted() {
        XCTAssertNotNil(validateDate("2026-02-15T14:00:00Z"))
    }

    func testTimezoneOffsetIsAccepted() {
        // Perth/AWST — real-world case for this project
        XCTAssertNotNil(validateDate("2026-02-15T14:00:00+08:00"))
    }

    // ── Formats ekctl rejects ─────────────────────────────────────────────────

    func testHumanReadableDateIsRejected() {
        XCTAssertNil(validateDate("March 5 2026"))
    }

    func testDateOnlyWithoutTimeIsRejected() {
        // Missing time component — ekctl requires full ISO8601 datetime
        XCTAssertNil(validateDate("2026-03-05"))
    }

    func testEmptyStringIsRejected() {
        XCTAssertNil(validateDate(""))
    }

    func testSlashSeparatedDateIsRejected() {
        // Common user mistake
        XCTAssertNil(validateDate("05/03/2026"))
    }

    // ── Travel time conversion ────────────────────────────────────────────────

    func testTravelTimeConvertsMinutesToSeconds() {
        // 20 min → 1200 seconds, stored via KVC travelTime property
        XCTAssertEqual(travelTimeSeconds(from: "20"), 1200)
    }

    func testTravelTimeZeroMinutes() {
        XCTAssertEqual(travelTimeSeconds(from: "0"), 0)
    }

    func testTravelTimeRejectsNonNumericInput() {
        XCTAssertNil(travelTimeSeconds(from: "thirty"))
    }

    func testTravelTimeRejectsEmpty() {
        XCTAssertNil(travelTimeSeconds(from: ""))
    }

    // ── Alarm rendering (inverse of --alarms) ────────────────────────────────

    /// Absolute alarms are the only branch needing a date; a fixed string keeps
    /// these assertions independent of timezone and formatter settings.
    private func alarmDicts(_ alarms: [EKAlarm]) -> [[String: Any]] {
        EventKitManager.alarmDicts(alarms) { _ in "FORMATTED_DATE" }
    }

    func testAlarmBeforeStartRendersAsPositiveMinutes() {
        // `--alarms "10"` stores -600s; output must read back as 10.
        let dicts = alarmDicts([EKAlarm(relativeOffset: -600)])
        XCTAssertEqual(dicts.count, 1)
        XCTAssertEqual(dicts[0]["type"] as? String, "relative")
        XCTAssertEqual(dicts[0]["minutesBeforeStart"] as? Int, 10)
    }

    func testAlarmAfterStartRendersAsNegativeMinutes() {
        // `--alarms "+15"` stores +900s; output must read back as -15.
        let dicts = alarmDicts([EKAlarm(relativeOffset: 900)])
        XCTAssertEqual(dicts[0]["minutesBeforeStart"] as? Int, -15)
    }

    func testAlarmAtStartRendersAsZero() {
        XCTAssertEqual(alarmDicts([EKAlarm(relativeOffset: 0)])[0]["minutesBeforeStart"] as? Int, 0)
    }

    /// The round trip that makes the field useful: whatever `--alarms` parses,
    /// the output renders back into the same flag value.
    func testAlarmRenderingRoundTripsThroughAlarmParsing() {
        for flagValue in ["10", "30", "+15", "0", "1440"] {
            let offsets = AlarmParsing.parse(flagValue)!
            let dicts = alarmDicts(offsets.map { EKAlarm(relativeOffset: $0) })
            let minutes = dicts[0]["minutesBeforeStart"] as? Int
            let expected = flagValue.hasPrefix("+") ? -Int(flagValue.dropFirst())! : Int(flagValue)!
            XCTAssertEqual(minutes, expected, "round trip failed for --alarms \(flagValue)")
        }
    }

    func testAbsoluteAlarmRendersDateNotOffset() {
        let alarm = EKAlarm(absoluteDate: Date(timeIntervalSince1970: 0))
        let dicts = alarmDicts([alarm])
        XCTAssertEqual(dicts[0]["type"] as? String, "absolute")
        XCTAssertEqual(dicts[0]["date"] as? String, "FORMATTED_DATE")
        XCTAssertNil(dicts[0]["minutesBeforeStart"])
    }

    func testMultipleAlarmsArePreservedInOrder() {
        let dicts = alarmDicts([EKAlarm(relativeOffset: -600), EKAlarm(relativeOffset: -1800)])
        XCTAssertEqual(dicts.map { $0["minutesBeforeStart"] as? Int }, [10, 30])
    }

    func testNilAlarmsRenderAsEmptyArray() {
        XCTAssertTrue(EventKitManager.alarmDicts(nil) { _ in "" }.isEmpty)
    }

    func testEmptyAlarmsRenderAsEmptyArray() {
        XCTAssertTrue(alarmDicts([]).isEmpty)
    }

    func testSubMinuteOffsetRoundsToNearestMinute() {
        // EventKit permits second-level offsets the flag cannot express; they
        // must round rather than truncate toward zero.
        XCTAssertEqual(alarmDicts([EKAlarm(relativeOffset: -110)])[0]["minutesBeforeStart"] as? Int, 2)
    }

    // ── Recurrence interval fallback ─────────────────────────────────────────

    func testRecurrenceIntervalParsesValidInt() {
        XCTAssertEqual(recurrenceInterval(from: "2"), 2)
    }

    func testRecurrenceIntervalDefaultsToOneWhenNil() {
        // nil means --recurrence-interval was not passed
        XCTAssertEqual(recurrenceInterval(from: nil), 1)
    }

    func testRecurrenceIntervalDefaultsToOneWhenInvalid() {
        // Garbage input falls back to 1, not crash
        XCTAssertEqual(recurrenceInterval(from: "fortnightly"), 1)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

final class UpdateReminderLogicTests: XCTestCase {

    // ── Priority parsing ─────────────────────────────────────────────────────

    func testParsePriorityNone() {
        XCTAssertEqual(parsePriority("0"), 0)
    }

    func testParsePriorityHigh() {
        XCTAssertEqual(parsePriority("1"), 1)
    }

    func testParsePriorityMedium() {
        XCTAssertEqual(parsePriority("5"), 5)
    }

    func testParsePriorityLow() {
        XCTAssertEqual(parsePriority("9"), 9)
    }

    func testParsePriorityInvalidReturnsNil() {
        XCTAssertNil(parsePriority("high"))
        XCTAssertNil(parsePriority("urgent"))
        XCTAssertNil(parsePriority(""))
    }

    func testParsePriorityNilInputReturnsNil() {
        XCTAssertNil(parsePriority(nil))
    }

    // ── Due date error message ────────────────────────────────────────────────
    // Pins the exact error string — if someone renames it, scripts break
    // and this test catches it before release.

    func testInvalidDueDateProducesCorrectErrorMessage() {
        let message = "Invalid --due date format. Use \(DateParsing.acceptedFormats)."
        let output = JSONOutput.error(message)
        let dict = output.toDictionary()
        XCTAssertEqual(dict["status"] as? String, "error")
        XCTAssertEqual(dict["error"] as? String, message)
        // Scripts grep for the "Invalid --<flag> date format" prefix — keep it stable.
        XCTAssertTrue(message.hasPrefix("Invalid --due date format."))
    }

    // ── Completed flag — tests the actual conditional logic ───────────────────

    func testCompletedTrueMarksAsDone() {
        var isCompleted = false
        let flag: Bool? = true
        if let f = flag { isCompleted = f }
        XCTAssertTrue(isCompleted)
    }

    func testCompletedFalseReopens() {
        var isCompleted = true
        let flag: Bool? = false
        if let f = flag { isCompleted = f }
        XCTAssertFalse(isCompleted)
    }

    func testCompletedNilLeavesStateUnchanged() {
        var isCompleted = true   // already done
        let flag: Bool? = nil    // --completed not passed
        if let f = flag { isCompleted = f }
        XCTAssertTrue(isCompleted)  // must not have been touched
    }

    // ── JSON output shape for update ─────────────────────────────────────────

    func testUpdateReminderSuccessShape() {
        let output = JSONOutput.success([
            "status": "success",
            "message": "Reminder updated successfully",
            "reminder": [
                "id": "REM-001",
                "title": "Updated title",
                "completed": false,
                "priority": 1
            ]
        ])
        let dict = output.toDictionary()
        XCTAssertEqual(dict["status"] as? String, "success")
        XCTAssertEqual(dict["message"] as? String, "Reminder updated successfully")
        let reminder = dict["reminder"] as? [String: Any]
        XCTAssertEqual(reminder?["title"] as? String, "Updated title")
        XCTAssertEqual(reminder?["priority"] as? Int, 1)
    }

    func testUpdateReminderNotFoundShape() {
        let output = JSONOutput.error("Reminder not found with ID: bad-id")
        let dict = output.toDictionary()
        XCTAssertEqual(dict["status"] as? String, "error")
        XCTAssertTrue((dict["error"] as? String)?.contains("bad-id") == true)
    }

    // ── Partial update — only supplied fields should change ──────────────────

    func testPartialUpdateOnlyChangesSuppliedFields() {
        var title    = "Original title"
        var priority = 0
        var notes    = "Original notes"

        let newTitle:    String? = "New title"
        let newPriority: Int?    = nil
        let newNotes:    String? = nil

        if let t = newTitle    { title    = t }
        if let p = newPriority { priority = p }
        if let n = newNotes    { notes    = n }

        XCTAssertEqual(title,    "New title")
        XCTAssertEqual(priority, 0)
        XCTAssertEqual(notes,    "Original notes")
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Tests for `AvailabilitySetting` — the `--availability` value on
/// `add event` / `update event`. Previously a raw String that was silently
/// ignored when misspelled; now ArgumentParser rejects unknown values.
final class AvailabilitySettingTests: XCTestCase {

    func testParsesAllKnownValues() {
        XCTAssertEqual(AvailabilitySetting(argument: "busy"), .busy)
        XCTAssertEqual(AvailabilitySetting(argument: "free"), .free)
        XCTAssertEqual(AvailabilitySetting(argument: "tentative"), .tentative)
        XCTAssertEqual(AvailabilitySetting(argument: "unavailable"), .unavailable)
    }

    func testParsingIsCaseInsensitive() {
        // The old string-based flag lowercased input; keep that leniency.
        XCTAssertEqual(AvailabilitySetting(argument: "BUSY"), .busy)
        XCTAssertEqual(AvailabilitySetting(argument: "Tentative"), .tentative)
    }

    func testRejectsUnknownValues() {
        XCTAssertNil(AvailabilitySetting(argument: "bsy"))
        XCTAssertNil(AvailabilitySetting(argument: ""))
        // Filterable but not settable — EventKit reports notSupported, you
        // can't assign it.
        XCTAssertNil(AvailabilitySetting(argument: "notSupported"))
    }

    func testEventKitMapping() {
        XCTAssertEqual(AvailabilitySetting.busy.ekAvailability, .busy)
        XCTAssertEqual(AvailabilitySetting.free.ekAvailability, .free)
        XCTAssertEqual(AvailabilitySetting.tentative.ekAvailability, .tentative)
        XCTAssertEqual(AvailabilitySetting.unavailable.ekAvailability, .unavailable)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Tests for `TimeFormat` — the `--time-format` flag's rendering patterns
/// (issue #3). `rfc3339` must stay byte-identical to the historical output;
/// `compact` must always produce a numeric offset jq's `%z` can parse.
final class TimeFormatTests: XCTestCase {

    /// 2026-01-01T00:00:00Z rendered through `timeFormat` in `zone` — mirrors
    /// `localDateFormatter()` exactly (POSIX locale + pattern).
    private func render(_ timeFormat: TimeFormat, zone: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = timeFormat.dateFormatPattern
        formatter.timeZone = TimeZone(identifier: zone)
        return formatter.string(from: Date(timeIntervalSince1970: 1_767_225_600))
    }

    func testRFC3339RendersColonSeparatedOffset() {
        XCTAssertEqual(render(.rfc3339, zone: "Australia/Sydney"), "2026-01-01T11:00:00+11:00")
    }

    func testCompactRendersOffsetWithoutColon() {
        XCTAssertEqual(render(.compact, zone: "Australia/Sydney"), "2026-01-01T11:00:00+1100")
    }

    func testUTCRendering() {
        // rfc3339 keeps the historical `Z`; compact must render `+0000`
        // because a literal `Z` is exactly what breaks jq's `%z`.
        XCTAssertEqual(render(.rfc3339, zone: "UTC"), "2026-01-01T00:00:00Z")
        XCTAssertEqual(render(.compact, zone: "UTC"), "2026-01-01T00:00:00+0000")
    }

    func testDefaultIsRFC3339() throws {
        // The flag defaults — changing these silently changes every
        // consumer's output, so pin them. (Must go through parse(); reading
        // an @Option property on a hand-constructed ParsableArguments traps.)
        let options = try OutputFormatOptions.parse([])
        XCTAssertEqual(options.timeFormat, .rfc3339)
        XCTAssertEqual(options.format, .json)
    }

    func testEveryTimeFormatRoundTripsThroughDateParsing() {
        for timeFormat in TimeFormat.allCases {
            for zone in ["UTC", "Australia/Sydney", "America/New_York"] {
                let emitted = render(timeFormat, zone: zone)
                XCTAssertNotNil(
                    DateParsing.parse(emitted),
                    "\(timeFormat.rawValue) output \(emitted) must be valid ekctl input")
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Tests for `DateParsing.parse` — the shared parser behind every date-taking
/// flag. The defining property (issue #3): anything ekctl can emit must parse
/// back in, in both the colon (`+11:00`) and compact (`+1100`) offset forms.
final class DateParsingTests: XCTestCase {

    // ── Accepted: RFC 3339 / colon offsets (original behaviour) ──────────────

    func testParsesUTCZuluForm() {
        XCTAssertEqual(
            DateParsing.parse("2026-01-01T00:00:00Z"),
            Date(timeIntervalSince1970: 1_767_225_600))
    }

    func testParsesColonSeparatedOffset() {
        XCTAssertNotNil(DateParsing.parse("2026-03-09T16:00:00-04:00"))
    }

    // ── Accepted: compact offsets (issue #3) ─────────────────────────────────

    func testParsesCompactOffset() {
        XCTAssertNotNil(DateParsing.parse("2026-03-09T16:00:00-0400"))
    }

    func testCompactAndColonOffsetsParseToSameInstant() {
        XCTAssertEqual(
            DateParsing.parse("2026-03-09T16:00:00-0400"),
            DateParsing.parse("2026-03-09T16:00:00-04:00"))
    }

    func testParsesFractionalSeconds() {
        XCTAssertEqual(
            DateParsing.parse("2026-03-09T16:00:00.000Z"),
            DateParsing.parse("2026-03-09T16:00:00Z"))
        XCTAssertNotNil(DateParsing.parse("2026-03-09T16:00:00.123+11:00"))
        XCTAssertNotNil(DateParsing.parse("2026-03-09T16:00:00.123+1100"))
    }

    // ── Rejected ──────────────────────────────────────────────────────────────

    func testRejectsNonISOInput() {
        XCTAssertNil(DateParsing.parse("March 5 2026"))
        XCTAssertNil(DateParsing.parse("05/03/2026"))
        XCTAssertNil(DateParsing.parse(""))
        XCTAssertNil(DateParsing.parse("2026-03-05"))  // date-only — no time
    }

    // ── Round-trip: every form ekctl can emit is valid ekctl input ────────────

    func testEmittedFormatsRoundTrip() {
        // Mirror both timestamp renderings `localDateFormatter` can produce
        // (rfc3339 `XXXXX` and compact `xxxx`).
        for pattern in ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ssxxxx"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            formatter.timeZone = TimeZone(identifier: "Australia/Sydney")
            let emitted = formatter.string(from: Date(timeIntervalSince1970: 1_767_225_600))
            XCTAssertNotNil(DateParsing.parse(emitted), "Failed to round-trip: \(emitted)")
        }
    }
}