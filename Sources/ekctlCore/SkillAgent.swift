import ArgumentParser
import Foundation

/// A coding agent that `ekctl init` can install the bundled skill for.
///
/// Raw values are the `--agent` spellings, chosen to match other tools that
/// install agent skills so a user's muscle memory carries over. `allCases`
/// order is the order results are reported in.
public enum SkillAgent: String, CaseIterable, Sendable {
    case codex
    case claude
    case pi
    case antigravity
    case antigravityIDE = "antigravity-ide"
    case opencode

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .pi: return "Pi"
        case .antigravity: return "Antigravity CLI"
        case .antigravityIDE: return "Antigravity IDE"
        case .opencode: return "OpenCode"
        }
    }

    /// Accepts the raw value plus the longer product spellings people type.
    public init?(name: String) {
        switch name.lowercased() {
        case "claude-code": self = .claude
        case "antigravity-cli", "agy": self = .antigravity
        default: self.init(rawValue: name.lowercased())
        }
    }
}

/// Where the skill is installed: the user's own agent config, or the current
/// project (relative to the working directory) so it can be committed.
public enum SkillScope: String, CaseIterable, ExpressibleByArgument, Sendable {
    case user
    case project

    public static var allValueStrings: [String] { allCases.map(\.rawValue) }
}

/// One `--agent` value: a specific agent, or `all` of them.
public enum SkillAgentSelection: ExpressibleByArgument, Equatable, Sendable {
    case all
    case agent(SkillAgent)

    public init?(argument: String) {
        if argument.lowercased() == "all" {
            self = .all
        } else if let agent = SkillAgent(name: argument) {
            self = .agent(agent)
        } else {
            return nil
        }
    }

    public static var allValueStrings: [String] {
        ["all"] + SkillAgent.allCases.map(\.rawValue)
    }

    /// Expands selections into agents, deduplicated and in `allCases` order.
    public static func resolve(_ selections: [SkillAgentSelection]) -> [SkillAgent] {
        if selections.contains(.all) { return SkillAgent.allCases }
        let chosen = Set(selections.compactMap { selection -> SkillAgent? in
            if case .agent(let agent) = selection { return agent }
            return nil
        })
        return SkillAgent.allCases.filter(chosen.contains)
    }
}
