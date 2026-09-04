import Foundation

/// Shorthand date grammar layered under the ISO 8601 parser, so every
/// date-taking flag (`--from`, `--to`, `--start`, `--end`, `--due`,
/// `--recurrence-end-date`) accepts the forms a person actually types.
///
/// ISO 8601 is still tried first and wins outright, so nothing that parsed
/// before parses differently now — this only widens what's accepted.
///
/// The grammar, all case-insensitive:
///
///   now                      the current instant
///   +90m  -2h  +3d  +1w      an offset from now (m/min, h/hr, d/day, w/week)
///   today  tomorrow  yesterday
///   fri  friday             the next Friday, today included
///   next fri                the next Friday, today excluded
///   last fri                the most recent Friday, today excluded
///   next week  last week    seven days either side of today
///   2026-02-01              a plain date
///   14:30  3pm  9:15am      a time today
///   noon  midnight
///   tomorrow 3pm            any day above, with any time above
///   next fri at 09:00       "at" is optional filler
///
/// A bare day resolves to the *start* of that day, which is what a range
/// endpoint like `--from tomorrow` should mean. A bare number is deliberately
/// rejected: "9" could be a time or a day of the month, and guessing wrong
/// would book a meeting three weeks out.
///
/// `now` and `calendar` are parameters rather than globals so the whole grammar
/// can be tested against pinned instants and zones.
public enum RelativeDates {

    /// One-line summary of the shorthand, folded into `DateParsing.acceptedFormats`.
    public static let acceptedFormats =
        "a date (2026-02-01), a shorthand (now, today, tomorrow, fri, 'tomorrow 3pm', 14:30), or an offset (+90m, +2h, +3d, +1w)"

    public static func parse(_ string: String,
                             now: Date = Date(),
                             calendar: Calendar = .current) -> Date? {
        let tokens = string
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter { $0 != "at" }  // "tomorrow at 3pm"
        guard !tokens.isEmpty else { return nil }

        if tokens == ["now"] { return now }
        if tokens.count == 1, let offset = offset(tokens[0], from: now, calendar: calendar) {
            return offset
        }

        // A day on its own resolves to the start of that day.
        if let day = day(tokens, now: now, calendar: calendar) {
            return calendar.startOfDay(for: day)
        }
        // A time on its own is that time today.
        if let token = timeToken(tokens[...]), let minutes = timeOfDay(token) {
            return instant(minutesPastMidnight: minutes, on: now, calendar: calendar)
        }
        // Otherwise: a day phrase followed by a time.
        // Longest day phrase first, so "next friday 3pm" beats "next" alone.
        for split in stride(from: tokens.count - 1, through: 1, by: -1) {
            guard let day = day(Array(tokens[0..<split]), now: now, calendar: calendar),
                  let token = timeToken(tokens[split...]),
                  let minutes = timeOfDay(token)
            else { continue }
            return instant(minutesPastMidnight: minutes, on: day, calendar: calendar)
        }
        return nil
    }

    // MARK: - Offsets

    /// `+90m`, `-2h`, `+3d`, `+1w`. Months and years are left out on purpose:
    /// `m` would be ambiguous between minutes and months, and a wrong guess
    /// there is a big miss.
    static func offset(_ token: String, from now: Date, calendar: Calendar) -> Date? {
        guard let sign = token.first, sign == "+" || sign == "-" else { return nil }

        let body = token.dropFirst()
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty, let magnitude = Int(digits) else { return nil }

        let unit = String(body.dropFirst(digits.count))
        guard let component = componentFor(unit), magnitude <= maximumMagnitude(for: component)
        else { return nil }

        let value = sign == "-" ? -magnitude : magnitude
        guard let result = calendar.date(byAdding: component, value: value, to: now)
        else { return nil }
        // Foundation hands back an unmoved — or wildly overshot — date when it
        // can't represent the result, so a garbled offset would silently read
        // as "now" or flip its sign. Neither is an acceptable answer for a
        // flag that schedules things.
        guard value == 0 || (value > 0 ? result > now : result < now) else { return nil }
        return result
    }

    /// Roughly a century in each unit. Beyond that an offset is a typo, and
    /// resolving it to a date in year 5828963 helps nobody.
    private static func maximumMagnitude(for component: Calendar.Component) -> Int {
        switch component {
        case .minute: return 100 * 366 * 24 * 60
        case .hour: return 100 * 366 * 24
        case .day: return 100 * 366
        case .weekOfYear: return 100 * 53
        default: return 0
        }
    }

    private static func componentFor(_ unit: String) -> Calendar.Component? {
        switch unit {
        case "m", "min", "mins", "minute", "minutes": return .minute
        case "h", "hr", "hrs", "hour", "hours": return .hour
        case "d", "day", "days": return .day
        case "w", "wk", "wks", "week", "weeks": return .weekOfYear
        default: return nil
        }
    }

    // MARK: - Days

