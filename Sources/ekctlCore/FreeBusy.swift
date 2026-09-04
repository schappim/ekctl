import Foundation

/// Pure free/busy arithmetic backing `ekctl free`.
///
/// Everything here is side-effect-free and parameterised on `calendar`, so the
/// slot-finding logic can be unit-tested against pinned instants and time zones
/// without touching an `EKEventStore`. `EventKitManager` supplies the busy
/// intervals; this file decides what's left.
///
/// The shape of the problem:
///   1. every event that isn't marked "free" contributes a busy interval
///   2. busy intervals are padded by `--buffer` and merged (they overlap freely
///      across calendars — a merged view is the only correct one)
///   3. the search window is cut into one window per local day, clipped to the
///      configured working hours and weekdays
///   4. the merged busy intervals are subtracted from each day's window
///
/// Day arithmetic goes through `Calendar` rather than 86 400-second jumps so
/// DST transitions don't smear the working-hours boundaries by an hour.

// MARK: - TimeSlot

/// A half-open `[start, end)` interval. Used for both busy intervals and the
/// free slots that come out the other side.
public struct TimeSlot: Equatable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    /// Length in whole minutes, rounded *down* — a 29-minute-59-second gap is
    /// not a 30-minute meeting.
    public var durationMinutes: Int {
        Int((end.timeIntervalSince(start) / 60).rounded(.down))
    }

    /// True when the slot carries no time at all (`end <= start`).
    public var isEmpty: Bool { end <= start }
}

// MARK: - WorkingHours

/// The daily window `ekctl free` searches within, as minutes past local
/// midnight. `endMinutes <= startMinutes` describes an overnight window
/// (`22:00-02:00`), which closes on the following day.
public struct WorkingHours: Equatable {
    public let startMinutes: Int
    public let endMinutes: Int

    public init(startMinutes: Int, endMinutes: Int) {
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    /// 09:00–17:00 — the default for `--working-hours`.
    public static let standard = WorkingHours(startMinutes: 9 * 60, endMinutes: 17 * 60)

    /// The whole day, midnight to midnight (`--working-hours all`).
    public static let allDay = WorkingHours(startMinutes: 0, endMinutes: 24 * 60)

    public var isFullDay: Bool { startMinutes == 0 && endMinutes >= 24 * 60 }

    /// An overnight window: it opens on one day and closes on the next.
    public var spansMidnight: Bool { !isFullDay && endMinutes <= startMinutes }

    /// `HH:MM-HH:MM` rendering, echoed back in `ekctl free` output so a
    /// caller can confirm which window was actually searched.
    public var formatted: String {
        func render(_ minutes: Int) -> String {
            String(format: "%02d:%02d", minutes / 60, minutes % 60)
        }
        return "\(render(startMinutes))-\(render(endMinutes))"
    }

    /// One-line summary of accepted values, shared by the flag help and the
    /// error message so the two can't drift.
    public static let acceptedFormats = "HH:MM-HH:MM (e.g., 09:00-17:00), or 'all' for the whole day"

    /// Parses `"09:00-17:00"`, `"9-17"`, `"22:00-02:00"` (overnight), or the
    /// keywords `all` / `any` / `24h`.
    public static func parse(_ string: String) -> WorkingHours? {
        let trimmed = string.trimmingCharacters(in: .whitespaces).lowercased()
        if ["all", "any", "24h", "24", "always"].contains(trimmed) { return .allDay }

        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = parseTimeOfDay(String(parts[0])),
              let end = parseTimeOfDay(String(parts[1])),
              start != end
        else { return nil }
        return WorkingHours(startMinutes: start, endMinutes: end)
    }

    /// `"9"`, `"09:00"`, `"17:30"`, `"24:00"` → minutes past midnight.
    static func parseTimeOfDay(_ string: String) -> Int? {
        let components = string
            .trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(components.count) else { return nil }
        guard let hour = Int(components[0]), (0...24).contains(hour) else { return nil }

        var minute = 0
        if components.count == 2 {
            guard let parsed = Int(components[1]), (0..<60).contains(parsed) else { return nil }
            minute = parsed
        }
        let total = hour * 60 + minute
        guard total <= 24 * 60 else { return nil }
        return total
    }
}

// MARK: - Weekdays

/// Parses the `--weekdays` flag into `Calendar`-style weekday numbers
/// (1 = Sunday … 7 = Saturday), matching `Calendar.component(.weekday:)`.
public enum Weekdays {
    static let names: [String: Int] = [
        "sun": 1, "sunday": 1,
        "mon": 2, "monday": 2,
        "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "weds": 4, "wednesday": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6,
        "sat": 7, "saturday": 7,
    ]

    public static let monToFri: Set<Int> = [2, 3, 4, 5, 6]
    public static let weekend: Set<Int> = [1, 7]
    public static let all: Set<Int> = [1, 2, 3, 4, 5, 6, 7]

