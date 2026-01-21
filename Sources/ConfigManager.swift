import Foundation

/// ConfigManager handles reading and writing the ekctl configuration file.
/// Configuration is stored at ~/.ekctl/config.json
struct ConfigManager {
    private static let configDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ekctl")
    private static let configFile = configDirectory.appendingPathComponent("config.json")

    /// The configuration data structure
    struct Config: Codable {
        var aliases: [String: String] // alias name -> calendar/list ID
        var version: Int

        init() {
            self.aliases = [:]
            self.version = 1
        }
    }

    /// Loads the configuration from disk, or returns a default config if none exists
    static func load() -> Config {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            return Config()
        }

        do {
            let data = try Data(contentsOf: configFile)
            let config = try JSONDecoder().decode(Config.self, from: data)
            return config
        } catch {
            // If config is corrupted, return default
            return Config()
        }
    }

    /// Saves the configuration to disk
    static func save(_ config: Config) throws {
        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: configDirectory.path) {
            try FileManager.default.createDirectory(
                at: configDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configFile)
    }

    // MARK: - Alias Operations

    /// Sets an alias for a calendar/list ID
    static func setAlias(name: String, id: String) throws {
        var config = load()
        config.aliases[name] = id
        try save(config)
    }

    /// Removes an alias
    static func removeAlias(name: String) throws -> Bool {
        var config = load()
        guard config.aliases.removeValue(forKey: name) != nil else {
            return false
        }
        try save(config)
        return true
    }

    /// Gets all aliases
    static func getAliases() -> [String: String] {
        return load().aliases
    }

    /// Resolves an alias to an ID, or returns the input if it's not an alias
    static func resolveAlias(_ nameOrID: String) -> String {
        let config = load()
        return config.aliases[nameOrID] ?? nameOrID
    }

    /// Gets the config file path (for display purposes)
    static func configPath() -> String {
        return configFile.path
    }
}
