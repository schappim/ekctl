import Foundation

/// Parses the ISO 8601 strings accepted by every date-taking CLI flag
/// (`--from`, `--to`, `--start`, `--end`, `--due`, `--recurrence-end-date`).
///
/// Flags originally accepted only the strict RFC 3339 profile that
/// `ISO8601DateFormatter`'s default options parse — `Z` or colon-separated
/// offsets like `+11:00`. But `eventToDict` *emits* local-offset timestamps,
/// and jq pipelines work in the compact `+1100` offset form, so ekctl's own
/// output (and jq-massaged derivatives of it) couldn't be fed back into
/// `--from`/`--to` (issue #3). The parser therefore accepts every combination
/// of {colon, compact} offsets × {with, without} fractional seconds, plus `Z`
/// — anything ekctl can emit is valid input.
public enum DateParsing {
    /// One-line summary of accepted formats for help and error text, so the
    /// flags all describe themselves identically.
    public static let acceptedFormats =
        "ISO 8601 (e.g., 2026-02-01T09:30:00Z, 2026-02-01T09:30:00+11:00, or 2026-02-01T09:30:00+1100), "
        + RelativeDates.acceptedFormats

    private static let formatters: [ISO8601DateFormatter] = {
        let base: ISO8601DateFormatter.Options = [
            .withFullDate, .withFullTime, .withDashSeparatorInDate, .withColonSeparatorInTime,
        ]
        // `.withColonSeparatorInTimeZone` toggles `+11:00` vs `+1100`;
        // `.withFractionalSeconds` is strict in both directions, so each
        // combination needs its own formatter. `Z` parses under all of them.
        let optionSets: [ISO8601DateFormatter.Options] = [
            base.union([.withColonSeparatorInTimeZone]),
            base,
            base.union([.withColonSeparatorInTimeZone, .withFractionalSeconds]),
            base.union([.withFractionalSeconds]),
        ]
        return optionSets.map { options in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            return formatter
        }
    }()

    public static func parse(_ string: String) -> Date? {
        parse(string, now: Date(), calendar: .current)
    }

    /// Testable form: `now` and `calendar` anchor the shorthand grammar (see
    /// `RelativeDates`) so it can be pinned to a fixed instant and zone.
    ///
    /// ISO 8601 is tried first and wins outright — every string that parsed
    /// before this shorthand existed still parses to exactly the same instant.
    public static func parse(_ string: String, now: Date, calendar: Calendar = .current) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        for formatter in formatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return RelativeDates.parse(trimmed, now: now, calendar: calendar)
    }
}
