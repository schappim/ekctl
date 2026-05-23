import Foundation

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
}

// MARK: - ExitCode Extension

import ArgumentParser

public extension ExitCode {
    static let permissionDenied = ExitCode(rawValue: 2)
}