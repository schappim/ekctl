import ArgumentParser
import Foundation
import ekctlCore

/// `ekctl init`: installs the bundled agent skill (SKILL.md) so coding agents
/// know how to drive ekctl. Never prompts — without `--agent` it installs for
/// every agent whose config directory exists, which keeps it scriptable.
struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Install the ekctl agent skill (SKILL.md) for AI coding agents.",
        discussion: """
            Without --agent, installs for every agent detected on this Mac (its config \
            directory exists, e.g. ~/.claude or ~/.codex). An existing SKILL.md that \
            differs is backed up beside it before being replaced. Does not request \
            Calendar or Reminders access.
            """
    )

    @Option(
        name: .customLong("agent"),
        help: ArgumentHelp(
            "Agent to install for. Repeat for several, or pass 'all'. Defaults to every detected agent.",
            valueName: "agent")
    )
    var agents: [SkillAgentSelection] = []

    @Option(
        name: .long,
        help: "user installs into the agent's own config directory; project installs relative to the current directory."
    )
    var scope: SkillScope = .user

    @Flag(name: .long, help: "Report what would change without writing anything.")
    var dryRun: Bool = false

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        // `$HOME`, as every supported agent reads it, rather than the account
        // database's home: under a wrapper or sandbox that sets HOME, the
        // skill has to land in the home the agent will look in.
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let installer = SkillInstaller(
            home: home,
            projectDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            environment: environment)

        let selected = agents.isEmpty
            ? installer.detectedAgents()
            : SkillAgentSelection.resolve(agents)
        guard !selected.isEmpty else {
            print(JSONOutput.error(installer.noAgentsDetectedMessage()).format(outputFormat.format))
            throw ExitCode.failure
        }

        let results = installer.install(agents: selected, scope: scope, dryRun: dryRun)
        print(SkillInstaller.output(results, scope: scope, dryRun: dryRun).format(outputFormat.format))
        if results.contains(where: { $0.action == .failed }) {
            throw ExitCode.failure
        }
    }
}
