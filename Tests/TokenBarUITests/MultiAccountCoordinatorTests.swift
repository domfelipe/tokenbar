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

        /// `count` dirs de frota sob o root (cada uma com exatamente 137
        /// tokens hoje: 100 in + 37 out, modelo precificado) — Red Team caso 3.
        func makeFleetDirs(count: Int) throws -> [URL] {
            var dirs: [URL] = []
            for index in 0..<count {
                let dir = root.appendingPathComponent("fleet-\(index)", isDirectory: true)
                try writeLine("100", to: dir, file: "f-\(index).jsonl")
                try writeLine("37", to: dir, file: "f-\(index)-b.jsonl")
                dirs.append(dir)
            }
            return dirs
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

    @Test("toggle ativa pela VIEW-MODEL: conta inativa sai do ciclo e do agregado; reativa volta")
    func inactiveAccountLeavesCycle() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeLine("33", to: fixture.localDir)
        try fixture.writeLine("10", to: fixture.workDir)

        let coordinator = makeCoordinator(fixture)
        let work = try registerWork(coordinator, fixture)
        await coordinator.refreshAllNow()
        #expect(coordinator.store.providers[.claude]?.todayTokens == 43)

        // Caminho da UI (fix review final F4): o toggle da linha passa pelo
        // AccountsModel — nunca pelo registry direto. O app conecta o refresh
        // do ciclo no `onMutation` (AppState); o teste refresca explícito.
        let model = AccountsModel(
            registry: try #require(coordinator.accountRegistry),
            multiAccountProviders: [.claude])
        var mutations = 0
        model.onMutation = { mutations += 1 }

        model.setActive(false, account: work)
        #expect(mutations == 1, "toggle passou pelo model (onMutation dispara o refresh)")
        await coordinator.refreshAllNow()

        let display = try #require(coordinator.store.providers[.claude])
        #expect(display.todayTokens == 33, "só a conta canônica cicliza")
        #expect(display.accounts.map(\.key) == ["local"])

        model.setActive(true, account: work)
        try fixture.writeLine("5", to: fixture.workDir)
        await coordinator.refreshAllNow()
        #expect(coordinator.store.providers[.claude]?.todayTokens == 48, "reativação retoma a conta")
    }

    /// Fix do review final F4 (BLOQUEANTE): a seção de contas montada só com
    /// `display.accounts` (só ATIVAS) fazia a linha da conta desativada sumir
    /// — toggle de reativação e "Remove account" desapareciam JUNTOS, e o
    /// re-add era bloqueado pelo guard de overlap: conta presa no banco. Pin:
    /// toggle-off → linha permanece (badge "inactive", display vazio) com o
    /// registro ancorando toggle/remove; reativar → volta ao ciclo.
    @Test("painel união registry ⊕ ciclo: toggle-off mantém a linha (inactive) e remove alcançável; reativar volta")
    func inactiveRowStaysVisibleAndManageable() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeLine("33", to: fixture.localDir)
        try fixture.writeLine("10", to: fixture.workDir)

        let coordinator = makeCoordinator(fixture)
        let work = try registerWork(coordinator, fixture)
        let model = AccountsModel(
            registry: try #require(coordinator.accountRegistry),
            multiAccountProviders: [.claude])
        await coordinator.refreshAllNow()

        // As linhas que `accountsSection` renderiza (união do view-model).
        func rows() -> [AccountDisplay] {
            ProviderPanelModel.accountRows(
                cycled: coordinator.store.providers[.claude]?.accounts ?? [],
                registered: model.accounts(for: .claude))
        }
        #expect(rows().count == 2, "antes do toggle: as duas contas, ativas")
        #expect(ProviderPanelModel.showsAccountsSection(
            rows: rows(), registeredCount: model.accounts(for: .claude).count))

        model.setActive(false, account: work)
        await coordinator.refreshAllNow()

        // O ciclo deixa de trazer a conta, mas a LINHA permanece pela união.
        #expect(coordinator.store.providers[.claude]?.accounts.map(\.key) == ["local"],
                "ciclo: conta inativa sai")
        let unionRows = rows()
        #expect(unionRows.count == 2, "painel: a linha da inativa NÃO some")
        let inactiveRow = unionRows.first { $0.key == work.accountKey }
        #expect(inactiveRow?.active == false, "badge 'inactive' na linha")
        #expect(inactiveRow?.display == .empty, "nada inventado p/ conta fora do ciclo")
        #expect(inactiveRow?.label == "Work")
        #expect(ProviderPanelModel.showsAccountsSection(
            rows: unionRows, registeredCount: model.accounts(for: .claude).count),
            "seção segue visível: toggle de reativação acessível")
        #expect(model.accounts(for: .claude).contains { $0.accountKey == work.accountKey },
                "registro ancora toggle (reativar) e Remove na linha")

        // Remove alcançável na linha inativa: sai da união, volta ao layout F2.
        model.remove(work)
        await coordinator.refreshAllNow()
        #expect(model.accounts(for: .claude).isEmpty)
        #expect(rows().map(\.key) == ["local"])
        #expect(coordinator.store.providers[.claude]?.todayTokens == 33)
    }

    // MARK: - União registry ⊕ ciclo (painel — fix review final, pura)

    @Test("união registry ⊕ ciclo: sem duplicata; inativa vira linha com badge; regra de visibilidade da seção")
    func accountRowsUnionSemantics() {
        let local = AccountDisplay(
            key: "local", label: "local", active: true, invalidCredential: false,
            display: ProviderDisplay(todayTokens: 33))
        let workCycled = AccountDisplay(
            key: "acct-w", label: "Work", active: true, invalidCredential: false,
            display: ProviderDisplay(todayTokens: 10))
        let workInactive = RegisteredAccount(
            provider: .claude, accountKey: "acct-w", label: "Work", kind: "oauth",
            active: false, credentialPath: "/tmp/work.json", directoryPath: "")

        // Conta presente nos DOIS lados → união não duplica (resolvida pelo
        // ciclo; comportamento anterior preservado bit-a-bit).
        let allCycled = ProviderPanelModel.accountRows(
            cycled: [local, workCycled], registered: [workInactive])
        #expect(allCycled == [local, workCycled])

        // Fora do ciclo (inativa) → linha persiste com o estado do registro.
        let union = ProviderPanelModel.accountRows(cycled: [local], registered: [workInactive])
        #expect(union.count == 2)
        #expect(union[0] == local, "cicladas intactas, ordem preservada")
        #expect(union[1].key == "acct-w")
        #expect(!union[1].active, "badge 'inactive'")
        #expect(union[1].display == .empty, "nada inventado p/ conta fora do ciclo")
        #expect(union[1].label == "Work")

        // Visibilidade: >1 linha mostra; conta única ATIVA é ruído (decisão
        // F4-MULTIACCOUNT); única conta INATIVA segue alcançável.
        #expect(ProviderPanelModel.showsAccountsSection(rows: union, registeredCount: 1))
        #expect(!ProviderPanelModel.showsAccountsSection(rows: [local], registeredCount: 0))
        #expect(ProviderPanelModel.showsAccountsSection(rows: [local], registeredCount: 1))
    }

    /// Red Team F4 caso 3 (porção automatizável): 30 contas registradas no
    /// MESMO provider — UM ciclo cobre todas (31 alvos), soma exata, estado
    /// por conta no DB e remoção em lote devolve o display ao F2. A porção de
    /// sistema (tempo/memória/UI com o app real) é do E2E §10 e do QA.
    @Test("frota de 30 contas: um ciclo cobre todas com soma exata; remoção em lote poda")
    func thirtyAccountsAllCycleInOnePass() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeLine("33", to: fixture.localDir)  // canônica: 33
        let fleet = try fixture.makeFleetDirs(count: 30)   // 137 tokens cada
        let credential = fixture.workCredential.path

        let coordinator = makeCoordinator(fixture)
        let registry = try #require(coordinator.accountRegistry)
        for (index, dir) in fleet.enumerated() {
            _ = try registry.add(
                provider: .claude, label: "Fleet \(index)", credentialPath: credential,
                directoryPath: dir.path)
        }
        #expect(try registry.activeAccounts(provider: .claude).count == 30)

        await coordinator.refreshAllNow()

        // 33 + 30×137 = 4143 — um ciclo só, sem duplicação nem conta faltando.
        let display = try #require(coordinator.store.providers[.claude])
        #expect(display.todayTokens == 33 + 30 * 137)
        #expect(display.accounts.count == 31)
        #expect(display.accounts.filter { $0.display.todayTokens == 137 }.count == 30)

        let db = try #require(coordinator.historyDatabase)
        #expect(
            Set(try db.dailyAggRows(provider: .claude).map(\.account)).count == 31,
            "31 namespaces de conta no DB (canônica + frota)")

        // Remoção no-op é idempotente; remoção em LOTE devolve o display ao F2.
        try registry.remove(provider: .claude, accountKey: "acct-inexistente")
        for account in try registry.accounts(provider: .claude) {
            try registry.remove(provider: .claude, accountKey: account.accountKey)
        }
        await coordinator.refreshAllNow()
        #expect(coordinator.store.providers[.claude]?.todayTokens == 33)
        #expect(coordinator.store.providers[.claude]?.accounts.map(\.key) == ["local"])
    }

    /// Red Team F4 caso 5 (residual documentado, decisão 7 de decisoes-f4):
    /// registro programático BYPASSANDO o form/AccountsModel — o registry puro
    /// NÃO bloqueia dirs sobrepostas (não conhece raízes canônicas) e o mesmo
    /// corpus passa a contar 2× no agregado E no DB. Sem crash, cursor/hwm por
    /// conta não colidem (namespaces disjuntos) — a dobragem é o comportamento
    /// registrado; nenhum caminho de usuário alcança (form + AccountsModel
    /// bloqueiam; E2E §10 usa exatamente este caminho para o setup).
    @Test("overlap programático (bypass do form): dobragem documentada, sem crash")
    func programmaticOverlapDoublesDocumented() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeLine("33", to: fixture.localDir)
        try fixture.writeLine("10", to: fixture.workDir)

        let coordinator = makeCoordinator(fixture)
        let registry = try #require(coordinator.accountRegistry)
        let credential = fixture.workCredential.path
        // Duas contas, MESMA dir (o form teria bloqueado a 2ª).
        _ = try registry.add(
            provider: .claude, label: "A", credentialPath: credential,
            directoryPath: fixture.workDir.path)
        _ = try registry.add(
            provider: .claude, label: "B", credentialPath: credential,
            directoryPath: fixture.workDir.path)

        await coordinator.refreshAllNow()

        let display = try #require(coordinator.store.providers[.claude])
        #expect(display.todayTokens == 33 + 10 + 10, "dobragagem: o corpus da dir conta por conta (33+10+10)")
        #expect(display.accounts.count == 3)
        // Sem colisão de namespaces: cada conta tem seu próprio cursor/hwm —
        // o dado NÃO dobra dentro de uma mesma conta em ciclos seguintes.
        await coordinator.refreshAllNow()
        #expect(coordinator.store.providers[.claude]?.todayTokens == 53, "2º ciclo não re-dobra (hwm por conta)")
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
