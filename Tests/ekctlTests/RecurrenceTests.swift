import EventKit
import XCTest
@testable import ekctlCore

final class RecurrenceParsingTests: XCTestCase {

    private func parse(
        frequency: String? = nil, interval: String? = nil, endCount: String? = nil,
        endDate: Date? = nil, clearEndDate: Bool = false, days: String? = nil,
        months: String? = nil, daysOfMonth: String? = nil, weeksOfYear: String? = nil,
        daysOfYear: String? = nil, setPositions: String? = nil, allowNone: Bool = true
    ) throws -> RecurrenceSpec {
        try RecurrenceParsing.parse(
            frequency: frequency, interval: interval, endCount: endCount, endDate: endDate,
            clearEndDate: clearEndDate, days: days, months: months, daysOfMonth: daysOfMonth,
            weeksOfYear: weeksOfYear, daysOfYear: daysOfYear, setPositions: setPositions,
            allowNone: allowNone)
    }

    private func assertRejects(
        _ message: String, file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> RecurrenceSpec
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertTrue(
                "\(error)".contains(message), "\"\(error)\" should mention \"\(message)\"",
                file: file, line: line)
        }
    }

    // MARK: Frequency

    func testNoFlagsIsEmpty() throws {
        let spec = try parse()
        XCTAssertTrue(spec.isEmpty)
        XCTAssertFalse(spec.hasRuleDetails)
        XCTAssertFalse(spec.removesRecurrence)
    }

    func testFrequencyIsCaseInsensitive() throws {
        XCTAssertEqual(try parse(frequency: "Weekly").frequency, .some(.weekly))
        XCTAssertEqual(try parse(frequency: " YEARLY ").frequency, .some(.yearly))
    }

    func testNoneRemovesRecurrenceOnUpdate() throws {
        let spec = try parse(frequency: "none")
        XCTAssertTrue(spec.removesRecurrence)
        XCTAssertFalse(spec.isEmpty)
    }

    func testNoneIsRejectedOnAdd() {
        assertRejects("only applies to update") { try self.parse(frequency: "none", allowNone: false) }
    }

    func testNoneCannotCarryOtherRecurrenceFlags() {
        assertRejects("can't be combined") { try self.parse(frequency: "none", endCount: "3") }
    }

    func testUnknownFrequencyIsRejected() {
        assertRejects("Invalid --recurrence-frequency \"fortnightly\"") {
            try self.parse(frequency: "fortnightly")
        }
    }

    // MARK: Interval and end

    func testIntervalMustBePositiveWholeNumber() throws {
        XCTAssertEqual(try parse(interval: "2").interval, 2)
        assertRejects("--recurrence-interval \"0\"") { try self.parse(interval: "0") }
        assertRejects("--recurrence-interval \"two\"") { try self.parse(interval: "two") }
        assertRejects("--recurrence-interval \"1.5\"") { try self.parse(interval: "1.5") }
    }

    func testEndCountAndEndDateAreExclusive() {
        assertRejects("not both") { try self.parse(endCount: "3", endDate: Date()) }
        assertRejects("not both") { try self.parse(endCount: "3", clearEndDate: true) }
    }

    func testEndForms() throws {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(try parse(endCount: "4").end, .count(4))
        XCTAssertEqual(try parse(endDate: date).end, .date(date))
        XCTAssertEqual(try parse(clearEndDate: true).end, .never)
        assertRejects("--recurrence-end-count \"0\"") { try self.parse(endCount: "0") }
    }

    // MARK: Days of the week

    func testDaysAcceptNamesAndWeekNumbers() throws {
        let days = try RecurrenceParsing.parseDays("mon, Wednesday,1mon,-1fri,+2sun")
        XCTAssertEqual(days, [
            RecurrenceDay(weekday: 2), RecurrenceDay(weekday: 4),
            RecurrenceDay(weekday: 2, week: 1), RecurrenceDay(weekday: 6, week: -1),
            RecurrenceDay(weekday: 1, week: 2),
        ])
    }

    func testDaysFormatRoundTrips() throws {
        let input = "mon,1mon,-1fri,sat"
        let days = try RecurrenceParsing.parseDays(input)
        XCTAssertEqual(days.map(\.formatted).joined(separator: ","), input)
    }

    func testDaysRejectTyposWeekZeroAndEmptyEntries() {
        assertRejects("\"mnd\"") { RecurrenceSpec(daysOfTheWeek: try RecurrenceParsing.parseDays("mon,mnd")) }
        assertRejects("week in --recurrence-days value \"0mon\"") {
            RecurrenceSpec(daysOfTheWeek: try RecurrenceParsing.parseDays("0mon"))
        }
        assertRejects("week in --recurrence-days value \"54mon\"") {
            RecurrenceSpec(daysOfTheWeek: try RecurrenceParsing.parseDays("54mon"))
        }
        assertRejects("empty value") { RecurrenceSpec(daysOfTheWeek: try RecurrenceParsing.parseDays("mon,,wed")) }
        assertRejects("\"--mon\"") { RecurrenceSpec(daysOfTheWeek: try RecurrenceParsing.parseDays("--mon")) }
    }

    // MARK: Numeric lists

    func testMonthsAcceptNumbersAndNames() throws {
        XCTAssertEqual(try RecurrenceParsing.parseMonths("1,jul,December"), [1, 7, 12])
        assertRejects("\"13\"") { RecurrenceSpec(monthsOfTheYear: try RecurrenceParsing.parseMonths("13")) }
        assertRejects("\"0\"") { RecurrenceSpec(monthsOfTheYear: try RecurrenceParsing.parseMonths("0")) }
    }

    /// Zero and out-of-range values would otherwise reach EKRecurrenceRule,
    /// which can raise an uncatchable Objective-C exception for them.
    func testSignedListsRejectZeroAndOutOfRange() throws {
        XCTAssertEqual(try parse(daysOfMonth: "1,15,-1").daysOfTheMonth, [1, 15, -1])
        assertRejects("--recurrence-days-of-month value \"0\"") { try self.parse(daysOfMonth: "0") }
        assertRejects("--recurrence-days-of-month value \"32\"") { try self.parse(daysOfMonth: "32") }
        assertRejects("--recurrence-weeks-of-year value \"-54\"") { try self.parse(weeksOfYear: "-54") }
        assertRejects("--recurrence-days-of-year value \"367\"") { try self.parse(daysOfYear: "367") }
        assertRejects("--recurrence-set-positions value \"x\"") { try self.parse(setPositions: "x") }
    }

    // MARK: Merging onto an existing rule

    func testFrequencyStartsAFreshRule() throws {
        var base = RecurrenceSpec()
        base.frequency = .some(.weekly)
        base.daysOfTheWeek = [RecurrenceDay(weekday: 2)]
        base.end = .count(10)
        let change = try parse(frequency: "monthly")
        var expected = change
        expected.end = .count(10)  // the end isn't tied to the frequency, so it carries over
        XCTAssertEqual(change.applying(to: base), expected)
        XCTAssertEqual(try parse(frequency: "monthly", clearEndDate: true).applying(to: base).end, .never)
    }

    func testChangesOnlyEnd() throws {
        XCTAssertTrue(try parse(endCount: "3").changesOnlyEnd)
        XCTAssertTrue(try parse(clearEndDate: true).changesOnlyEnd)
        XCTAssertFalse(try parse(interval: "2", endCount: "3").changesOnlyEnd)
        XCTAssertFalse(try parse().changesOnlyEnd)
    }

    func testDetailsModifyTheExistingRule() throws {
        var base = RecurrenceSpec()
        base.frequency = .some(.weekly)
        base.interval = 2
        base.daysOfTheWeek = [RecurrenceDay(weekday: 2)]
        base.end = .count(10)
        let merged = try parse(endCount: "4").applying(to: base)
        XCTAssertEqual(merged.frequency, .some(.weekly))
        XCTAssertEqual(merged.interval, 2)
        XCTAssertEqual(merged.daysOfTheWeek, [RecurrenceDay(weekday: 2)])
        XCTAssertEqual(merged.end, .count(4))
    }

    func testDetailsWithoutAnExistingRuleHaveNoFrequency() throws {
        let merged = try parse(endCount: "4").applying(to: nil)
        XCTAssertNil(merged.ekRule, "There's nothing to build without a frequency")
    }

    // MARK: Frequency/field validation

    func testFieldsThatDontApplyToTheFrequencyAreRejected() throws {
        func check(_ spec: RecurrenceSpec, _ message: String, line: UInt = #line) {
            XCTAssertThrowsError(try spec.validate(against: spec), line: line) {
                XCTAssertTrue("\($0)".contains(message), "\($0)", line: line)
            }
        }
        check(try parse(frequency: "daily", days: "mon"), "--recurrence-days doesn't apply to a daily")
        check(try parse(frequency: "weekly", days: "1mon"), "week number")
        check(try parse(frequency: "weekly", daysOfMonth: "1"), "--recurrence-days-of-month doesn't apply")
        check(try parse(frequency: "monthly", months: "jan"), "--recurrence-months doesn't apply")
        check(try parse(frequency: "monthly", weeksOfYear: "1"), "--recurrence-weeks-of-year")
        check(try parse(frequency: "weekly", daysOfYear: "1"), "--recurrence-days-of-year")
        check(try parse(frequency: "monthly", setPositions: "-1"), "--recurrence-set-positions picks")
    }

    func testMonthlyWeekNumbersStayWithinAMonth() throws {
        let sixth = try parse(frequency: "monthly", days: "6mon")
        XCTAssertThrowsError(try sixth.validate(against: sixth)) { XCTAssertTrue("\($0)".contains("1 to 5")) }
        let lastButFour = try parse(frequency: "monthly", days: "-5fri")
        XCTAssertNoThrow(try lastButFour.validate(against: lastButFour))
        let yearly = try parse(frequency: "yearly", days: "20mon")
        XCTAssertNoThrow(try yearly.validate(against: yearly), "Yearly rules count weeks of the year")
        let withWeekNumbers = try parse(frequency: "yearly", days: "1mon", weeksOfYear: "10")
        XCTAssertThrowsError(try withWeekNumbers.validate(against: withWeekNumbers))
    }

    func testValidCombinationsPass() throws {
        for spec in [
            try parse(frequency: "weekly", days: "mon,wed,fri"),
            try parse(frequency: "monthly", days: "-1fri"),
            try parse(frequency: "monthly", daysOfMonth: "1,15"),
            try parse(frequency: "yearly", months: "jan", daysOfMonth: nil),
            try parse(frequency: "monthly", days: "mon,tue,wed,thu,fri", setPositions: "-1"),
        ] {
            XCTAssertNoThrow(try spec.validate(against: spec))
        }
    }

    /// An odd rule written by another client shouldn't block an unrelated
    /// edit: only the flags given are checked against the frequency.
    func testValidationIgnoresExistingRuleDetailsTheUserDidntTouch() throws {
        var base = RecurrenceSpec()
        base.frequency = .some(.weekly)
        base.daysOfTheMonth = [1]
        let change = try parse(endCount: "3")
        XCTAssertNoThrow(try change.validate(against: change.applying(to: base)))
    }

    // MARK: EventKit round-trip

    func testSpecRoundTripsThroughEKRecurrenceRule() throws {
        let end = Date(timeIntervalSince1970: 2_000_000_000)
        let spec = try parse(
            frequency: "monthly", interval: "2", endDate: end, days: "mon,wed,fri", setPositions: "-1")
        let rule = try XCTUnwrap(spec.ekRule)
        XCTAssertEqual(rule.frequency, .monthly)
        XCTAssertEqual(rule.interval, 2)
        XCTAssertEqual(rule.recurrenceEnd?.endDate, end)
        XCTAssertEqual(RecurrenceSpec(rule), spec)
    }

    func testCountEndAndWeekNumbersRoundTrip() throws {
        let spec = try parse(frequency: "yearly", interval: "1", endCount: "5", days: "-1fri", months: "nov")
        XCTAssertEqual(RecurrenceSpec(try XCTUnwrap(spec.ekRule)), spec)
    }

    func testRuleWithoutEndReadsBackAsNever() throws {
        let rule = EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        XCTAssertEqual(RecurrenceSpec(rule).end, .never)
    }

    func testOutputUsesFlagVocabulary() throws {
        let spec = try parse(frequency: "weekly", endCount: "3", days: "mon,1tue")
        let dict = RecurrenceSpec(try XCTUnwrap(spec.ekRule)).outputDict { _ in "DATE" }
        XCTAssertEqual(dict["frequency"] as? String, "weekly")
        XCTAssertEqual(dict["interval"] as? Int, 1)
        XCTAssertEqual(dict["daysOfTheWeek"] as? [String], ["mon", "1tue"])
        XCTAssertEqual(dict["endCount"] as? Int, 3)
        XCTAssertTrue(dict["endDate"] is NSNull)
        XCTAssertTrue(dict["daysOfTheMonth"] is NSNull)
    }
}

final class EventSpanTests: XCTestCase {
    func testSpanParsesCaseInsensitively() {
        XCTAssertEqual(EventSpan(argument: "this"), .this)
        XCTAssertEqual(EventSpan(argument: "Future"), .future)
        XCTAssertEqual(EventSpan(argument: "ALL"), .all)
        XCTAssertNil(EventSpan(argument: "series"))
    }

    func testSeriesIDStripsDetachedOccurrenceSuffix() {
        let series = "2BB0249C-0C4F-4EC5-9C0E-67955E974F2A:6DB3987A-F3F5-4927-986E-C5605CEAA578"
        XCTAssertEqual(EventIdentifiers.seriesID(series + "/RID=953161200"), series)
        XCTAssertEqual(EventIdentifiers.seriesID(series), series)
        XCTAssertEqual(EventIdentifiers.seriesID(""), "")
    }
}

private extension RecurrenceSpec {
    init(daysOfTheWeek: [RecurrenceDay]) {
        self.init()
        self.daysOfTheWeek = daysOfTheWeek
    }

    init(monthsOfTheYear: [Int]) {
        self.init()
        self.monthsOfTheYear = monthsOfTheYear
    }
}
