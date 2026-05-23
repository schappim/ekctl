import Foundation

/// Pure date arithmetic for the `today` / `tomorrow` / `next` convenience
/// subcommands. Kept side-effect-free and parameterised on `now` and
/// `calendar` so unit tests can pin them to specific instants and zones
/// rather than wallclock time.
///
/// All ranges are half-open: `[start, end)`. The `end` is the start of the
/// following day, so EventKit's `predicateForEvents(withStart:end:)` —
/// which is inclusive on both ends — won't double-count midnight events.
public enum DateRanges {

    /// Range covering the local day containing `now`.
    public static func today(now: Date = Date(),
                             calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return (start, end)
    }

    /// Range covering the local day after the one containing `now`.
    public static func tomorrow(now: Date = Date(),
                                calendar: Calendar = .current) -> (start: Date, end: Date) {
        let startToday = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: 1, to: startToday)!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return (start, end)
    }

    /// Range from `now` to `now + days` (used by `ekctl next`'s lookahead
    /// window). Uses calendar arithmetic so DST transitions are handled
    /// correctly — straight `TimeInterval(days * 86400)` arithmetic would
    /// be off by an hour twice a year.
    public static func nextWindow(now: Date = Date(),
                                  days: Int,
                                  calendar: Calendar = .current) -> (start: Date, end: Date) {
        let end = calendar.date(byAdding: .day, value: days, to: now)!
        return (now, end)
    }
}
