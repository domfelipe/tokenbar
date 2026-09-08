import Darwin
import Foundation
import Testing
import TokenBarCore
@testable import TokenBarUI

/// F4 Task 3 — wiring multi-conta no coordinator: ciclo itera a conta
/// canônica + as registradas ativas; eventos/cursores/hwm POR CONTA; agregado
/// do provider = soma; conta com path inválido degrada sozinha (provider
/// segue de pé); toggle ativa tira a conta do ciclo. Fixtures sintéticas —
/// nenhuma credencial real em código/teste.
@MainActor
struct MultiAccountCoordinatorTests {
    /// Fixture com dois corpora Claude (conta local + conta "work" com dir
    /// própria) e um arquivo de credencial sintético para a conta registrada
    /// (o Claude local não o lê na F4 — existe para validar o path).
    private struct Fixture {
        let root: URL
        let localDir: URL
        let workDir: URL
        let workCredential: URL

        static func make() throws -> Fixture {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("multi-coord-\(UUID().uuidString)", isDirectory: true)
            let localDir = root.appendingPathComponent("claude", isDirectory: true)
            let workDir = root.appendingPathComponent("claude-work", isDirectory: true)
            let support = root.appendingPathComponent("support", isDirectory: true)
            let e2e = root.appendingPathComponent("e2e", isDirectory: true)
            for dir in [root, localDir, workDir, support, e2e] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let workCredential = root.appendingPathComponent("work-credential.json")
            try Data("{\"synthetic\": true}".utf8).write(to: workCredential)
            return Fixture(root: root, localDir: localDir, workDir: workDir, workCredential: workCredential)
        }

