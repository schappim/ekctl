import ArgumentParser
import Foundation

/// Which occurrences of a recurring event an update or delete applies to.
///
/// EventKit only offers `.thisEvent` and `.futureEvents`, and "future" is
/// relative to whichever occurrence you hand it. `all` is therefore not a
/// third EventKit mode but a choice of target: the series' first occurrence,
/// saved or removed with `.futureEvents`.
public enum EventSpan: String, CaseIterable, ExpressibleByArgument {
    /// Only the addressed occurrence. The default, and what non-recurring
    /// events always get.
    case this
    /// The addressed occurrence and every one after it. The series is split
    /// in two: earlier occurrences keep the old identifier, the rest get a
    /// new one, which the output reports.
    case future
    /// Every occurrence in the series, from its first.
    case all

    public static var allValueStrings: [String] { Self.allCases.map(\.rawValue) }

    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

/// The identifier shared by every occurrence of a series.
///
/// Every untouched occurrence of a recurring event carries the same
/// `eventIdentifier`. One edited on its own (a *detached* occurrence) keeps
/// that identifier plus a `/RID=<seconds>` suffix naming the occurrence it
/// replaced. Stripping the suffix recovers the series, which is how an
/// occurrence is matched back to the ID a caller passed and how `--span all`
/// finds the first occurrence. This is structural parsing of EventKit's own
/// identifier format, not a guess about meaning.
public enum EventIdentifiers {
    public static func seriesID(_ eventID: String) -> String {
        guard let range = eventID.range(of: "/RID=") else { return eventID }
        return String(eventID[..<range.lowerBound])
    }
}

/// A day of the week in a recurrence rule, optionally pinned to a week:
/// `mon` (every Monday), `1mon` (the first Monday), `-1fri` (the last
/// Friday). `weekday` uses Calendar numbering, 1 = Sunday ... 7 = Saturday,
/// which is also EventKit's `EKWeekday` raw value.
public struct RecurrenceDay: Equatable {
    public let weekday: Int
    public let week: Int

    public init(weekday: Int, week: Int = 0) {
        self.weekday = weekday
        self.week = week
    }

    static let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// The same spelling `--recurrence-days` accepts, so output round-trips.
    public var formatted: String {
        (week == 0 ? "" : String(week)) + Self.names[weekday - 1]
    }
}

/// A recurrence rule as the CLI describes it, before it touches EventKit.
///
/// Every field is optional so the same type describes both a whole new rule
/// (`add event`) and a partial edit of an existing one (`update event
/// --recurrence-end-count 4` keeps the frequency and days it already had).
public struct RecurrenceSpec: Equatable {
    public enum Frequency: String, CaseIterable {
        case daily, weekly, monthly, yearly
    }

    /// How the series ends. `.never` exists so an update can make a bounded
    /// series open-ended again.
    public enum End: Equatable {
        case never
        case count(Int)
        case date(Date)
    }

    /// `nil`: not given. `.some(nil)`: `none` — remove the recurrence.
    public var frequency: Frequency??
    public var interval: Int?
    public var end: End?
    public var daysOfTheWeek: [RecurrenceDay]?
    public var monthsOfTheYear: [Int]?
    public var daysOfTheMonth: [Int]?
    public var weeksOfTheYear: [Int]?
    public var daysOfTheYear: [Int]?
    public var setPositions: [Int]?

    public init() {}

    /// No recurrence flag was given at all.
    public var isEmpty: Bool { self == RecurrenceSpec() }

    /// Only the series' end changes: the rule still produces the same slots.
    public var changesOnlyEnd: Bool {
        guard end != nil else { return false }
        var rest = self
        rest.end = nil
        return rest.isEmpty
    }

    /// `--recurrence-frequency none`.
    public var removesRecurrence: Bool {
        if case .some(.none) = frequency { return true }
        return false
    }

    /// Flags other than the frequency, which only mean something alongside a
    /// rule (a new one, or the event's existing one).
    public var hasRuleDetails: Bool {
        var details = self
        details.frequency = nil
        return !details.isEmpty
    }

