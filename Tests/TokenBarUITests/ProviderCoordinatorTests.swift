import Darwin
import Testing
import Foundation
import TokenBarCore
@testable import TokenBarUI

/// Smoke do wiring T7 (degradação): dirs fake via env, bases de API apontando
/// pra nada, credencial sintética p/ forçar tentativa de rede do Codex —
/// sem crash, heartbeat v2 escrito com os 4 providers, credencial nunca vaza.
///
/// Não toca no App Support real: stores de cursor em memória via fábrica.
@MainActor
struct ProviderCoordinatorTests {
    private struct Fixture {
        let root: URL
        let environment: [String: String]
        let e2eDirectory: URL

        static func make(fakeToken: String) throws -> Fixture {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("tokenbar-t7-\(UUID().uuidString)", isDirectory: true)
            let claude = root.appendingPathComponent("claude", isDirectory: true)
            let codex = root.appendingPathComponent("codex", isDirectory: true)
            let gemini = root.appendingPathComponent("gemini", isDirectory: true)
            let support = root.appendingPathComponent("support", isDirectory: true)
            let e2e = root.appendingPathComponent("e2e", isDirectory: true)
            for dir in [root, claude, codex, gemini, support, e2e] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            // Credencial SINTÉTICA (não é segredo): força o caminho de rede do
            // Codex contra uma base morta → erro de rede → degradação sem crash.
            let codexAuth = root.appendingPathComponent("codex-auth.json")
            try Data("""
            {"tokens": {"access_token": "\(fakeToken)", "account_id": "t7account"}, "auth_mode": "chatgpt"}
            """.utf8).write(to: codexAuth)
            // Z.ai sem credencial nenhuma: sem rede, snapshot .missing.
            try Data("{}".utf8).write(to: root.appendingPathComponent("zai-config.json"))

            return Fixture(
                root: root,
                environment: [
                    "TOKENBAR_CLAUDE_DIR": claude.path,
                    "TOKENBAR_CODEX_DIR": codex.path,
                    "TOKENBAR_CODEX_AUTH": codexAuth.path,
                    "TOKENBAR_CODEX_API": "http://127.0.0.1:1",
                    "TOKENBAR_GEMINI_DIR": gemini.path,
                    "TOKENBAR_ZAI_CONFIG": root.appendingPathComponent("zai-config.json").path,
                    "TOKENBAR_ZAI_AUTH": root.appendingPathComponent("zai-cred.json").path,
                    "TOKENBAR_ZAI_API": "http://127.0.0.1:1",
                ],
                e2eDirectory: e2e
            )
        }
    }

