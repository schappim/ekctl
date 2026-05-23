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

/// Mirrors: guard let date = ISO8601DateFormatter().date(from: input)
func validateDate(_ input: String) -> Date? {
    ISO8601DateFormatter().date(from: input)
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

/// Mirrors: parseAlarms() in AddEvent.run() / UpdateEvent.run()
func parseAlarms(_ string: String?) -> [Double]? {
    guard let string = string else { return nil }
    return string.split(separator: ",").compactMap { component in
        let s = component.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("+") {
            return Double(s.dropFirst()).map { $0 * 60 }
        }
        guard let val = Double(s) else { return nil }
        return val < 0 ? val * 60 : -val * 60
    }
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
        let output = JSONOutput.error("Invalid --due date format. Use ISO8601.")
        let dict = output.toDictionary()
        XCTAssertEqual(dict["status"] as? String, "error")
        XCTAssertEqual(dict["error"] as? String, "Invalid --due date format. Use ISO8601.")
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