        func writeLine(_ tokens: String, to directory: URL, file: String = "s1.jsonl") throws {
            let project = directory.appendingPathComponent("proj", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let line =
                #"{"type":"assistant","timestamp":"\#(f.string(from: Date()))","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":\#(tokens),"output_tokens":0}}}"#
            let url = project.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                _ = try? handle.seekToEnd()
                try handle.write(contentsOf: Data((line + "\n").utf8))
                try handle.close()
            } else {
                try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func makeCoordinator(_ fixture: Fixture) -> ProviderCoordinator {
        ProviderCoordinator(config: ProviderCoordinatorConfig(
            environment: ["TOKENBAR_CLAUDE_DIR": fixture.localDir.path],
            home: fixture.root,
            supportDirectory: fixture.root.appendingPathComponent("support"),
            e2eDirectory: fixture.root.appendingPathComponent("e2e")
        ))
    }

    /// Registra a conta "work" (dir própria) no registry do coordinator.
    private func registerWork(_ coordinator: ProviderCoordinator, _ fixture: Fixture) throws -> RegisteredAccount {
        try #require(coordinator.accountRegistry).add(
            provider: .claude,
            label: "Work",
            credentialPath: fixture.workCredential.path,
            directoryPath: fixture.workDir.path)
    }

    @Test("ciclo com 2 contas: eventos, cursores e hwm por conta; agregado soma")
    func cycleWithTwoAccountsProducesPerAccountState() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeLine("33", to: fixture.localDir)   // local: 33
        try fixture.writeLine("10", to: fixture.workDir)    // work: 10

        let coordinator = makeCoordinator(fixture)
        #expect(coordinator.supportsMultiAccount(.claude))
        #expect(!coordinator.supportsMultiAccount(.gemini), "gemini sem suporte → botão oculto")
        let work = try registerWork(coordinator, fixture)

        await coordinator.refreshAllNow()

        // Agregado = soma das contas (33 + 10) e as duas linhas no display.
        let display = try #require(coordinator.store.providers[.claude])
        #expect(display.todayTokens == 43)
        #expect(display.accounts.count == 2)
        #expect(display.accounts.map(\.label).sorted() == ["Work", "local"])
        #expect(display.accounts.contains { $0.key == work.accountKey && $0.label == "Work" && $0.active })

        // DB: eventos e daily_agg POR CONTA.
        let db = try #require(coordinator.historyDatabase)
        let accounts = Set(try db.dailyAggRows(provider: .claude).map(\.account))
        #expect(accounts == ["local", work.accountKey])

        // Cursor POR CONTA: canônica na chave legada (F2), registrada no
        // namespace próprio — e a registrada NÃO toca a legada.
        #expect(try db.setting(forKey: "cursors:claude") != nil)
        #expect(try db.setting(forKey: "cursors:claude:\(work.accountKey)") != nil)

        // HWM POR CONTA: namespaces disjuntos (paths diferentes, chaves diferentes).
        let localPath = resolvedPath(try #require(
            fixture.localDir.appendingPathComponent("proj/s1.jsonl").path))
        let workPath = resolvedPath(try #require(
            fixture.workDir.appendingPathComponent("proj/s1.jsonl").path))
        #expect(try db.highWater(provider: .claude, path: localPath) != nil)
        #expect(try db.highWater(provider: .claude, path: workPath, accountKey: work.accountKey) != nil)
    }

    @Test("cursores por conta: crescer o corpus da conta registrada não re-inge a local")
    func cursorIsolationBetweenAccounts() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeLine("33", to: fixture.localDir)
        try fixture.writeLine("10", to: fixture.workDir)

        let coordinator = makeCoordinator(fixture)
        let work = try registerWork(coordinator, fixture)
        await coordinator.refreshAllNow()
        #expect(coordinator.store.providers[.claude]?.todayTokens == 43)

        // Só o corpus da conta work cresce.
        try fixture.writeLine("7", to: fixture.workDir)
        await coordinator.refreshAllNow()

        let display = try #require(coordinator.store.providers[.claude])
        #expect(display.todayTokens == 50, "33 local + 17 work — sem re-ingest da local")
        let workDisplay = try #require(display.accounts.first { $0.key == work.accountKey })
        #expect(workDisplay.display.todayTokens == 17)
        let localDisplay = try #require(display.accounts.first { $0.key == "local" })
        #expect(localDisplay.display.todayTokens == 33)

        // Nada duplicado no DB (2 grupos por conta, soma consistente).
        let db = try #require(coordinator.historyDatabase)
        let rows = try db.dailyAggRows(provider: .claude)
        #expect(rows.count == 2)
        #expect(rows.reduce(Int64(0)) { $0 + $1.inputTokens } == 50)
    }

    @Test("conta com path inválido degrada sozinha: badge na linha, provider de pé")
    func invalidAccountDegradesAlone() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeLine("33", to: fixture.localDir)

        let coordinator = makeCoordinator(fixture)
        let registry = try #require(coordinator.accountRegistry)
        let bad = try registry.add(
            provider: .claude,
            label: "Broken",
            credentialPath: fixture.root.appendingPathComponent("missing-cred.json").path)

        await coordinator.refreshAllNow()

        let display = try #require(coordinator.store.providers[.claude])
        // Provider de pé: dado da conta canônica intacto, erro NENHUM no nível
        // do provider (a conta degradou sozinha).
        #expect(display.todayTokens == 33)
        #expect(display.accounts.contains { $0.key == "local" && !$0.invalidCredential })

        let broken = try #require(display.accounts.first { $0.key == bad.accountKey })
        #expect(broken.invalidCredential, "badge de erro na linha da conta")
        #expect(broken.display.todayTokens == 0, "nada inventado para a conta inválida")

        let diagnostic = coordinator.diagnosticPayload()
        let providers = try #require(diagnostic["providers"] as? [String: Any])
        let claudeEntry = try #require(providers["claude"] as? [String: Any])
        #expect(claudeEntry["error"] == nil, "erro de conta registrada não vira erro do provider")
    }

    @Test("toggle ativa: conta inativa sai do ciclo e do agregado; reativa volta")
    func inactiveAccountLeavesCycle() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeLine("33", to: fixture.localDir)
        try fixture.writeLine("10", to: fixture.workDir)

        let coordinator = makeCoordinator(fixture)
        let work = try registerWork(coordinator, fixture)
        await coordinator.refreshAllNow()
        #expect(coordinator.store.providers[.claude]?.todayTokens == 43)

        let registry = try #require(coordinator.accountRegistry)
        try registry.setActive(false, provider: .claude, accountKey: work.accountKey)
        await coordinator.refreshAllNow()

        let display = try #require(coordinator.store.providers[.claude])
        #expect(display.todayTokens == 33, "só a conta canônica cicliza")
        #expect(display.accounts.map(\.key) == ["local"])

        try registry.setActive(true, provider: .claude, accountKey: work.accountKey)
        try fixture.writeLine("5", to: fixture.workDir)
        await coordinator.refreshAllNow()
        #expect(coordinator.store.providers[.claude]?.todayTokens == 48, "reativação retoma a conta")
    }

    // MARK: - Agregado puro

    private func accountDisplay(
        key: String, label: String, windows: [UsageWindow], tokens: Int64,
        authState: AuthState = .ok
    ) -> AccountDisplay {
        AccountDisplay(
            key: key, label: label, active: true, invalidCredential: false,
            display: ProviderDisplay(
                percent: criticalWindow(in: windows)?.usedFraction.map { $0 * 100 },
                todayTokens: tokens,
                authState: authState,
                source: .api,
                windows: windows))
    }

    @Test("agregado: janela da conta de maior fração vence; tokens somados")
    func aggregatePicksHighestFractionAccount() {
        let primary = accountDisplay(
            key: "local", label: "local",
            windows: [UsageWindow(kind: .daily, usedFraction: 0.2, resetsAt: nil, label: "Hoje")],
            tokens: 100)
        let work = accountDisplay(
            key: "acct-w", label: "Work",
            windows: [UsageWindow(kind: .session, usedFraction: 0.9, resetsAt: nil, label: "5h")],
            tokens: 50)

        let aggregate = ProviderCoordinator.aggregateAccountsDisplay(
            [primary, work], base: ProviderDisplay.empty)

        #expect(aggregate.todayTokens == 150)
        #expect(aggregate.percent == 90, "conta crítica (maior fração) alimenta o percent")
        #expect(aggregate.windows == work.display.windows)
        #expect(aggregate.accounts.count == 2)

        // Empate: a primeira (canônica) vence.
        let tied = accountDisplay(
            key: "acct-t", label: "Tied",
            windows: [UsageWindow(kind: .daily, usedFraction: 0.2, resetsAt: nil, label: "Hoje")],
            tokens: 10)
        let tiedAggregate = ProviderCoordinator.aggregateAccountsDisplay(
            [primary, tied], base: ProviderDisplay.empty)
        #expect(tiedAggregate.percent == 20)
        #expect(tiedAggregate.windows == primary.display.windows)

        // Sem fração conhecida (modo local): primeira conta, comportamento F2.
        let localOnly = accountDisplay(
            key: "local", label: "local", windows: [], tokens: 5)
        let localAggregate = ProviderCoordinator.aggregateAccountsDisplay(
            [localOnly], base: ProviderDisplay.empty)
        #expect(localAggregate.percent == nil)
        #expect(localAggregate.todayTokens == 5)

        // Sem contas: base intacta (defensivo — o ciclo sempre tem a canônica).
        let empty = ProviderCoordinator.aggregateAccountsDisplay([], base: primary.display)
        #expect(empty == primary.display)
    }
}
