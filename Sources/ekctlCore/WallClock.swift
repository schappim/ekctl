import Foundation

/// Turns a Gregorian wall-clock reading ("2026-03-08 at 02:30 in New York")
/// into an instant. This one resolver backs every input that names a clock
/// time without a UTC offset, both the shorthand (`tomorrow 2:30am`,
/// `2026-03-08 02:30`) and offset-less ISO 8601 (`2026-03-08T02:30`), so the
/// two can never disagree about the same reading.
///
/// Most readings name exactly one instant. Around a DST change two kinds don't,
/// and they are resolved like this:
///
/// - **Gap (spring forward).** 02:30 on 2026-03-08 never happens in New York;
///   the clock jumps from 01:59:59 to 03:00. It is read with the offset in force
///   *before* the jump, which carries it forward by the length of the gap: 02:30
///   becomes 03:30 EDT, and 02:15 on Lord Howe Island's half-hour change becomes
///   02:45. It is not rejected: the shorthand has always resolved
///   `tomorrow 2:30am` this way, a script that books "2:30 every night" should
///   not fail on one night a year, and moving forward keeps the time on the day
///   that was asked for, a few minutes after the clock time it named.
/// - **Repeat (fall back).** 01:30 on 2026-11-01 happens twice in New York. The
///   *first* occurrence wins (01:30 EDT, -04:00), as it has for the shorthand.
///   That's the 01:30 a clock watched from the start of the day reaches first.
///
/// This matches what `Calendar.date(from:)` does on current macOS. It is spelled
/// out here rather than left to Foundation because Foundation doesn't document
/// it, and the ICU-backed `Calendar` on older systems resolves repeated times
/// with its own defaults. A scheduling tool shouldn't book a different hour
/// depending on which macOS it runs on.
enum WallClock {

    /// The instant at which `timeZone`'s clocks read the given Gregorian date and
    /// time. Fields must already be in range; this does no validation beyond
    /// what building the date requires.
    static func instant(year: Int, month: Int, day: Int,
                        hour: Int, minute: Int, second: Int,
                        in timeZone: TimeZone) -> Date? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        // The reading as if it were UTC. Subtracting the zone's offset gives the
        // real instant; the work is in knowing which offset.
        guard let naive = utc.date(from: components) else { return nil }

        // A day either side brackets any transition near this reading: UTC
        // offsets lie within -12h...+14h, so both samples land at least ten
        // hours from the instant being solved for.
        let offsets = Set([
            timeZone.secondsFromGMT(for: naive.addingTimeInterval(-86_400)),
            timeZone.secondsFromGMT(for: naive.addingTimeInterval(86_400)),
        ])

        // An offset is genuine if the zone actually uses it at the instant it
        // produces. Two genuine offsets mean a repeated time; take the earlier.
        let genuine = offsets
            .map { naive.addingTimeInterval(-TimeInterval($0)) }
            .filter { candidate in
                naive.timeIntervalSince(candidate) == TimeInterval(timeZone.secondsFromGMT(for: candidate))
            }
        if let earliest = genuine.min() { return earliest }

        // None genuine: the reading falls in a gap. The clock jumped forward, so
        // the smaller offset is the one in force before the jump.
        guard let before = offsets.min() else { return nil }
        return naive.addingTimeInterval(-TimeInterval(before))
    }
}

/// A change between two clock readings, measured in clock time rather than
/// elapsed time.
///
/// Moving a meeting "from 01:30 to 03:30" on the night the clocks go forward
/// is two hours on the clock but one hour of elapsed time; applied to the
/// rest of a series, only the clock reading gives 03:30 on every other day.
/// Readings are taken in one zone (the event's own, not necessarily the
/// Mac's), so a shift measured in New York lands at the same New York clock
/// time however the user's own zone changes in between.
public struct WallClockShift: Equatable {
    /// The difference between the two readings as floating (zone-free)
    /// seconds.
    public let seconds: TimeInterval
    public let timeZone: TimeZone

    public init(from: Date, to: Date, in timeZone: TimeZone) {
        self.timeZone = timeZone
        seconds = Self.floating(to, in: timeZone) - Self.floating(from, in: timeZone)
    }

    public var isZero: Bool { seconds == 0 }

    /// The instant whose clock reading is `date`'s reading moved by this
    /// shift. Readings that land in a DST gap or repeat resolve as
    /// `WallClock.instant` does.
    public func applied(to date: Date) -> Date {
        reading(Self.floating(date, in: timeZone) + seconds)
    }

    private func reading(_ floating: TimeInterval) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = utc.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: floating))
        return WallClock.instant(
            year: c.year!, month: c.month!, day: c.day!, hour: c.hour!, minute: c.minute!, second: c.second!,
            in: timeZone) ?? Date(timeIntervalSince1970: floating)
    }

    /// The clock reading of `date` in `timeZone`, as seconds since a
    /// zone-free epoch.
    public static func floating(_ date: Date, in timeZone: TimeZone) -> TimeInterval {
        date.timeIntervalSince1970 + TimeInterval(timeZone.secondsFromGMT(for: date))
    }
}