    /// Timestamp de AGORA em ISO8601 fracionado (formato dos transcripts reais):
    /// o ledger só soma eventos do dia corrente.
    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private final class MemOffsetStore: FileOffsetStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: FileCursor] = [:]
        func cursors() -> [String: FileCursor] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func set(_ cursor: FileCursor?, for path: String) throws {
            lock.lock(); defer { lock.unlock() }
            if let cursor { storage[path] = cursor } else { storage.removeValue(forKey: path) }
        }
    }

    @Test("wiring degradado: 4 providers no heartbeat v2, sem crash, credencial não vaza")
    func degradedWiringWritesHeartbeatV2() async throws {
        let fakeToken = "t7-synthetic-token-never-real"
        let fixture = try Fixture.make(fakeToken: fakeToken)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let coordinator = ProviderCoordinator(config: ProviderCoordinatorConfig(
            environment: fixture.environment,
            home: fixture.root,  // home fake: nada real é lido
            supportDirectory: fixture.root.appendingPathComponent("support"),
            e2eDirectory: fixture.e2eDirectory,
            makeOffsetStore: { _ in MemOffsetStore() }
        ))

        // Um ciclo de cada provider, direto (sem start(): watchers/scheduler
        // ficam p/ o app; o smoke mira os ciclos e o heartbeat).
        await coordinator.refreshAllNow()

        let stateURL = fixture.e2eDirectory.appendingPathComponent("state.json")
        let data = try Data(contentsOf: stateURL)  // ausente → teste falha aqui
        let raw = String(decoding: data, as: UTF8.self)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["menuBarText"] as? String == "TB")  // sem dado → nada na string

        let providers = try #require(json["providers"] as? [String: Any])
        #expect(Set(providers.keys) == ["claude", "codex", "gemini", "zai"])

        let keys = ["menuBar", "percent", "todayTokens", "authState", "fetchedAt"]
        for id in providers.keys {
            let entry = try #require(providers[id] as? [String: Any])
            #expect(Set(entry.keys).isSuperset(of: Set(keys)))
            #expect(entry["fetchedAt"] != nil)
        }

        // Claude/Gemini: modo local saudável; sem janela → percent null.
        #expect((providers["claude"] as? [String: Any])?["authState"] as? String == "ok")
        #expect((providers["claude"] as? [String: Any])?["percent"] is NSNull)
        #expect((providers["gemini"] as? [String: Any])?["authState"] as? String == "ok")

        // Codex: rede contra base morta → ciclo degrada sem crash; sem dado bom
        // anterior, sem janela → percent null; o erro aparece tokenizado.
        #expect((providers["codex"] as? [String: Any])?["percent"] is NSNull)

        // Z.ai sem credencial: degrada .missing SEM request (base morta nunca tocada).
        #expect((providers["zai"] as? [String: Any])?["authState"] as? String == "missing")
        #expect((providers["zai"] as? [String: Any])?["menuBar"] is NSNull)

        // Diagnóstico (selfcheck): erro do Codex tokenizado, sem mensagem crua.
        let diagnostic = coordinator.diagnosticPayload()
        let diagnosticData = try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
        let diagnosticJSON = try #require(try JSONSerialization.jsonObject(with: diagnosticData) as? [String: Any])
        let codexEntry = try #require((diagnosticJSON["providers"] as? [String: Any])?["codex"] as? [String: Any])
        #expect(codexEntry["error"] as? String == "network")

        // Spec §9: a credencial sintética NÃO aparece em artefato nenhum.
        #expect(!raw.contains(fakeToken))

        // Idempotente: segundo ciclo reescreve o heartbeat sem crescer o estado.
        await coordinator.refreshAllNow()
        let data2 = try Data(contentsOf: stateURL)
        let json2 = try #require(try JSONSerialization.jsonObject(with: data2) as? [String: Any])
        let providers2 = try #require(json2["providers"] as? [String: Any])
        #expect(Set(providers2.keys) == Set(providers.keys))
    }

    @Test("M1 por provider: ciclo concorrente do mesmo provider vira skip")
    func concurrentCycleSkipsWhenBusy() async throws {
        let fixture = try Fixture.make(fakeToken: "t7-synthetic-token-never-real")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let coordinator = ProviderCoordinator(config: ProviderCoordinatorConfig(
            environment: fixture.environment,
            home: fixture.root,
            supportDirectory: fixture.root,
            e2eDirectory: fixture.e2eDirectory,
            makeOffsetStore: { _ in MemOffsetStore() }
        ))

        // M1 é skip-if-busy sob MainActor: dois ciclos enfileirados do mesmo
        // provider nunca se sobrepõem (o segundo roda depois — comportamento
        // observável: ambos completam e o heartbeat fica com os 4 providers).
        async let first: Void = coordinator.refreshAllNow()
        async let second: Void = coordinator.refreshAllNow()
        _ = await (first, second)

        let data = try Data(contentsOf: fixture.e2eDirectory.appendingPathComponent("state.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["providers"] as? [String: Any])?.count == 4)
        #expect(json["menuBarText"] as? String == "TB")
    }

    /// Regressão T8 (Red Team/e2e): provider API-driven cujo PRIMEIRO ciclo
    /// falha com throw (rede morta) NÃO pode sumir do heartbeat v2 — sem
    /// display, o payload omitia o provider inteiro e o token de erro se
    /// perdia (o zai com credencial contra base morta desaparecia do
    /// diagnóstico; o selfcheck de degradação do e2e demonstrou o sintoma).
    @Test("provider degradado com throw no 1º ciclo permanece no heartbeat com erro")
    func providerWithErrorOnFirstCycleStaysInPayload() async throws {
        let fakeToken = "t8-synthetic-token-never-real"
        let fixture = try Fixture.make(fakeToken: fakeToken)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Z.ai COM credencial sintética e base morta: fetchUsage lança
        // `.network` no 1º ciclo (caminho que não criava display).
        try Data("""
        {"provider": {"builtin:zai-coding-plan": {"options": {"apiKey": "\(fakeToken)"}}}}
        """.utf8).write(to: fixture.root.appendingPathComponent("zai-config.json"))

        let coordinator = ProviderCoordinator(config: ProviderCoordinatorConfig(
            environment: fixture.environment,
            home: fixture.root,
            supportDirectory: fixture.root.appendingPathComponent("support"),
            e2eDirectory: fixture.e2eDirectory,
            makeOffsetStore: { _ in MemOffsetStore() }
        ))

        await coordinator.refreshAllNow()

        let data = try Data(contentsOf: fixture.e2eDirectory.appendingPathComponent("state.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try #require(json["providers"] as? [String: Any])

        // TODOS os 4 registrados continuam no payload — inclusive o zai em erro.
        #expect(Set(providers.keys) == ["claude", "codex", "gemini", "zai"])

        // O zai degradado entra vazio (sem dado inventado) com o erro tokenizado
        // no diagnóstico — nunca mensagem crua com URL (spec §9).
        let zai = try #require(providers["zai"] as? [String: Any])
        #expect(zai["menuBar"] is NSNull)
        #expect(zai["percent"] is NSNull)
        #expect(zai["authState"] as? String == "missing")

        let diagnostic = coordinator.diagnosticPayload()
        let diagnosticData = try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
        let diagnosticJSON = try #require(try JSONSerialization.jsonObject(with: diagnosticData) as? [String: Any])
        let zaiEntry = try #require((diagnosticJSON["providers"] as? [String: Any])?["zai"] as? [String: Any])
        #expect(zaiEntry["error"] as? String == "network")

        // A credencial sintética não vaza em artefato nenhum (spec §9).
        let raw = String(decoding: data, as: UTF8.self)
        #expect(!raw.contains(fakeToken))
    }

    /// F3 wiring (default factory): com o banco abrindo, o store de cursores
    /// vivo é o DBOffsetStore e a ingest PERSISTE eventos — sem fábrica
    /// injetada, sem cursors.json novo, eventos consultáveis no SQLite.
    @Test("wiring F3: ingest do coordinator persiste no SQLite (store de cursores no settings)")
    func databaseWiringPersistsIngestedEvents() async throws {
        let fixture = try Fixture.make(fakeToken: "t7-synthetic-token-never-real")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Corpus Claude sintético (formato real do transcript).
        let session = fixture.root.appendingPathComponent("claude/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let line =
            "{\"type\":\"assistant\",\"timestamp\":\"\(Self.isoNow())\",\"message\":{\"model\":\"claude-sonnet-4-6\",\"usage\":{\"input_tokens\":33,\"output_tokens\":44}}}"
        try (line + "\n").write(to: session.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let support = fixture.root.appendingPathComponent("support")
        let coordinator = ProviderCoordinator(config: ProviderCoordinatorConfig(
            environment: fixture.environment,
            home: fixture.root,
            supportDirectory: support,
            e2eDirectory: fixture.e2eDirectory
        ))  // SEM makeOffsetStore: default F3 → DBOffsetStore

        await coordinator.refreshAllNow()

        // Banco criado na support directory com eventos persistidos.
        let db = try AppDatabase.open(at: support.appendingPathComponent(AppDatabase.databaseName))
        #expect(try db.usageEventCount(provider: .claude) == 1)
        let agg = try db.dailyAggRows(provider: .claude)
        #expect(agg.count == 1 && agg[0].inputTokens == 33 && agg[0].outputTokens == 44)

        // Cursores vivem no settings (não há JSON novo); marca d'água avançou
        // (o scan do ingester resolve symlinks: /var → /private/var).
        #expect(try db.setting(forKey: "cursors:claude") != nil)
        let transcript = session.appendingPathComponent("s1.jsonl").path
        #expect(try db.highWater(provider: .claude, path: resolvedPath(transcript)) != nil)

        // Segundo ciclo: nada novo no DB (cursor do settings evita re-ingest).
        await coordinator.refreshAllNow()
        let db2 = try AppDatabase.open(at: support.appendingPathComponent(AppDatabase.databaseName))
        #expect(try db2.usageEventCount(provider: .claude) == 1)
    }

    /// Red Team Task 1: DB que não abre (support dir é um ARQUIVO) → degrada
    /// para o comportamento F2 (JSON stores, sem persistência) — ciclos
    /// completam, heartbeat v2 sai com os 4 providers, sem crash.
    @Test("degradação sem DB: coordinator segue vivo com comportamento F2")
    func coordinatorDegradesWhenDatabaseUnavailable() async throws {
        let fixture = try Fixture.make(fakeToken: "t7-synthetic-token-never-real")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let session = fixture.root.appendingPathComponent("claude/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let line =
            "{\"type\":\"assistant\",\"timestamp\":\"\(Self.isoNow())\",\"message\":{\"model\":\"claude-sonnet-4-6\",\"usage\":{\"input_tokens\":5,\"output_tokens\":6}}}"
        try (line + "\n").write(to: session.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        // O support dir do fixture já existe (criado no setup) — apontamos o
        // coordinator para um ARQUIVO: AppDatabase.open falha (criar
        // <file>/x.sqlite é impossível) — o caminho de degradação.
        let blocker = fixture.root.appendingPathComponent("support-blocker")
        try Data("not a directory".utf8).write(to: blocker)

        let coordinator = ProviderCoordinator(config: ProviderCoordinatorConfig(
            environment: fixture.environment,
            home: fixture.root,
            supportDirectory: blocker,
            e2eDirectory: fixture.e2eDirectory
        ))

        await coordinator.refreshAllNow()

        let data = try Data(contentsOf: fixture.e2eDirectory.appendingPathComponent("state.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try #require(json["providers"] as? [String: Any])
        #expect(Set(providers.keys) == ["claude", "codex", "gemini", "zai"])

        // Sem DB, ingest local continua funcionando: display do dia correto
        // (ledger), apenas sem persistência.
        #expect((providers["claude"] as? [String: Any])?["todayTokens"] as? Int == 11)
        #expect(!FileManager.default.fileExists(atPath: blocker.appendingPathComponent("tokenbar.sqlite").path))
    }
}

/// Resolve o path como o `FileManager.enumerator` faz (realpath: /var →
/// /private/var) — as chaves de marca d'água/cursores usam o path da scan.
func resolvedPath(_ path: String) -> String {
    guard let r = realpath(path, nil) else { return path }
    defer { free(r) }
    return String(cString: r)
}
