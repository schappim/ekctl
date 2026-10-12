import Foundation

/// The outcome of installing the skill for one agent.
public struct SkillInstallResult: Equatable, Sendable {
    public enum Action: String, Sendable {
        case installed
        case updated
        case unchanged
        case wouldInstall = "would-install"
        case wouldUpdate = "would-update"
        case failed
    }

    public let agent: SkillAgent
    public let path: String
    public let action: Action
    public let backupPath: String?
    public let error: String?

    /// Row for JSON / CSV / text output. Optional keys are omitted, not null,
    /// so text output only shows a backup or error line when there is one.
    public var dictionary: [String: Any] {
        var row: [String: Any] = [
            "agent": agent.rawValue,
            "displayName": agent.displayName,
            "path": path,
            "action": action.rawValue,
        ]
        if let backupPath { row["backupPath"] = backupPath }
        if let error { row["error"] = error }
        return row
    }
}

/// Installs the bundled `SKILL.md` into each agent's skills directory.
///
/// Pure filesystem logic with the home directory, project directory, and
/// environment all injected, so tests run against temp directories and never
/// touch the real `~`.
///
/// Directory layout, per agent (`<name>` is `ekctl`):
///
/// | Agent           | User scope                                  | Project scope                |
/// | --------------- | ------------------------------------------- | ---------------------------- |
/// | Codex           | `~/.agents/skills/<name>/`                  | `.agents/skills/<name>/`     |
/// | Claude Code     | `$CLAUDE_CONFIG_DIR` or `~/.claude`, `/skills/<name>/` | `.claude/skills/<name>/` |
/// | Pi              | `$PI_CODING_AGENT_DIR` or `~/.pi/agent`, `/skills/<name>/` | `.pi/skills/<name>/` |
/// | Antigravity CLI | `~/.gemini/antigravity-cli/skills/<name>/`  | `.agents/skills/<name>/`     |
/// | Antigravity IDE | `~/.gemini/config/skills/<name>/`           | `.agents/skills/<name>/`     |
/// | OpenCode        | `$XDG_CONFIG_HOME` or `~/.config`, `/opencode/skills/<name>/` | `.opencode/skills/<name>/` |
///
/// Several agents share `.agents/skills` at project scope; that file is
/// written once and every agent that reads it reports the same outcome.
public struct SkillInstaller {
    public static let skillName = "ekctl"
    public static let fileName = "SKILL.md"

    public let skill: Data
    public let home: URL
    public let projectDirectory: URL
    public let environment: [String: String]
    private let now: () -> Date
    private let fileManager = FileManager.default

    public init(
        skill: Data = Data(BundledSkill.content.utf8),
        home: URL,
        projectDirectory: URL,
        environment: [String: String],
        now: @escaping () -> Date = Date.init
    ) {
        self.skill = skill
        self.home = home
        self.projectDirectory = projectDirectory
        self.environment = environment
        self.now = now
    }

    // MARK: - Locations

    /// The agent's own config directory. Its existence is what "detected"
    /// means: it's created the first time the agent runs.
    public func configDirectory(for agent: SkillAgent) -> URL {
        switch agent {
        case .codex: return path(fromEnvironment: "CODEX_HOME") ?? home.appendingPathComponent(".codex")
        case .claude: return path(fromEnvironment: "CLAUDE_CONFIG_DIR") ?? home.appendingPathComponent(".claude")
        case .pi: return path(fromEnvironment: "PI_CODING_AGENT_DIR") ?? home.appendingPathComponent(".pi/agent")
        case .antigravity: return home.appendingPathComponent(".gemini/antigravity-cli")
        case .antigravityIDE: return home.appendingPathComponent(".gemini/antigravity")
        case .opencode:
            let base = path(fromEnvironment: "XDG_CONFIG_HOME") ?? home.appendingPathComponent(".config")
            return base.appendingPathComponent("opencode")
        }
    }

    public func skillsDirectory(for agent: SkillAgent, scope: SkillScope) -> URL {
        switch scope {
        case .project:
            let relative: String
            switch agent {
            case .codex, .antigravity, .antigravityIDE: relative = ".agents/skills"
            case .claude: relative = ".claude/skills"
            case .pi: relative = ".pi/skills"
            case .opencode: relative = ".opencode/skills"
            }
            return projectDirectory.appendingPathComponent(relative)
        case .user:
            switch agent {
            // Codex reads user skills from ~/.agents/skills, not $CODEX_HOME.
            case .codex: return home.appendingPathComponent(".agents/skills")
            case .antigravityIDE: return home.appendingPathComponent(".gemini/config/skills")
            case .claude, .pi, .antigravity, .opencode:
                return configDirectory(for: agent).appendingPathComponent("skills")
            }
        }
    }

