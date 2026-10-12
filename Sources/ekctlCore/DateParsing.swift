import Foundation

/// Parses the ISO 8601 strings accepted by every date-taking CLI flag
/// (`--from`, `--to`, `--start`, `--end`, `--due`, `--recurrence-end-date`).
///
/// Flags originally accepted only the strict RFC 3339 profile —
/// `Z` or colon-separated offsets like `+11:00`. But `eventToDict` *emits* local-offset timestamps,
/// and jq pipelines work in the compact `+1100` offset form, so ekctl's own
/// output (and jq-massaged derivatives of it) couldn't be fed back into
/// `--from`/`--to` (issue #3). The parser therefore accepts every combination
/// of {colon, compact} offsets × {with, without} fractional seconds, plus `Z`
/// — anything ekctl can emit is valid input.
///
/// A date-time with no offset at all (`2026-02-23T14:00`) is local wall-clock
/// time; see `localDateTime`.
public enum DateParsing {
    /// One-line summary of accepted formats for help and error text, so the
    /// flags all describe themselves identically.
    public static let acceptedFormats =
        "ISO 8601 with an offset (e.g., 2026-02-01T09:30:00Z, 2026-02-01T09:30:00+11:00, or 2026-02-01T09:30:00+1100) "
        + "or without one for local time (2026-02-01T09:30, 2026-02-01T09:30:00, or 2026-02-01 09:30:00), "
        + RelativeDates.acceptedFormats

    public static func parse(_ string: String) -> Date? {
        parse(string, now: Date(), calendar: .current)
    }

