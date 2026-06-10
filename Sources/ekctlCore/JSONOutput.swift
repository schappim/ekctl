import Foundation
import ArgumentParser

/// JSONOutput provides consistent JSON formatting for all CLI output.
/// All commands output valid JSON for easy scripting and parsing.
public struct JSONOutput {
    private let data: [String: Any]

    private init(_ data: [String: Any]) {
        self.data = data
    }

    /// Creates a success response with the given data
    public static func success(_ data: [String: Any]) -> JSONOutput {
        var output = data
        if output["status"] == nil {
            output["status"] = "success"
        }
        return JSONOutput(output)
    }

    /// Creates an error response with the given message
    public static func error(_ message: String) -> JSONOutput {
        return JSONOutput([
            "status": "error",
            "error": message
        ])
    }

    /// Converts the output to a JSON string
    public func toJSON() -> String {
        do {
            let jsonData = try JSONSerialization.data(
                withJSONObject: data,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
            )
            return String(data: jsonData, encoding: .utf8) ?? "{\"error\": \"Failed to encode JSON\"}"
        } catch {
            return "{\"status\": \"error\", \"error\": \"JSON serialization failed: \(error.localizedDescription)\"}"
        }
    }

    /// Converts the JSON output back to a dictionary.
    /// Useful for scripting and testing.
    public func toDictionary() -> [String: Any] {
        guard
            let data = toJSON().data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    /// Serialises the output in the requested format.
    /// CSV and text both *derive* their fields from the same dictionary that
    /// `toJSON()` does, so new fields added to `eventToDict` / `reminderToDict`
    /// / etc. flow through automatically and can't silently lag behind JSON.
    public func format(_ format: OutputFormat) -> String {
        switch format {
        case .json: return toJSON()
        case .csv:  return OutputFormatter.csv(from: data)
        case .text: return OutputFormatter.text(from: data)
        }
    }
}

// MARK: - OutputFormat

public enum OutputFormat: String, CaseIterable, ExpressibleByArgument {
    case json, csv, text

    public static var allValueStrings: [String] { Self.allCases.map(\.rawValue) }
}

// MARK: - TimeFormat

/// How timestamps are rendered in output (issue #3). The default stays
/// RFC 3339 so existing consumers are untouched; `compact` is the opt-in
/// jq-friendly form, since jq's `strptime` can parse `%z` (`+1100`) but not
/// the colon-separated `%:z` (`+11:00`).
public enum TimeFormat: String, CaseIterable, ExpressibleByArgument {
    /// Colon-separated offset, `Z` for UTC: `2026-03-09T16:00:00+11:00`.
    case rfc3339
    /// Compact offset, never `Z`: `2026-03-09T16:00:00+1100`. UTC renders as
    /// `+0000` so the offset is always numeric for `%z` parsers.
    case compact

    public static var allValueStrings: [String] { Self.allCases.map(\.rawValue) }

    /// `DateFormatter` pattern rendering this form. `XXXXX` emits colon
    /// offsets and `Z`; lowercase `xxxx` emits compact offsets and `+0000`.
    public var dateFormatPattern: String {
        switch self {
        case .rfc3339: return "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        case .compact: return "yyyy-MM-dd'T'HH:mm:ssxxxx"
        }
    }
}

/// Shared options for commands that emit output. Add via `@OptionGroup`.
public struct OutputFormatOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Output format: json (default), csv, or text. CSV and text auto-discover fields from the JSON dictionary, so new fields appear without code changes."
    )
    public var format: OutputFormat = .json

    @Option(
        name: .long,
        help: "Timestamp rendering: rfc3339 (default, +11:00 offsets) or compact (+1100 offsets, parseable by jq strptime's %z)."
    )
    public var timeFormat: TimeFormat = .rfc3339

    public init() {}
}

// MARK: - Formatters (CSV / text)

enum OutputFormatter {
    /// CSV: pick the primary list/item in the dict, flatten each row (nested
    /// objects → dot notation, nested arrays → JSON-encoded cell), then emit
    /// `header\r\nrow\r\nrow…` with RFC 4180 escaping.
    static func csv(from data: [String: Any]) -> String {
        let rows = primaryRows(in: data).map { flatten($0) }
        guard !rows.isEmpty else { return "" }

        let keys = collectKeys(from: rows)
        let header = keys.map(csvEscape).joined(separator: ",")
        let body = rows.map { row -> String in
            keys.map { csvEscape(stringify(row[$0])) }.joined(separator: ",")
        }
        return ([header] + body).joined(separator: "\r\n")
    }

    /// Text: same row detection as CSV, but each row emits a block of
    /// `key: value` lines, separated by a blank line. Auto-discovered so it
    /// won't drift either.
    static func text(from data: [String: Any]) -> String {
        let rows = primaryRows(in: data).map { flatten($0) }
        guard !rows.isEmpty else { return "" }

        let blocks = rows.map { row -> String in
            row.keys.sorted().map { key in
                "\(key): \(stringify(row[key]))"
            }.joined(separator: "\n")
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Row detection

    /// Plural keys → return that list as rows.
    /// Singular keys → wrap in a one-element list.
    /// Otherwise → treat the whole dict as a single row.
    static func primaryRows(in data: [String: Any]) -> [[String: Any]] {
        let listKeys = ["events", "reminders", "calendars", "aliases"]
        for key in listKeys {
            if let list = data[key] as? [[String: Any]] { return list }
        }
        let itemKeys = ["event", "reminder", "calendar", "alias"]
        for key in itemKeys {
            if let item = data[key] as? [String: Any] { return [item] }
        }
        return [data]
    }

    // MARK: - Flatten

    /// Walks `dict`, lifting nested `[String: Any]` into dot-notated keys.
    /// Nested arrays are JSON-encoded into a single cell — preserves the data
    /// for round-tripping without forcing CSV consumers into a multi-row mess.
    static func flatten(_ dict: [String: Any], prefix: String = "") -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dict {
            let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                for (nk, nv) in flatten(nested, prefix: fullKey) {
                    result[nk] = nv
                }
            } else if let array = value as? [Any] {
                result[fullKey] = jsonEncode(array)
            } else {
                result[fullKey] = value
            }
        }
        return result
    }

    static func collectKeys(from rows: [[String: Any]]) -> [String] {
        var keys: Set<String> = []
        for row in rows {
            for key in row.keys { keys.insert(key) }
        }
        return keys.sorted()
    }

    // MARK: - Stringification

    static func stringify(_ value: Any?) -> String {
        guard let value = value else { return "" }
        if value is NSNull { return "" }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            // NSNumber sometimes wraps Bool — handle above; otherwise stringify
            // without the trailing `.0` that "\(n)" would produce for whole ints.
            if CFNumberIsFloatType(n) {
                return "\(n.doubleValue)"
            }
            return "\(n.int64Value)"
        }
        return "\(value)"
    }

    static func jsonEncode(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return String(describing: value) }
        return str
    }

    // MARK: - CSV escaping (RFC 4180)

    static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}

// MARK: - ExitCode Extension

public extension ExitCode {
    static let permissionDenied = ExitCode(rawValue: 2)
}
