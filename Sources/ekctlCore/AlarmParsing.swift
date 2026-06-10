import Foundation

/// Parses the `--alarms` flag: comma-separated minute offsets relative to the
/// event start, returned as EventKit-ready second offsets for
/// `EKAlarm(relativeOffset:)`.
///
/// Sign convention (matches the CLI help text):
///   - bare positive values mean minutes *before* the start → negative seconds
///   - a leading `+` means minutes *after* the start → positive seconds
///   - explicit negative values are minutes before, passed through as-is
///
/// Unparseable components are dropped rather than failing the whole flag.
public enum AlarmParsing {
    public static func parse(_ string: String?) -> [Double]? {
        guard let string = string else { return nil }
        return string.split(separator: ",").compactMap { component in
            let s = component.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("+") {
                return Double(s.dropFirst()).map { $0 * 60 }
            }
            guard let val = Double(s) else { return nil }
            return val < 0 ? val * 60 : -val * 60
        }
    }
}
