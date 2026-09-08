import Foundation
import Testing
import TokenBarCore
@testable import TokenBarUI

/// Red Team F3 (Task 5) — degradação do coordinator quando o banco não está
/// disponível: DB corrompido (caso 1) e support directory sem permissão de
/// escrita (caso 2, "disco cheio"/volume readonly na abertura). O contrato é
/// o mesmo do T1: persistência é ADITIVA — `AppDatabase.open` falha → `nil` →
/// comportamento F2 (ingest/display seguem, history7d omitido), NUNCA crash.
@MainActor
@Suite
struct CoordinatorRedTeamTests {
    /// Corpus com 1 evento de hoje (mesmo fixture dos testes de heartbeat).
    private func writeTodayLine(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = #"{"type":"assistant","timestamp":"\#(f.string(from: Date()))","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":33,"output_tokens":44}}}"#
        try (line + "\n").write(to: dir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
    }

    private func heartbeat(_ e2e: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: e2e.appendingPathComponent("state.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("caso 1: tokenbar.sqlite corrompido → app vivo em modo F2, history7d omitido, sem crash")
    func corruptDatabaseDegradesToModeF2() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t5-rt1-\(UUID().uuidString)", isDirectory: true)
        let claude = root.appendingPathComponent("claude/proj", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let e2e = root.appendingPathComponent("e2e", isDirectory: true)
        for dir in [root, claude, support, e2e] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTodayLine(to: claude)

        // DB truncado no meio (simula crash de disco durante escrita).
        let dbURL = support.appendingPathComponent(AppDatabase.databaseName)
        let healthy = try AppDatabase.open(at: dbURL)
        for i in 0..<200 {
            try healthy.persistBatch(
                provider: .claude, path: "/p/f\(i).jsonl",
                events: [UsageEvent(
                    ts: Date(), provider: .claude,
                    account: AccountID(provider: .claude, key: "local"),
                    model: "claude-sonnet-4-6", inputTokens: 1, outputTokens: 1,
                    cacheReadTokens: 0, cacheWriteTokens: 0, project: nil)],
                endOffset: UInt64(i * 100), resetToZero: false)
        }
        let raw = try Data(contentsOf: dbURL)
        try raw.prefix(raw.count / 2).write(to: dbURL)
        // Sem WAL: a corrupção do arquivo principal precisa ser real (com o
        // WAL intacto o SQLite recupera tudo e a consulta legítima funciona —
        // histórico presente é o comportamento CORRETO nesse caso).
        try? FileManager.default.removeItem(at: support.appendingPathComponent("tokenbar.sqlite-wal"))
        try? FileManager.default.removeItem(at: support.appendingPathComponent("tokenbar.sqlite-shm"))

        let coordinator = ProviderCoordinator(config: ProviderCoordinatorConfig(
            environment: ["TOKENBAR_CLAUDE_DIR": claude.path],
            home: root, supportDirectory: support, e2eDirectory: e2e))
        await coordinator.refreshAllNow()

        let json = try heartbeat(e2e)
        let providers = try #require(json["providers"] as? [String: Any])
        let claudeEntry = try #require(providers["claude"] as? [String: Any])
        // Ingest/display seguem (persistência é aditiva; o DB não derruba o app).
        #expect(claudeEntry["todayTokens"] as? Int == 77)
        // history7d OMITIDO (consulta não rodou — nada fake no contrato v3).
        #expect(claudeEntry["history7d"] == nil)
        #expect(json["menuBarText"] as? String == "C:77")
    }

    @Test("caso 2: support dir sem permissão de escrita (disco cheio/readonly) → app vivo, sem history7d, sem crash")
    func readOnlySupportDirectoryDegradesGracefully() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t5-rt2-\(UUID().uuidString)", isDirectory: true)
        let claude = root.appendingPathComponent("claude/proj", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let e2e = root.appendingPathComponent("e2e", isDirectory: true)
        for dir in [root, claude, support, e2e] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path)
            try? FileManager.default.removeItem(at: root)
        }
        try writeTodayLine(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: support.path)

        let coordinator = ProviderCoordinator(config: ProviderCoordinatorConfig(
            environment: ["TOKENBAR_CLAUDE_DIR": claude.path],
            home: root, supportDirectory: support, e2eDirectory: e2e))
        await coordinator.refreshAllNow()

        let json = try heartbeat(e2e)
        let providers = try #require(json["providers"] as? [String: Any])
        let claudeEntry = try #require(providers["claude"] as? [String: Any])
        #expect(claudeEntry["todayTokens"] as? Int == 77)   // display segue correto
        #expect(claudeEntry["history7d"] == nil)            // sem DB → modo F2
        #expect(json["menuBarText"] as? String == "C:77")
        #expect(!FileManager.default.fileExists(
            atPath: support.appendingPathComponent(AppDatabase.databaseName).path))
    }
}
