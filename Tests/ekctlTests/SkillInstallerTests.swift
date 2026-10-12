import Foundation
import XCTest
import ekctlCore

final class SkillInstallerTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var project: URL!
    private let skill = Data("---\nname: ekctl\n---\nbundled\n".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ekctl-skill-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        home = root.appendingPathComponent("home")
        project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installer(
        environment: [String: String] = [:], now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> SkillInstaller {
        SkillInstaller(
            skill: skill, home: home, projectDirectory: project,
            environment: environment, now: { now })
    }

    private func contents(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    private func write(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: - Paths

    func testUserScopePaths() {
        let sut = installer()
        let expected: [SkillAgent: String] = [
            .codex: ".agents/skills/ekctl/SKILL.md",
            .claude: ".claude/skills/ekctl/SKILL.md",
            .pi: ".pi/agent/skills/ekctl/SKILL.md",
            .antigravity: ".gemini/antigravity-cli/skills/ekctl/SKILL.md",
            .antigravityIDE: ".gemini/config/skills/ekctl/SKILL.md",
            .opencode: ".config/opencode/skills/ekctl/SKILL.md",
        ]
        for agent in SkillAgent.allCases {
            XCTAssertEqual(
                sut.skillFile(for: agent, scope: .user).path,
                home.appendingPathComponent(expected[agent]!).path, "\(agent)")
        }
    }

    func testProjectScopePaths() {
        let sut = installer()
        let expected: [SkillAgent: String] = [
            .codex: ".agents/skills/ekctl/SKILL.md",
            .claude: ".claude/skills/ekctl/SKILL.md",
            .pi: ".pi/skills/ekctl/SKILL.md",
            .antigravity: ".agents/skills/ekctl/SKILL.md",
            .antigravityIDE: ".agents/skills/ekctl/SKILL.md",
            .opencode: ".opencode/skills/ekctl/SKILL.md",
        ]
        for agent in SkillAgent.allCases {
            XCTAssertEqual(
                sut.skillFile(for: agent, scope: .project).path,
                project.appendingPathComponent(expected[agent]!).path, "\(agent)")
        }
    }

    func testEnvironmentOverridesConfigDirectories() {
        let sut = installer(environment: [
            "CLAUDE_CONFIG_DIR": "~/custom-claude",
            "PI_CODING_AGENT_DIR": root.appendingPathComponent("pi").path,
            "XDG_CONFIG_HOME": "relative/ignored",
        ])
        XCTAssertEqual(
            sut.skillFile(for: .claude, scope: .user).path,
            home.appendingPathComponent("custom-claude/skills/ekctl/SKILL.md").path)
        XCTAssertEqual(
            sut.skillFile(for: .pi, scope: .user).path,
            root.appendingPathComponent("pi/skills/ekctl/SKILL.md").path)
        XCTAssertEqual(
            sut.skillFile(for: .opencode, scope: .user).path,
            home.appendingPathComponent(".config/opencode/skills/ekctl/SKILL.md").path)
    }

    // MARK: - Install outcomes

    func testFreshInstall() throws {
        let results = installer().install(agents: [.claude], scope: .user, dryRun: false)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].action, .installed)
        XCTAssertNil(results[0].backupPath)
        XCTAssertNil(results[0].error)
        XCTAssertEqual(contents(results[0].path), skill)
        // No temp files are left behind by the atomic write.
        let dir = URL(fileURLWithPath: results[0].path).deletingLastPathComponent().path
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["SKILL.md"])
    }

    func testIdenticalFileIsUnchangedAndUntouched() throws {
        let sut = installer()
        let path = sut.skillFile(for: .codex, scope: .user).path
        _ = sut.install(agents: [.codex], scope: .user, dryRun: false)
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: path)

        let results = sut.install(agents: [.codex], scope: .user, dryRun: false)
        XCTAssertEqual(results[0].action, .unchanged)
        XCTAssertNil(results[0].backupPath)
        let modified = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        XCTAssertEqual(modified, past)
    }

    func testDifferentFileIsBackedUpThenUpdated() throws {
        let sut = installer()
        let path = sut.skillFile(for: .pi, scope: .user).path
        try write("old skill\n", to: path)

        let results = sut.install(agents: [.pi], scope: .user, dryRun: false)
        XCTAssertEqual(results[0].action, .updated)
        XCTAssertEqual(contents(path), skill)
        let backup = try XCTUnwrap(results[0].backupPath)
        XCTAssertEqual(URL(fileURLWithPath: backup).deletingLastPathComponent().path,
                       URL(fileURLWithPath: path).deletingLastPathComponent().path)
        XCTAssertTrue(backup.hasSuffix(".bak"))
        XCTAssertEqual(contents(backup), Data("old skill\n".utf8))

        // A second update in the same second keeps the first backup.
        try write("older still\n", to: path)
        let again = sut.install(agents: [.pi], scope: .user, dryRun: false)
        let secondBackup = try XCTUnwrap(again[0].backupPath)
        XCTAssertNotEqual(secondBackup, backup)
        XCTAssertEqual(contents(backup), Data("old skill\n".utf8))
        XCTAssertEqual(contents(secondBackup), Data("older still\n".utf8))
    }

    func testDryRunWritesNothing() throws {
        let sut = installer()
        let updatePath = sut.skillFile(for: .opencode, scope: .user).path
        try write("old\n", to: updatePath)

        let results = sut.install(agents: [.claude, .opencode], scope: .user, dryRun: true)
        XCTAssertEqual(results.map(\.action), [.wouldInstall, .wouldUpdate])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
        XCTAssertEqual(contents(updatePath), Data("old\n".utf8))
        let dir = URL(fileURLWithPath: updatePath).deletingLastPathComponent().path
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["SKILL.md"])
    }

    func testProjectScopeWritesUnderProjectAndSharesAgentsDirectory() {
        let results = installer().install(
            agents: SkillAgentSelection.resolve([.all]), scope: .project, dryRun: false)
        XCTAssertEqual(results.map(\.agent), SkillAgent.allCases)
        XCTAssertTrue(results.allSatisfy { $0.path.hasPrefix(project.path + "/") })
        XCTAssertTrue(results.allSatisfy { $0.action == .installed })
        // Codex and both Antigravity variants share .agents/skills: one file, same row.
        let shared = results.filter { [.codex, .antigravity, .antigravityIDE].contains($0.agent) }
        XCTAssertEqual(Set(shared.map(\.path)).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
    }

    func testFailureIsReportedPerAgent() throws {
        // A plain file where the skills directory should be.
        try write("not a directory\n", to: home.appendingPathComponent(".claude/skills").path)

        let results = installer().install(agents: [.codex, .claude], scope: .user, dryRun: false)
        XCTAssertEqual(results[0].action, .installed)
        XCTAssertEqual(results[1].action, .failed)
        XCTAssertTrue(results[1].error?.contains("not a directory") ?? false, results[1].error ?? "")
        XCTAssertEqual(
            installer().install(agents: [.claude], scope: .user, dryRun: true)[0].action, .failed,
            "dry run should report the same failure")

        let payload = SkillInstaller.output(results, scope: .user, dryRun: false).toDictionary()
        XCTAssertEqual(payload["status"] as? String, "error")
        XCTAssertEqual(payload["count"] as? Int, 2)
        let rows = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(rows[1]["action"] as? String, "failed")
        XCTAssertNotNil(rows[1]["error"])
        XCTAssertNil(rows[0]["error"])
    }

    func testSymlinkedSkillFileIsNotReplaced() throws {
        let sut = installer()
        let path = sut.skillFile(for: .claude, scope: .user).path
        let target = root.appendingPathComponent("elsewhere/SKILL.md").path
        try write("someone else's\n", to: target)
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)

        let results = sut.install(agents: [.claude], scope: .user, dryRun: false)
        XCTAssertEqual(results[0].action, .failed)
        XCTAssertEqual(contents(target), Data("someone else's\n".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path), target)
    }

    // MARK: - Selection and detection

    func testAgentSelectionParsing() {
        XCTAssertEqual(SkillAgentSelection(argument: "all"), .all)
        XCTAssertEqual(SkillAgentSelection(argument: "claude-code"), .agent(.claude))
        XCTAssertEqual(SkillAgentSelection(argument: "antigravity-ide"), .agent(.antigravityIDE))
        XCTAssertNil(SkillAgentSelection(argument: "vim"))
        XCTAssertEqual(SkillAgentSelection.resolve([.all]), SkillAgent.allCases)
        XCTAssertEqual(
            SkillAgentSelection.resolve([.agent(.opencode), .agent(.codex), .agent(.opencode)]),
            [.codex, .opencode])
    }

    func testDetectionWithNoAgents() {
        let sut = installer()
        XCTAssertEqual(sut.detectedAgents(), [])
        let message = sut.noAgentsDetectedMessage()
        for value in SkillAgentSelection.allValueStrings {
            XCTAssertTrue(message.contains(value), "message should list \(value)")
        }
        XCTAssertTrue(message.contains("~/.claude"))
    }

    func testDetectionFindsConfigDirectories() throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        // A file, not a directory, doesn't count.
        try write("x", to: home.appendingPathComponent(".config/opencode").path)
        XCTAssertEqual(installer().detectedAgents(), [.codex, .claude])
    }

    // MARK: - Output

    func testResultsRenderAsCSVRows() {
        let results = installer().install(agents: [.codex, .claude], scope: .user, dryRun: true)
        let csv = SkillInstaller.output(results, scope: .user, dryRun: true).format(.csv)
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "action,agent,displayName,path")
        XCTAssertTrue(lines[1].hasPrefix("would-install,codex,Codex,"))
        XCTAssertTrue(lines[2].hasPrefix("would-install,claude,Claude Code,"))
    }

    // MARK: - Bundled skill

    func testEmbeddedSkillMatchesRepositoryFile() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ekctlTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()
        let file = repoRoot.appendingPathComponent("skills/ekctl/SKILL.md")
        let onDisk = try Data(contentsOf: file)
        XCTAssertEqual(
            Data(BundledSkill.content.utf8), onDisk,
            "Sources/ekctlCore/BundledSkill.swift must be byte-identical to skills/ekctl/SKILL.md")
        XCTAssertTrue(BundledSkill.content.hasPrefix("---\nname: ekctl\n"))
    }

    // MARK: - Hardening

    /// A cloned repository can't use a linked skill directory to make a
    /// project install write outside the project.
    func testProjectInstallRefusesLinkLeadingOutsideTheProject() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent(".claude/skills/ekctl"), withDestinationURL: outside)

        for dryRun in [true, false] {
            let result = installer().install(agents: [.claude], scope: .project, dryRun: dryRun)[0]
            XCTAssertEqual(result.action, .failed, "dryRun: \(dryRun)")
            XCTAssertTrue(result.error?.contains("outside the project") ?? false, result.error ?? "")
        }
        XCTAssertNil(contents(outside.appendingPathComponent("SKILL.md").path))
    }

    func testReplacedFileKeepsItsPermissions() throws {
        let file = installer().skillFile(for: .claude, scope: .project).path
        try write("old", to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)

        XCTAssertEqual(installer().install(agents: [.claude], scope: .project, dryRun: false)[0].action, .updated)
        let mode = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testRelativeEnvironmentPathFailsRatherThanFallingBack() {
        let result = installer(environment: ["CLAUDE_CONFIG_DIR": "myclaude"])
            .install(agents: [.claude], scope: .user, dryRun: true)[0]
        XCTAssertEqual(result.action, .failed)
        XCTAssertTrue(result.error?.contains("CLAUDE_CONFIG_DIR") ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
    }

    /// Dry runs report the same failures a real run would hit.
    func testDryRunReportsUnwritableAndDanglingDirectories() throws {
        let skills = project.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: skills.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: skills.path) }
        XCTAssertEqual(installer().install(agents: [.claude], scope: .project, dryRun: true)[0].action, .failed)

        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".pi/skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent(".pi/skills/ekctl"),
            withDestinationURL: root.appendingPathComponent("missing"))
        let dangling = installer().install(agents: [.pi], scope: .project, dryRun: true)[0]
        XCTAssertEqual(dangling.action, .failed)
        XCTAssertTrue(dangling.error?.contains("doesn't exist") ?? false, dangling.error ?? "")
    }
}
