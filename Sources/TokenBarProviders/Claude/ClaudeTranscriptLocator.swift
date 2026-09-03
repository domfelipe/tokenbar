import Foundation

public struct ClaudeTranscriptLocator: Sendable {
    public let projectsDirectory: URL

    public init(projectsDirectory: URL) {
        self.projectsDirectory = projectsDirectory
    }

    public static func resolve(environment: [String: String], home: URL) -> ClaudeTranscriptLocator {
        if let override = environment["TOKENBAR_CLAUDE_DIR"], !override.isEmpty {
            return ClaudeTranscriptLocator(projectsDirectory: URL(filePath: override))
        }
        return ClaudeTranscriptLocator(
            projectsDirectory: home.appendingPathComponent(".claude/projects", isDirectory: true)
        )
    }

    public static func resolve() -> ClaudeTranscriptLocator {
        resolve(
            environment: ProcessInfo.processInfo.environment,
            home: URL(filePath: NSHomeDirectory())
        )
    }
}
