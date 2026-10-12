import Foundation

/// Parses an alarm-list flag (`--alarms`): comma-separated offsets relative to
/// the event start, returned as EventKit-ready second offsets for
/// `EKAlarm(relativeOffset:)`.
///
/// Each entry is a number with an optional unit, case-insensitive, from the
/// same vocabulary as date offsets like `+2h` (`m`/`min`, `h`/`hr`, `d`/`day`,
/// `w`/`week`, and their plurals). A bare number is minutes, as it always was,
/// so `10,60` still means what it did.
///
/// Sign convention (matches the CLI help text):
///   - a bare value means *before* the start → negative seconds
///   - a leading `+` means *after* the start → positive seconds
///   - a leading `-` also means before, so `-10` and `10` are the same alarm
///
/// `none` or an empty string means no alarms, and returns `[]`, which callers
/// use to clear an event's alarms.
///
/// Anything else is an error that names the entry, never a silent drop. This
/// parser used to skip entries it couldn't read, so before units existed
/// `update event --alarms 1h` parsed to `[]` and *removed* every alarm on the
/// event while reporting success.
public enum AlarmParsing {

    /// For help text. Kept beside the parser so the two can't drift.
    public static let acceptedFormats =
        "comma-separated offsets from the start, each a number with an optional unit "
        + "m (minutes, the default), h, d, or w, e.g. 10, 15m, 1.5h, 2d, 1w. "
        + "A plain or negative offset is before the start; prefix + for after (+30m). "
        + "'none' or an empty string means no alarms"

    /// One year either side of the start. EventKit would take more, but an
    /// offset that large is almost always the wrong unit (`10080h` typed where
    /// `10080m`, a week, was meant) rather than a reminder set a year ahead.
    /// 365 days still admits `52w` and `365d` for an annual heads-up.
    public static let maximumOffsetMinutes = 365 * 24 * 60

    /// - Returns: nil for nil input (the flag wasn't passed), `[]` for `none` or
    ///   an empty string, otherwise one offset in seconds per entry, in order.
    /// - Throws: `AlarmParsingError` naming the first entry that isn't valid.
    public static func parse(_ string: String?) throws -> [Double]? {
        guard let string = string else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "none" { return [] }

        return try trimmed.split(separator: ",", omittingEmptySubsequences: false).map { component in
            let entry = component.trimmingCharacters(in: .whitespaces)
            // A stray comma is more likely a script that built the list from an
            // empty variable than an intent to add nothing, so it isn't skipped.
            if entry.isEmpty { throw AlarmParsingError.emptyEntry(input: string) }
            if entry.lowercased() == "none" { throw AlarmParsingError.noneInList(input: string) }
            return try offsetSeconds(entry)
        }
    }

    /// Removes repeated offsets, keeping each one where it first appears. Values
    /// are compared exactly; `parse` only ever produces whole minutes, so `60m`
    /// and `1h` are already equal.
    public static func dedupe(_ offsets: [Double]) -> [Double] {
        var seen = Set<Double>()
        return offsets.filter { seen.insert($0).inserted }
    }

    // MARK: - One entry

