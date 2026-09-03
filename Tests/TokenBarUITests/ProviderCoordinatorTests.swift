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
            supportDirectory: fixture.root.appendingPathComponent("support"),
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
}