    /// The rule an update produces, given the event's current rule (`base`).
    ///
    /// Naming a frequency starts a fresh rule: the old one's days and months
    /// were chosen for the old frequency (Mondays mean something different
    /// in a monthly rule), so carrying them over would quietly produce a rule
    /// nobody asked for. Without a frequency, each flag given replaces just
    /// that part of the existing rule — `--recurrence-end-count 4` ends the
    /// series sooner and leaves everything else alone.
    ///
    /// The end is the exception: it doesn't depend on the frequency, so a
    /// fresh rule keeps the old end unless a new one is given (restating
    /// `--recurrence-frequency daily` on a ten-day series shouldn't make it
    /// endless; `--recurrence-end-date none` does that explicitly).
    public func applying(to base: RecurrenceSpec?) -> RecurrenceSpec {
        if frequency != nil {
            var fresh = self
            if fresh.end == nil { fresh.end = base?.end }
            return fresh
        }
        var merged = base ?? RecurrenceSpec()
        if let interval = interval { merged.interval = interval }
        if let end = end { merged.end = end }
        if let days = daysOfTheWeek { merged.daysOfTheWeek = days }
        if let months = monthsOfTheYear { merged.monthsOfTheYear = months }
        if let days = daysOfTheMonth { merged.daysOfTheMonth = days }
        if let weeks = weeksOfTheYear { merged.weeksOfTheYear = weeks }
        if let days = daysOfTheYear { merged.daysOfTheYear = days }
        if let positions = setPositions { merged.setPositions = positions }
        return merged
    }

    /// Rejects combinations EventKit documents as invalid for the rule's
    /// frequency. EventKit itself accepts most of them and silently ignores
    /// the part that doesn't apply, saving a rule that isn't the one the user
    /// described.
    ///
    /// Called on the flags the user passed, with `rule` the rule they produce
    /// (see `applying(to:)`). Only the flags actually given are checked: a
    /// rule written by another calendar client that EventKit was happy with
    /// shouldn't block an unrelated edit such as a new end count.
    public func validate(against rule: RecurrenceSpec) throws {
        guard case .some(.some(let frequency)) = rule.frequency else { return }
        func reject(_ flag: String, _ allowed: String) throws {
            throw RecurrenceParsingError(
                description: "\(flag) doesn't apply to a \(frequency.rawValue) recurrence; "
                    + "EventKit only uses it for \(allowed) rules.")
        }
        // With a new frequency `self` *is* the rule (see `applying(to:)`), so
        // everything gets checked; otherwise just the flags that changed.
        let given = self
        if given.daysOfTheWeek != nil && frequency == .daily {
            try reject("--recurrence-days", "weekly, monthly, and yearly")
        }
        if let days = given.daysOfTheWeek, days.contains(where: { $0.week != 0 }) {
            if frequency != .monthly && frequency != .yearly {
                try reject("A week number in --recurrence-days (e.g. 1mon)", "monthly and yearly")
            }
            // No month has a sixth Monday; a rule asking for one never fires.
            if frequency == .monthly, days.contains(where: { abs($0.week) > 5 }) {
                throw RecurrenceParsingError(
                    description: "A monthly --recurrence-days week number must be from 1 to 5, or -1 to -5 "
                        + "from the end of the month.")
            }
            // RFC 5545 forbids week-numbered days alongside BYWEEKNO.
            if rule.weeksOfTheYear != nil {
                throw RecurrenceParsingError(
                    description: "A week number in --recurrence-days (e.g. 1mon) can't be combined with "
                        + "--recurrence-weeks-of-year; use plain day names (mon) with it.")
            }
        }
        if given.daysOfTheMonth != nil && frequency != .monthly {
            try reject("--recurrence-days-of-month", "monthly")
        }
        if given.monthsOfTheYear != nil && frequency != .yearly {
            try reject("--recurrence-months", "yearly")
        }
        if given.weeksOfTheYear != nil && frequency != .yearly {
            try reject("--recurrence-weeks-of-year", "yearly")
        }
        if given.daysOfTheYear != nil && frequency != .yearly {
            try reject("--recurrence-days-of-year", "yearly")
        }
        if given.setPositions != nil && rule.daysOfTheWeek == nil && rule.daysOfTheMonth == nil
            && rule.monthsOfTheYear == nil && rule.weeksOfTheYear == nil && rule.daysOfTheYear == nil {
            throw RecurrenceParsingError(
                description: "--recurrence-set-positions picks among the days another --recurrence-* flag "
                    + "selects (e.g. --recurrence-days mon,tue,wed,thu,fri --recurrence-set-positions -1 "
                    + "for the last weekday), so it needs one of them.")
        }
    }
}

public struct RecurrenceParsingError: Error, CustomStringConvertible {
    public let description: String
}

/// Parses the `--recurrence-*` flags into a `RecurrenceSpec`.
///
/// Every value is validated against the range EventKit documents for it.
/// That matters beyond tidy errors: `EKRecurrenceRule` raises an Objective-C
/// exception for some out-of-range values (a day of the month of 0, say),
/// which Swift can't catch, so letting one through would crash the CLI
/// rather than report a typo.
public enum RecurrenceParsing {
    public static let frequencyValues = "daily, weekly, monthly, yearly"