    private static func offsetSeconds(_ entry: String) throws -> Double {
        var body = Substring(entry)
        var isAfterStart = false
        if let sign = body.first, sign == "+" || sign == "-" {
            isAfterStart = sign == "+"
            body = body.dropFirst()
        }

        // ASCII only: `Double("1e3")`, `Double("inf")` and `Int("٣")` all
        // succeed, and none of them is an alarm anyone typed on purpose.
        let number = body.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let unit = body.dropFirst(number.count).lowercased()
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy(RelativeDates.isAllDigits),
              unit.allSatisfy(\.isLetter)
        else { throw AlarmParsingError.unrecognised(entry: entry) }

        let unitSeconds = try secondsPerUnit(unit, entry: entry)
        let capSeconds = maximumOffsetMinutes * 60

        // Exact decimal arithmetic in integers: 1.1h is 66 minutes, not the
        // 66.00000000000001 a Double makes of it.
        let integerDigits = parts[0].drop { $0 == "0" }
        guard integerDigits.count <= 12,
              let whole = Int(integerDigits.isEmpty ? "0" : String(integerDigits)),
              whole <= capSeconds / unitSeconds
        else { throw AlarmParsingError.outOfRange(entry: entry) }

        var fractionDigits = parts.count == 2 ? String(parts[1]) : ""
        while fractionDigits.hasSuffix("0") { fractionDigits.removeLast() }
        // Every unit's length in seconds divides a week, 604 800 = 2^7·3^3·5^2·7.
        // A fraction with k significant decimal places (last digit non-zero)
        // times that is whole only if the unit supplies the 2s and 5s for 10^k,
        // so beyond k = 7 it can't come out to a whole number of seconds, let
        // alone minutes. Bailing here also keeps the arithmetic below far from
        // overflow.
        guard fractionDigits.count <= 7 else { throw AlarmParsingError.notWholeMinutes(entry: entry) }

        var scale = 1
        for _ in 0..<fractionDigits.count { scale *= 10 }
        let scaled = (whole * scale + (Int(fractionDigits) ?? 0)) * unitSeconds
        guard scaled % scale == 0, (scaled / scale) % 60 == 0
        else { throw AlarmParsingError.notWholeMinutes(entry: entry) }

        let seconds = scaled / scale
        guard seconds <= capSeconds else { throw AlarmParsingError.outOfRange(entry: entry) }
        // Integer negation, so "-0" and "0" are both 0, never -0.0.
        return Double(isAfterStart ? seconds : -seconds)
    }

    private static func secondsPerUnit(_ unit: String, entry: String) throws -> Int {
        if unit.isEmpty { return 60 }
        if ["s", "sec", "secs", "second", "seconds"].contains(unit) {
            throw AlarmParsingError.secondsUnsupported(entry: entry)
        }
        switch RelativeDates.componentFor(unit) {
        case .minute: return 60
        case .hour: return 60 * 60
        case .day: return 24 * 60 * 60
        case .weekOfYear: return 7 * 24 * 60 * 60
        default: throw AlarmParsingError.unknownUnit(entry: entry, unit: unit)
        }
    }
}

/// Why an alarm-list flag was rejected. `description` is the user-facing
/// message; it names the entry but not the flag, so a caller can prefix
/// whichever flag it was (`--alarms`, `--add-alarms`).
public enum AlarmParsingError: Error, CustomStringConvertible, Equatable {
    /// `10,,30`, `10,` — `input` is the whole flag value, since the entry is blank.
    case emptyEntry(input: String)
    /// `none,10` — `input` is the whole flag value.
    case noneInList(input: String)
    case unrecognised(entry: String)
    case unknownUnit(entry: String, unit: String)
    case secondsUnsupported(entry: String)
    case notWholeMinutes(entry: String)
    case outOfRange(entry: String)

    public var description: String {
        switch self {
        case .emptyEntry(let input):
            return "\"\(input)\" has an empty entry. Remove the stray comma, "
                + "or pass none on its own for no alarms."
        case .noneInList(let input):
            return "\"none\" can't be combined with other alarms (got \"\(input)\"). "
                + "Pass none on its own for no alarms."
        case .unrecognised(let entry):
            return "\"\(entry)\" is not an alarm offset. Use \(AlarmParsing.acceptedFormats)."
        case .unknownUnit(let entry, let unit):
            return "\"\(entry)\" has an unknown unit \"\(unit)\". "
                + "Use m, h, d, or w (minutes, hours, days, weeks)."
        case .secondsUnsupported(let entry):
            return "\"\(entry)\" is in seconds, which alarms don't support: event output "
                + "reports alarms in whole minutes (minutesBeforeStart), so a seconds alarm "
                + "wouldn't read back as what was set. Use minutes, e.g. 1m."
        case .notWholeMinutes(let entry):
            return "\"\(entry)\" is not a whole number of minutes. Event output reports "
                + "alarms in whole minutes (minutesBeforeStart), so a fraction of a minute "
                + "wouldn't read back as what was set."
        case .outOfRange(let entry):
            return "\"\(entry)\" is more than a year from the start. Alarms are limited to "
                + "365 days (52w) either side, because an offset that large is almost always "
                + "the wrong unit, such as 10080h where 10080m (a week) was meant."
        }
    }
}
