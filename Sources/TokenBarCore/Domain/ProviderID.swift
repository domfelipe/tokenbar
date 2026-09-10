public enum ProviderID: String, Sendable, Codable, CaseIterable {
    case claude, codex, gemini, zai, cursor, openrouter, copilot
    // F5 Task 5 (paridade CodexBar — docs/specs/f5-providers.md).
    case alibaba, antigravity, deepseek, grok
}
