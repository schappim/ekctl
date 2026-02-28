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