    public func skillFile(for agent: SkillAgent, scope: SkillScope) -> URL {
        skillsDirectory(for: agent, scope: scope)
            .appendingPathComponent(Self.skillName)
            .appendingPathComponent(Self.fileName)
    }

    public func isDetected(_ agent: SkillAgent) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: configDirectory(for: agent).path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public func detectedAgents() -> [SkillAgent] {
        SkillAgent.allCases.filter(isDetected)
    }

    /// The error for a bare `ekctl init` on a machine with no known agents.
    public func noAgentsDetectedMessage() -> String {
        let looked = SkillAgent.allCases.map { tildePath(configDirectory(for: $0)) }
        return "No supported coding agents detected (looked for "
            + looked.joined(separator: ", ")
            + "). Choose explicitly with --agent: "
            + SkillAgentSelection.allValueStrings.joined(separator: ", ") + "."
    }

    // MARK: - Install

    public func install(
        agents: [SkillAgent], scope: SkillScope, dryRun: Bool
    ) -> [SkillInstallResult] {
        var outcomes: [String: (SkillInstallResult.Action, String?, String?)] = [:]
        return agents.map { agent in
            let file = skillFile(for: agent, scope: scope)
            let outcome: (SkillInstallResult.Action, String?, String?)
            if let shared = outcomes[file.path] {
                outcome = shared
            } else {
                do {
                    try checkEnvironment(for: agent, scope: scope)
                    let (action, backup) = try installFile(
                        at: file, dryRun: dryRun, within: scope == .project ? projectDirectory : nil)
                    outcome = (action, backup, nil)
                } catch {
                    outcome = (.failed, nil, Self.describe(error))
                }
                outcomes[file.path] = outcome
            }
            return SkillInstallResult(
                agent: agent, path: file.path,
                action: outcome.0, backupPath: outcome.1, error: outcome.2)
        }
    }

    /// The command's whole JSON payload. `status` is `error` if any agent
    /// failed, but the per-agent rows are still reported so the caller can
    /// see which ones succeeded.
    public static func output(
        _ results: [SkillInstallResult], scope: SkillScope, dryRun: Bool
    ) -> JSONOutput {
        var payload: [String: Any] = [
            "results": results.map(\.dictionary),
            "count": results.count,
            "scope": scope.rawValue,
            "dryRun": dryRun,
        ]
        let failed = results.filter { $0.action == .failed }
        if !failed.isEmpty {
            payload["status"] = "error"
            payload["error"] = "Failed to install the skill for "
                + failed.map(\.agent.displayName).joined(separator: ", ")
        }
        return JSONOutput.success(payload)
    }

    // MARK: - Filesystem

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Writes one SKILL.md, returning the action taken and any backup path.
    ///
    /// Symlinks: directory symlinks anywhere on the path (a dotfiles-managed
    /// `~/.claude`, or a `skills/ekctl` linked to a shared copy) are followed
    /// as normal — the temp file is created in the resolved directory, so the
    /// rename is still atomic and lands where the agent reads from. A
    /// symlinked SKILL.md itself is different: renaming over it would replace
    /// the link with a plain file and silently detach it from wherever it
    /// pointed, while writing through it would edit a file outside the
    /// skills directory. Neither is what the user set up, so a linked
    /// SKILL.md is left alone — reported `unchanged` when its target already
    /// matches, and `failed` with an explanation otherwise.
    ///
    /// At project scope (`within`), the skill must also *land* inside the
    /// project once links are resolved. A repository can ship
    /// `.claude/skills/ekctl` as a link to anywhere, and following it would
    /// let a cloned project make `ekctl init` overwrite (say) another skill in
    /// the user's own `~/.claude/skills`.
    private func installFile(
        at file: URL, dryRun: Bool, within root: URL?
    ) throws -> (SkillInstallResult.Action, String?) {
        let directory = file.deletingLastPathComponent()
        try checkDirectoryIsCreatable(directory)
        if let root = root {
            let resolvedRoot = root.resolvingSymlinksInPath().path
            let resolved = resolvedExistingPrefix(of: directory)
            guard resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/") else {
                throw InstallError(message:
                    "\(directory.path) leads outside the project (to \(resolved)) through a symbolic link; "
                    + "ekctl won't install a project skill there.")
            }
        }

        let existing = try? fileManager.attributesOfItem(atPath: file.path)  // does not follow links
        let isUpdate: Bool
        switch existing?[.type] as? FileAttributeType {
        case nil:
            isUpdate = false
        case .typeSymbolicLink?:
            if let current = try? Data(contentsOf: file), current == skill {
                return (.unchanged, nil)
            }
            throw InstallError(message:
                "\(file.path) is a symbolic link; ekctl won't replace a linked skill. "
                + "Update the file it points to, or remove the link and run init again.")
        case .typeRegular?:
            if try Data(contentsOf: file) == skill { return (.unchanged, nil) }
            isUpdate = true
        default:
            throw InstallError(message: "\(file.path) exists but is not a regular file.")
        }