    /// Comma-separated day names for a set of weekday numbers, in week order —
    /// the inverse of `parse`, echoed back in `ekctl free` output.
    public static func formatted(_ weekdays: Set<Int>) -> String {
        weekdays.sorted().map { name(for: $0) }.joined(separator: ",")
    }

    /// Lowercase weekday name for a `Calendar` weekday number, used in output.
    public static func name(for weekday: Int) -> String {
        let names = [
            1: "sunday", 2: "monday", 3: "tuesday", 4: "wednesday",
            5: "thursday", 6: "friday", 7: "saturday",
        ]
        return names[weekday] ?? "unknown"
    }

    public static let acceptedFormats =
        "comma-separated day names, ranges, or the keywords weekdays/weekends/all (e.g., mon,wed,fri or mon-fri)"

    /// Parses `"mon,wed,fri"`, `"mon-fri"`, `"fri-mon"` (wraps through the
    /// weekend), or the keywords `weekdays` / `weekends` / `all`.
    /// Returns `nil` if any component is unrecognised — a typo'd day silently
    /// widening the search would be worse than an error.
    public static func parse(_ string: String) -> Set<Int>? {
        var result: Set<Int> = []
        let tokens = string.lowercased().split(separator: ",")
        guard !tokens.isEmpty else { return nil }

        for token in tokens {
            let value = token.trimmingCharacters(in: .whitespaces)
            switch value {
            case "weekday", "weekdays": result.formUnion(monToFri)
            case "weekend", "weekends": result.formUnion(weekend)
            case "all", "any", "daily": result.formUnion(all)
            default:
                guard let days = parseDayOrRange(value) else { return nil }
                result.formUnion(days)
            }
        }
        return result.isEmpty ? nil : result
    }

    /// A single day name, or an inclusive `from-to` range that wraps around
    /// the end of the week (`fri-mon` → Fri, Sat, Sun, Mon).
    private static func parseDayOrRange(_ value: String) -> Set<Int>? {
        guard value.contains("-") else {
            return names[value].map { [$0] }
        }
        let ends = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard ends.count == 2, let from = names[ends[0]], let to = names[ends[1]] else { return nil }

        var days: Set<Int> = [from]
        var day = from
        while day != to {
            day = day % 7 + 1
            days.insert(day)
        }
        return days
    }
}

// MARK: - FreeBusy

public enum FreeBusy {

    /// Pads every interval by `minutes` on both sides — the `--buffer` flag,
    /// so back-to-back meetings don't get proposed.
    public static func expand(_ intervals: [TimeSlot], byMinutes minutes: Int) -> [TimeSlot] {
        guard minutes > 0 else { return intervals }
        let seconds = Double(minutes) * 60
        return intervals.map {
            TimeSlot(start: $0.start.addingTimeInterval(-seconds),
                     end: $0.end.addingTimeInterval(seconds))
        }
    }

    /// Sorts and coalesces overlapping or touching intervals. Events from
    /// several calendars routinely overlap, and subtracting them one at a time
    /// would carve phantom gaps out of the middle of a double-booked hour.
    /// Zero-length intervals are dropped: they block nothing.
    public static func merge(_ intervals: [TimeSlot]) -> [TimeSlot] {
        let sorted = intervals.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
        var merged: [TimeSlot] = []
        for slot in sorted {
            guard let last = merged.last, slot.start <= last.end else {
                merged.append(slot)
                continue
            }
            if slot.end > last.end {
                merged[merged.count - 1] = TimeSlot(start: last.start, end: slot.end)
            }
        }
        return merged
    }

    /// Cuts `[from, to)` into one window per local day that passes the
    /// `weekdays` filter, clipped to `workingHours` and to the search range.
    public static func windows(from: Date,
                               to: Date,
                               workingHours: WorkingHours = .standard,
                               weekdays: Set<Int> = Weekdays.monToFri,
                               calendar: Calendar = .current) -> [TimeSlot] {
        guard from < to, !weekdays.isEmpty else { return [] }

        var result: [TimeSlot] = []
        // Start a day early: an overnight window that opened yesterday can
        // still overlap `from`.
        var day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: from))
            ?? calendar.startOfDay(for: from)