    /// Testable form: `now` and `calendar` anchor the shorthand grammar (see
    /// `RelativeDates`) so it can be pinned to a fixed instant and zone, and
    /// `calendar`'s time zone is the one offset-less ISO input is read in.
    ///
    /// ISO 8601 with an offset is tried first and wins outright — every string
    /// that parsed before still parses to exactly the same instant. Offset-less
    /// ISO comes next, then the shorthand.
    public static func parse(_ string: String, now: Date, calendar: Calendar = .current) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let date = offsetDateTime(trimmed) {
            return date
        }
        if let date = localDateTime(trimmed, timeZone: calendar.timeZone) {
            return date
        }
        return RelativeDates.parse(trimmed, now: now, calendar: calendar)
    }

    /// `2026-02-23T14:00`, `2026-02-23T14:00:00`, or `2026-02-23T14:00:00.250`:
    /// ISO 8601 with no offset, which ISO defines as local time. It's read on the
    /// wall clock of `timeZone` (the caller's calendar's zone, so the Mac's own
    /// by default).
    ///
    /// The `T` may be lower case or a single space, as RFC 3339 §5.6 allows, so
    /// `2026-02-23 14:00:00` (what `date '+%F %T'` and most databases print)
    /// works too. The space form without seconds already parsed through the
    /// shorthand; it now parses here first, to the same instant.
    ///
    /// Strict: every field is a fixed number of ASCII digits and must be in
    /// range — hour 24, minute 60, second 60 (leap seconds aren't representable
    /// on a Mac anyway), and Feb 31 are rejected, not rolled into the next hour,
    /// day or month. The date is checked by `RelativeDates.isoDate`, which also
    /// resolves it in Gregorian rather than the user's regional calendar.
    ///
    /// A time that the clocks skip or repeat at a DST change resolves exactly as
    /// the shorthand's clock times do; see `WallClock`. In short, a skipped
    /// time moves forward by the length of the gap and a repeated one takes its
    /// first occurrence.
    static func localDateTime(_ string: String, timeZone: TimeZone) -> Date? {
        guard let reading = dateTime(string) else { return nil }
        return WallClock.instant(year: reading.year, month: reading.month, day: reading.day,
                                 hour: reading.hour, minute: reading.minute, second: reading.second,
                                 in: timeZone)?
            .addingTimeInterval(reading.fraction)
    }

    /// ISO 8601 with a UTC offset: the same date-time `localDateTime` reads,
    /// followed by `Z` or `±HH`, `±HHMM` or `±HH:MM`.
    ///
    /// This used to be left to `ISO8601DateFormatter`, which is far more
    /// lenient than its documentation suggests: it rolled `2026-02-30` into
    /// March, read `+5:30` as `+05:00`, ignored trailing junk, and took
    /// five-digit and two-digit years. Every one of those quietly produced a
    /// different instant from the one written. Parsing the fields here, with
    /// the same strict checks as offset-less input, accepts everything ekctl
    /// emits (both `--time-format`s, with or without fractional seconds) and
    /// rejects the rest.
    static func offsetDateTime(_ string: String) -> Date? {
        let characters = Array(string)
        guard characters.count > 16 else { return nil }

        let body: String
        let offsetSeconds: Int
        if characters.last == "Z" || characters.last == "z" {
            body = String(characters.dropLast())
            offsetSeconds = 0
        } else {
            // The date's own hyphens sit before index 10; a sign after the
            // time starts the offset.
            guard let signIndex = characters.lastIndex(where: { $0 == "+" || $0 == "-" }),
                  signIndex > 10
            else { return nil }
            let text = String(characters[(signIndex + 1)...])
            let digits = text.replacingOccurrences(of: ":", with: "")
            let colonPlaced = text.count == 2 || text.count == 4
                || (text.count == 5 && text[text.index(text.startIndex, offsetBy: 2)] == ":")
            guard colonPlaced, digits.count == 2 || digits.count == 4,
                  RelativeDates.isAllDigits(digits),
                  let hours = Int(digits.prefix(2)), let minutes = Int(digits.dropFirst(2).isEmpty ? "0" : String(digits.dropFirst(2))),
                  hours <= 18, minutes < 60
            else { return nil }
            let magnitude = hours * 3600 + minutes * 60
            offsetSeconds = characters[signIndex] == "-" ? -magnitude : magnitude
            body = String(characters[..<signIndex])
        }

        guard let reading = dateTime(body) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            year: reading.year, month: reading.month, day: reading.day,
            hour: reading.hour, minute: reading.minute, second: reading.second)
        return utc.date(from: components)?
            .addingTimeInterval(reading.fraction - TimeInterval(offsetSeconds))
    }

    /// The fields of `yyyy-MM-dd` + `T`/`t`/space + a time of day, all
    /// validated; see `localDateTime` for the rules.
    private static func dateTime(_ string: String)
        -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, fraction: TimeInterval)?
    {
        let characters = Array(string)
        // "yyyy-MM-dd" + separator + at least "HH:mm".
        guard characters.count >= 16, ["T", "t", " "].contains(characters[10])
        else { return nil }

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let day = RelativeDates.isoDate(String(characters[..<10]), calendar: gregorian)
        else { return nil }
        let date = gregorian.dateComponents([.year, .month, .day], from: day)
        guard let year = date.year, let month = date.month, let dayOfMonth = date.day,
              let time = timeOfDay(String(characters[11...]))
        else { return nil }
        return (year, month, dayOfMonth, time.hour, time.minute, time.second, time.fraction)
    }

    /// `HH:mm`, `HH:mm:ss`, or `HH:mm:ss.f…` with two-digit fields and at least
    /// one fractional digit after a `.`.
    private static func timeOfDay(_ text: String)
        -> (hour: Int, minute: Int, second: Int, fraction: TimeInterval)?
    {
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count) else { return nil }

        var secondsField = fields.count == 3 ? fields[2] : "00"
        var fraction: TimeInterval = 0
        if let dot = secondsField.firstIndex(of: ".") {
            let digits = secondsField[secondsField.index(after: dot)...]
            guard RelativeDates.isAllDigits(digits), let value = Double("0." + digits)
            else { return nil }
            fraction = value
            secondsField = secondsField[..<dot]
        }

        let twoDigits = [fields[0], fields[1], secondsField]
        guard twoDigits.allSatisfy({ $0.count == 2 && RelativeDates.isAllDigits($0) }),
              let hour = Int(twoDigits[0]), let minute = Int(twoDigits[1]),
              let second = Int(twoDigits[2]),
              (0..<24).contains(hour), (0..<60).contains(minute), (0..<60).contains(second)
        else { return nil }
        return (hour, minute, second, fraction)
    }
}