        if dryRun { return (isUpdate ? .wouldUpdate : .wouldInstall, nil) }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var backup: URL?
        if isUpdate {
            let backupURL = backupLocation(for: file)
            try fileManager.copyItem(at: file, to: backupURL)
            backup = backupURL
        }
        do {
            try atomicWrite(skill, to: file)
        } catch {
            // The original is untouched, so its backup is just clutter.
            if let backup = backup { try? fileManager.removeItem(at: backup) }
            throw error
        }
        return (isUpdate ? .updated : .installed, backup?.path)
    }

    /// Fails early, and identically in dry runs, when the skills directory
    /// can't be created or written: something that isn't a directory (or a
    /// link to nowhere) sits on the path, or the nearest existing directory
    /// isn't writable. A dry run that promises `would-install` should mean
    /// the real run installs.
    private func checkDirectoryIsCreatable(_ directory: URL) throws {
        var candidate = directory
        while true {
            // `attributesOfItem` doesn't follow links, so a dangling one is
            // seen for what it is rather than as "nothing here yet".
            if (try? fileManager.attributesOfItem(atPath: candidate.path)) != nil {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
                    throw InstallError(message:
                        "Cannot create \(directory.path): \(candidate.path) is a symbolic link to something "
                        + "that doesn't exist.")
                }
                guard isDirectory.boolValue else {
                    throw InstallError(message:
                        "Cannot create \(directory.path): \(candidate.path) exists and is not a directory.")
                }
                guard fileManager.isWritableFile(atPath: candidate.path) else {
                    throw InstallError(message:
                        "Cannot write to \(candidate.path): permission denied.")
                }
                return
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return }
            candidate = parent
        }
    }

    /// `url` with links resolved as far as the path exists, and the rest
    /// appended unchanged.
    private func resolvedExistingPrefix(of url: URL) -> String {
        var existing = url
        var rest: [String] = []
        while (try? fileManager.attributesOfItem(atPath: existing.path)) == nil {
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break }
            rest.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        return rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }

    /// `SKILL.md.<timestamp>.bak` beside the original, never overwriting an
    /// earlier backup.
    private func backupLocation(for file: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now())
        let directory = file.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent("\(Self.fileName).\(stamp).bak")
        var counter = 2
        while (try? fileManager.attributesOfItem(atPath: candidate.path)) != nil {
            candidate = directory.appendingPathComponent("\(Self.fileName).\(stamp)-\(counter).bak")
            counter += 1
        }
        return candidate
    }

    /// Writes to a temp file in the destination's directory, then renames it
    /// into place, so an agent never reads a half-written SKILL.md.
    /// A replaced file keeps its permissions: a SKILL.md someone made
    /// private (600) shouldn't come back world-readable.
    private func atomicWrite(_ data: Data, to file: URL) throws {
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent(".\(Self.fileName).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: .withoutOverwriting)
            if let mode = (try? fileManager.attributesOfItem(atPath: file.path))?[.posixPermissions] {
                try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw InstallError(message: "Cannot write \(file.path): \(Self.describe(error))")
        }
        guard rename(temp.path, file.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: temp)
            throw InstallError(message:
                "Cannot write \(file.path): \(String(cString: strerror(code)))")
        }
    }

    // MARK: - Helpers

    /// An agent whose location comes from an environment variable set to a
    /// relative path can't be installed for: ekctl would have to guess what
    /// it's relative to, and installing at the default location instead
    /// would report success for a skill the agent never reads.
    private func checkEnvironment(for agent: SkillAgent, scope: SkillScope) throws {
        guard scope == .user else { return }
        let key: String?
        switch agent {
        case .claude: key = "CLAUDE_CONFIG_DIR"
        case .pi: key = "PI_CODING_AGENT_DIR"
        case .opencode: key = "XDG_CONFIG_HOME"
        case .codex, .antigravity, .antigravityIDE: key = nil
        }
        guard let key = key, let value = environment[key], !value.isEmpty,
              path(fromEnvironment: key) == nil
        else { return }
        throw InstallError(message:
            "\(key) is set to \"\(value)\", which isn't an absolute path, so ekctl can't tell where "
            + "\(agent.displayName) reads skills from. Set it to an absolute path, or use --scope project.")
    }

    /// An absolute or `~`-prefixed path from the environment. Relative values
    /// are ignored rather than resolved against whatever directory ekctl
    /// happens to be run from.
    private func path(fromEnvironment key: String) -> URL? {
        guard let value = environment[key], !value.isEmpty else { return nil }
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))) }
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value)
    }

    private func tildePath(_ url: URL) -> String {
        let homePath = home.path
        let path = url.path
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