        while day < to {
            // Re-anchor to local midnight every step. In zones whose DST
            // transition lands *on* midnight (America/Santiago, America/Havana)
            // that midnight doesn't exist, so plain day-addition parks the
            // cursor an hour late and keeps it there — every later full-day
            // window would run 25 hours and overlap its neighbour.
            guard let advanced = calendar.date(byAdding: .day, value: 1, to: day)
            else { break }
            let nextDay = calendar.startOfDay(for: advanced)
            guard nextDay > day else { break }

            if weekdays.contains(calendar.component(.weekday, from: day)),
               let window = dayWindow(on: day, nextDay: nextDay, hours: workingHours, calendar: calendar) {
                let clipped = TimeSlot(start: max(window.start, from), end: min(window.end, to))
                if !clipped.isEmpty { result.append(clipped) }
            }
            day = nextDay
        }
        return result
    }

    /// The working-hours window for a single local day. `nextDay` is passed in
    /// rather than recomputed so the caller's DST-safe day stepping is reused.
    private static func dayWindow(on day: Date,
                                  nextDay: Date,
                                  hours: WorkingHours,
                                  calendar: Calendar) -> TimeSlot? {
        guard let start = wallClock(minutes: hours.startMinutes, on: day, calendar: calendar)
        else { return nil }

        let end: Date?
        if hours.isFullDay {
            end = nextDay
        } else if hours.spansMidnight {
            end = wallClock(minutes: hours.endMinutes, on: nextDay, calendar: calendar)
        } else {
            end = wallClock(minutes: hours.endMinutes, on: day, calendar: calendar)
        }

        guard let end = end else { return nil }
        let window = TimeSlot(start: start, end: end)
        return window.isEmpty ? nil : window
    }

    /// The instant `minutes` past midnight *by the wall clock* on `day`'s local
    /// date. Resolved through date components rather than by adding seconds to
    /// midnight so that on a DST-transition day "09:00" still means 09:00.
    private static func wallClock(minutes: Int, on day: Date, calendar: Calendar) -> Date? {
        guard minutes < 24 * 60 else {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
                .map { calendar.startOfDay(for: $0) }
        }
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = minutes / 60
        components.minute = minutes % 60
        components.second = 0
        return calendar.date(from: components)
    }

    /// Subtracts merged busy intervals from a single window, returning the
    /// gaps. `busy` must be sorted and merged (see `merge`).
    public static func subtract(_ busy: [TimeSlot], from window: TimeSlot) -> [TimeSlot] {
        guard !window.isEmpty else { return [] }

        var free: [TimeSlot] = []
        var cursor = window.start
        for interval in busy {
            if interval.end <= cursor { continue }
            if interval.start >= window.end { break }
            if interval.start > cursor {
                free.append(TimeSlot(start: cursor, end: min(interval.start, window.end)))
            }
            cursor = max(cursor, interval.end)
            if cursor >= window.end { return free }
        }
        if cursor < window.end {
            free.append(TimeSlot(start: cursor, end: window.end))
        }
        return free
    }

    /// Moves a slot's start forward to the next multiple of `minutes` past
    /// local midnight (`--round`), so proposed times land on :00 / :15 / :30
    /// instead of whenever the previous meeting happened to end. Returns `nil`
    /// if rounding consumes the slot.
    ///
    /// The rounding is done on the *wall clock*, not on elapsed seconds since
    /// midnight: on a DST-transition day the two differ by the shift, and a
    /// zone with a half-hour shift (Australia/Lord_Howe) would otherwise land
    /// slots on :20 and :50 while the flag promises the quarter hour.
    public static func roundStartUp(_ slot: TimeSlot,
                                    toMultipleOfMinutes minutes: Int,
                                    calendar: Calendar = .current) -> TimeSlot? {
        guard minutes > 0 else { return slot }

        let components = calendar.dateComponents([.hour, .minute, .second], from: slot.start)
        let minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let onTheGrid = minuteOfDay % minutes == 0 && (components.second ?? 0) == 0
        guard !onTheGrid else { return slot }

        let rounded = (minuteOfDay / minutes + 1) * minutes
        // A repeated hour (fall-back) can resolve the rounded wall time to an
        // instant at or before the slot's own start. Leaving the slot as it
        // stands beats dropping a genuinely free stretch of the day.
        guard let start = wallClock(minutes: rounded, on: slot.start, calendar: calendar),
              start > slot.start
        else { return slot }

        guard start < slot.end else { return nil }
        return TimeSlot(start: start, end: slot.end)
    }

    /// The whole pipeline: pad and merge the busy intervals, cut the range
    /// into per-day windows, subtract, round, and keep the gaps long enough to
    /// hold `minimumDurationMinutes`. Slots come back in chronological order.
    public static func slots(busy: [TimeSlot],
                             from: Date,
                             to: Date,
                             workingHours: WorkingHours = .standard,
                             weekdays: Set<Int> = Weekdays.monToFri,
                             minimumDurationMinutes: Int = 30,
                             bufferMinutes: Int = 0,
                             roundToMinutes: Int = 0,
                             limit: Int? = nil,
                             calendar: Calendar = .current) -> [TimeSlot] {
        let blocked = merge(expand(busy, byMinutes: bufferMinutes))
        var free: [TimeSlot] = []

        for window in windows(from: from, to: to, workingHours: workingHours,
                              weekdays: weekdays, calendar: calendar) {
            for gap in subtract(blocked, from: window) {
                guard let slot = roundStartUp(gap, toMultipleOfMinutes: roundToMinutes, calendar: calendar),
                      slot.durationMinutes >= minimumDurationMinutes
                else { continue }

                free.append(slot)
                if let limit = limit, free.count >= limit { return free }
            }
        }
        return free
    }
}