    /// - Parameter allowNone: `update event` accepts `--recurrence-frequency
    ///   none` to remove the recurrence; `add event` has nothing to remove.
    /// - Parameter endDate: already parsed by the caller's shared date-flag
    ///   handling, which owns that flag's error message; `clearEndDate` is
    ///   the `none` spelling, which only `update event` passes through.
    public static func parse(
        frequency: String?,
        interval: String?,
        endCount: String?,
        endDate: Date?,
        clearEndDate: Bool = false,
        days: String?,
        months: String?,
        daysOfMonth: String?,
        weeksOfYear: String?,
        daysOfYear: String?,
        setPositions: String?,
        allowNone: Bool
    ) throws -> RecurrenceSpec {
        var spec = RecurrenceSpec()

        if let frequency = frequency {
            let value = frequency.trimmingCharacters(in: .whitespaces).lowercased()
            if value == "none" {
                guard allowNone else {
                    throw RecurrenceParsingError(
                        description: "--recurrence-frequency none only applies to update event; "
                            + "to create a one-off event, leave the flag out.")
                }
                spec.frequency = .some(nil)
            } else if let parsed = RecurrenceSpec.Frequency(rawValue: value) {
                spec.frequency = .some(parsed)
            } else {
                let accepted = allowNone ? frequencyValues + ", or none" : frequencyValues
                throw RecurrenceParsingError(
                    description: "Invalid --recurrence-frequency \"\(frequency)\". Use \(accepted).")
            }
        }

        if let interval = interval {
            spec.interval = try integer(interval, flag: "--recurrence-interval", in: 1...999)
        }

        if endCount != nil && (endDate != nil || clearEndDate) {
            throw RecurrenceParsingError(
                description: "Pass either --recurrence-end-count or --recurrence-end-date, not both.")
        }
        if let endCount = endCount {
            spec.end = .count(try integer(endCount, flag: "--recurrence-end-count", in: 1...9999))
        } else if let endDate = endDate {
            spec.end = .date(endDate)
        } else if clearEndDate {
            spec.end = .never
        }

        if let days = days { spec.daysOfTheWeek = try parseDays(days) }
        if let months = months { spec.monthsOfTheYear = try parseMonths(months) }
        if let daysOfMonth = daysOfMonth {
            spec.daysOfTheMonth = try integers(daysOfMonth, flag: "--recurrence-days-of-month", limit: 31)
        }
        if let weeksOfYear = weeksOfYear {
            spec.weeksOfTheYear = try integers(weeksOfYear, flag: "--recurrence-weeks-of-year", limit: 53)
        }
        if let daysOfYear = daysOfYear {
            spec.daysOfTheYear = try integers(daysOfYear, flag: "--recurrence-days-of-year", limit: 366)
        }
        if let setPositions = setPositions {
            spec.setPositions = try integers(setPositions, flag: "--recurrence-set-positions", limit: 366)
        }

        if spec.removesRecurrence && spec.hasRuleDetails {
            throw RecurrenceParsingError(
                description: "--recurrence-frequency none removes the recurrence, "
                    + "so it can't be combined with other --recurrence-* flags.")
        }
        return spec
    }