    /// Resolves a day phrase to *some* instant on that day; callers take the
    /// start of day or graft a time onto it.
    static func day(_ tokens: [String], now: Date, calendar: Calendar) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)

        switch tokens.count {
        case 1:
            switch tokens[0] {
            case "today": return startOfToday
            case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: startOfToday)
            case "yesterday": return calendar.date(byAdding: .day, value: -1, to: startOfToday)
            default: break
            }
            if let weekday = Weekdays.names[tokens[0]] {
                return occurrence(of: weekday, from: startOfToday, calendar: calendar,
                                  direction: .forward, includingToday: true)
            }
            return isoDate(tokens[0], calendar: calendar)

        case 2:
            let (qualifier, subject) = (tokens[0], tokens[1])
            guard qualifier == "next" || qualifier == "last" else { return nil }
            let direction: Direction = qualifier == "next" ? .forward : .backward

            if subject == "week" {
                return calendar.date(byAdding: .day,
                                     value: direction == .forward ? 7 : -7,
                                     to: startOfToday)
            }
            guard let weekday = Weekdays.names[subject] else { return nil }
            // "next friday" said on a Friday means the following one, and
            // "last friday" likewise never means today.
            return occurrence(of: weekday, from: startOfToday, calendar: calendar,
                              direction: direction, includingToday: false)

        default:
            return nil
        }
    }

    enum Direction { case forward, backward }

    private static func occurrence(of weekday: Int,
                                   from startOfToday: Date,
                                   calendar: Calendar,
                                   direction: Direction,
                                   includingToday: Bool) -> Date? {
        let today = calendar.component(.weekday, from: startOfToday)
        var delta = direction == .forward
            ? (weekday - today + 7) % 7
            : (today - weekday + 7) % 7
        if delta == 0 && !includingToday { delta = 7 }
        return calendar.date(byAdding: .day,
                             value: direction == .forward ? delta : -delta,
                             to: startOfToday)
    }

    /// `2026-02-01` — a plain date, which the ISO 8601 formatters reject
    /// because they require a time component.
    ///
    /// Resolved against a Gregorian calendar carrying the caller's time zone,
    /// never against the caller's own calendar. `2026` in a `yyyy-MM-dd` string
    /// is a Gregorian year; handing it to a Mac whose region calendar is
    /// Buddhist or Japanese reinterprets it as a year in *that* era and lands
    /// centuries away — silently, because a wrong year still round-trips the
    /// day and month checks below. Every other shorthand form is immune, since
    /// it only ever moves within one calendar.
    static func isoDate(_ token: String, calendar: Calendar) -> Date? {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy(isAllDigits),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = gregorian.date(from: components) else { return nil }
        // Reject 2026-02-31 and 0000-01-01 rather than letting Foundation roll
        // them into a neighbouring month or era.
        guard gregorian.component(.day, from: date) == day,
              gregorian.component(.month, from: date) == month,
              gregorian.component(.year, from: date) == year
        else { return nil }
        return date
    }

    /// ASCII digits only. `Int("+026")` is 26 and `Int("٣")` is 3, so a plain
    /// `Int(_:)` would let `+026-02-01` through as year 26.
    static func isAllDigits<S: StringProtocol>(_ text: S) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: - Times

    /// The tokens that may make up a time. A lone `am`/`pm` is allowed to stand
    /// apart ("3 pm"), but nothing else is glued together: joining freely turned
    /// the fat-fingered "1 4:30" into 14:30 without a word.
    static func timeToken(_ tokens: ArraySlice<String>) -> String? {
        switch tokens.count {
        case 1:
            return tokens.first
        case 2:
            guard let last = tokens.last, last == "am" || last == "pm" else { return nil }
            return tokens.joined()
        default:
            return nil
        }
    }

    /// `14:30`, `3pm`, `9:15am`, `noon`, `midnight` → minutes past midnight.
    /// A bare number is rejected as ambiguous.
    static func timeOfDay(_ token: String) -> Int? {
        if token == "noon" || token == "midday" { return 12 * 60 }
        if token == "midnight" { return 0 }

        var body = token
        var meridiem: String?
        // At most one — looping stripped "am" and then "pm" from "3pmam",
        // accepting it as 3pm.
        if let suffix = ["am", "pm"].first(where: { body.hasSuffix($0) }) {
            meridiem = suffix
            body = String(body.dropLast(2))
        }

        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        // Without am/pm, a bare number is ambiguous with a day of the month.
        guard parts.count == 2 || meridiem != nil else { return nil }
        guard isAllDigits(parts[0]), let hour = Int(parts[0]) else { return nil }

        var minute = 0
        if parts.count == 2 {
            guard parts[1].count == 2, isAllDigits(parts[1]), let parsed = Int(parts[1])
            else { return nil }
            minute = parsed
        }
        guard (0..<60).contains(minute) else { return nil }

        switch meridiem {
        case "am":
            guard (1...12).contains(hour) else { return nil }
            return (hour == 12 ? 0 : hour) * 60 + minute
        case "pm":
            guard (1...12).contains(hour) else { return nil }
            return (hour == 12 ? 12 : hour + 12) * 60 + minute
        default:
            guard (0...23).contains(hour) else { return nil }
            return hour * 60 + minute
        }
    }

    /// Grafts a wall-clock time onto a day. Built from date components rather
    /// than by adding seconds, so "09:00" stays 09:00 on a DST-transition day.
    private static func instant(minutesPastMidnight minutes: Int,
                                on day: Date,
                                calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = minutes / 60
        components.minute = minutes % 60
        components.second = 0
        return calendar.date(from: components)
    }
}
