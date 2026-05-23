import ArgumentParser
import Foundation

/// CLI-facing enum for filtering events by their EKEventAvailability value.
/// Raw values match the strings emitted by `eventToDict`'s availability field,
/// so filter input and JSON output use the same vocabulary.
public enum AvailabilityFilter: String, CaseIterable, ExpressibleByArgument {
    case busy, free, tentative, unavailable, notSupported

    public static var allValueStrings: [String] {
        Self.allCases.map(\.rawValue)
    }
}

/// Pure, side-effect-free filter predicates. Kept as static helpers so they
/// can be exercised by unit tests without an `EKEventStore`.
public enum EventFilter {
    /// Case-insensitive substring match across the provided text fields.
    /// A `nil` or empty needle is a no-op (returns `true`) so callers can
    /// always pipe input through without an extra guard.
    public static func matchesSearch(_ needle: String?, in fields: [String?]) -> Bool {
        guard let needle = needle?.lowercased(), !needle.isEmpty else { return true }
        return fields.contains { ($0 ?? "").lowercased().contains(needle) }
    }

    /// Match an event's emitted availability string against an
    /// `AvailabilityFilter`. A `nil` filter is a no-op (returns `true`).
    public static func matchesAvailability(_ filter: AvailabilityFilter?,
                                           eventAvailability: String) -> Bool {
        guard let filter = filter else { return true }
        return eventAvailability.lowercased() == filter.rawValue.lowercased()
    }
}