    /// `mon,wed`, `1mon` (first Monday), `-1fri` (last Friday).
    public static func parseDays(_ string: String) throws -> [RecurrenceDay] {
        let parts = try components(string, flag: "--recurrence-days")
        return try parts.map { part in
            let lowered = part.lowercased()
            let digitsEnd = lowered.firstIndex { !($0.isASCII && ($0.isNumber || $0 == "-" || $0 == "+")) }
                ?? lowered.endIndex
            let prefix = String(lowered[..<digitsEnd])
            let name = String(lowered[digitsEnd...])

            guard let weekday = weekdayNumber(name) else {
                throw RecurrenceParsingError(
                    description: "Invalid --recurrence-days value \"\(part)\". "
                        + "Use day names (mon,wed), optionally with a week: 1mon for the first Monday, "
                        + "-1fri for the last Friday.")
            }
            guard !prefix.isEmpty else { return RecurrenceDay(weekday: weekday) }
            guard let week = Int(prefix), week != 0, (-53...53).contains(week) else {
                throw RecurrenceParsingError(
                    description: "Invalid week in --recurrence-days value \"\(part)\". "
                        + "Use 1 to 53 counting from the start, or -1 to -53 from the end.")
            }
            return RecurrenceDay(weekday: weekday, week: week)
        }
    }

    /// Month numbers or names: `1,7`, `jan,jul`, `january`.
    public static func parseMonths(_ string: String) throws -> [Int] {
        let names = [
            "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
        ]
        let fullNames = [
            "january", "february", "march", "april", "may", "june", "july", "august",
            "september", "october", "november", "december",
        ]
        return try components(string, flag: "--recurrence-months").map { part in
            let lowered = part.lowercased()
            if let index = names.firstIndex(of: lowered) ?? fullNames.firstIndex(of: lowered) {
                return index + 1
            }
            guard let month = Int(lowered), (1...12).contains(month) else {
                throw RecurrenceParsingError(
                    description: "Invalid --recurrence-months value \"\(part)\". "
                        + "Use 1-12 or month names (jan,jul).")
            }
            return month
        }
    }

    static func weekdayNumber(_ name: String) -> Int? {
        let full = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if let index = RecurrenceDay.names.firstIndex(of: name) ?? full.firstIndex(of: name) {
            return index + 1
        }
        return nil
    }

    /// Comma-separated non-empty components. An empty one is almost always a
    /// typo (`mon,,wed`) or an unset variable, so it's rejected, not skipped.
    static func components(_ string: String, flag: String) throws -> [String] {
        let parts = string.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.contains(where: \.isEmpty) else {
            throw RecurrenceParsingError(description: "\(flag) has an empty value in \"\(string)\".")
        }
        return parts
    }

    static func integer(_ string: String, flag: String, in range: ClosedRange<Int>) throws -> Int {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), range.contains(value) else {
            throw RecurrenceParsingError(
                description: "Invalid \(flag) \"\(string)\". "
                    + "Use a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return value
    }

    /// Signed lists such as days of the month: 1...limit counts from the
    /// start, -1...-limit from the end, and 0 is meaningless.
    static func integers(_ string: String, flag: String, limit: Int) throws -> [Int] {
        try components(string, flag: flag).map { part in
            guard let value = Int(part), value != 0, (-limit...limit).contains(value) else {
                throw RecurrenceParsingError(
                    description: "Invalid \(flag) value \"\(part)\". "
                        + "Use 1 to \(limit), or -1 to -\(limit) to count from the end.")
            }
            return value
        }
    }
}
