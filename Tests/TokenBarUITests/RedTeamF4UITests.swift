import Foundation
import Testing
import TokenBarCore
@testable import TokenBarUI

// ============================================================================
// Red Team F4 (Task 4) — Casos 2 (countdown adversarial), 4 (paths hostis no
// form + overlap programático) e 6 (higiene do heartbeat com 30 contas).
// ============================================================================
@MainActor
struct RedTeamF4UITests {
    let now = Date(timeIntervalSince1970: 1_788_048_000)

    // MARK: - Caso 2: countdown com resetsAt adversarial

    @Test("countdown: passado/epoch/distantPast → 'Renewed'/'renewed', NUNCA dígitos negativos")
    func pastResetsShowRenewed() {
        for past in [
            now.addingTimeInterval(-1),
            now.addingTimeInterval(-86_400 * 365),
            Date(timeIntervalSince1970: 0),
            .distantPast,
        ] {
            #expect(ProviderPanelModel.countdownText(from: now, to: past) == "renewed")
            #expect(ProviderPanelModel.renewText(from: now, to: past) == "Renewed")
        }
    }

    @Test("countdown: distanteFuture/anômalo → texto finito, sem crash")
    func anomalousResetsStayFinite() {
        let far = ProviderPanelModel.renewText(from: now, to: .distantFuture)
        #expect(far.hasPrefix("Renews in "), "distantFuture é finito em TimeInterval → texto normal")
        #expect(!far.contains("-"))
        // 1 segundo → mínimo 1m (nunca "0m").
        let soon = ProviderPanelModel.countdownText(from: now, to: now.addingTimeInterval(1))
        #expect(soon == "1m")
    }

    @Test("windowRows: resetsAt nil → countdown nil; fração fora de 0...1 satura; fração nil → sem barra/invenção")
    func windowRowsClampAdversarialInput() {
        let rows = ProviderPanelModel.windowRows(
            windows: [
                UsageWindow(kind: .weekly, usedFraction: 1.5, resetsAt: now.addingTimeInterval(3_600), label: "w"),
                UsageWindow(kind: .daily, usedFraction: -0.2, resetsAt: now.addingTimeInterval(-60), label: "d"),
                UsageWindow(kind: .session, usedFraction: nil, resetsAt: nil, label: "s"),
            ], now: now)
        #expect(rows[0].fraction == 1.0)
        #expect(rows[0].usageText == "Weekly 100% used")
        #expect(rows[0].countdownText == "Renews in 1h 0m")
        #expect(rows[1].fraction == 0.0)
        #expect(rows[1].countdownText == "Renewed")
        #expect(rows[2].fraction == nil)
        #expect(rows[2].usageText == "Session window")
        #expect(rows[2].countdownText == nil)
    }

    @Test("pacing/updated adversarial: exhaustedIn negativo/zero → 'should last'; fetchedAt no futuro → delta nunca negativo")
    func pacingAndUpdatedAdversarial() {
        let negative = PacingForecast(exhaustedIn: -120, projectedFraction: 0.5, deficitPct: nil)
        #expect(ProviderPanelModel.pacingText(negative, now: now) == "Estimated — should last until renew")
        #expect(ProviderPanelModel.pacingText(nil, now: now) == nil)

        let future = ProviderPanelModel.updatedText(now: now, fetchedAt: now.addingTimeInterval(600))
        #expect(future == "updated 1s ago", "delta clamped ≥ 0")
        let epoch = ProviderPanelModel.updatedText(now: now, fetchedAt: Date(timeIntervalSince1970: 0))
        #expect(epoch == "not updated yet")
    }

    // MARK: - Caso 4: paths hostis no form + Caso 5: overlap programático

    private func makeModel(_ root: URL) throws -> (AccountsModel, AppDatabase) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-f4-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try AppDatabase.open(at: dir.appendingPathComponent("db.sqlite"))
        let model = AccountsModel(
            registry: AccountRegistry(database: db),
            multiAccountProviders: [.claude, .codex, .zai],
            canonicalRoots: [.claude: root.path])
        return (model, db)
    }

    @Test("validate: /dev/null, FIFO e symlink quebrado avisam/aceitam sem crash — nada bloqueia indevidamente")
    func hostilePathsValidateWithoutCrash() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-f4-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("auth.fifo")
        mkfifo(fifo.path, 0o644)
        let dangling = root.appendingPathComponent("dangling.json")
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: root.appendingPathComponent("nope.json"))

        // /dev/null e FIFO existem → ADDABLE, mas com aviso honesto.
        for hostile in ["/dev/null", fifo.path] {
            let v = AddAccountForm.validate(label: "X", credentialPath: hostile, directoryPath: "")
            #expect(v.isAddable, "\(hostile) é addable (degrada com badge no ciclo)")
            #expect(!v.warnings.isEmpty, "\(hostile) gera warning de não-regular")
        }
        // Symlink quebrado → warning de inexistente (addable).
        let v2 = AddAccountForm.validate(label: "X", credentialPath: dangling.path, directoryPath: "")
        #expect(v2.isAddable && !v2.warnings.isEmpty)
    }

    @Test("AccountsModel.add: dir sobreposta BLOQUEIA também programaticamente (defesa além do form)")
    func programmaticOverlapIsBlocked() throws {
        let canonical = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-f4-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: canonical) }
        let (model, _) = try makeModel(canonical)
        let cred = canonical.appendingPathComponent("cred.json")
        try Data("{}".utf8).write(to: cred)

        // Subdiretório da canônica → overlap → throws (antes de tocar o registry).
        #expect(throws: AccountsModelError.directoryOverlaps) {
            _ = try model.add(
                provider: .claude, label: "Sneaky", credentialPath: cred.path,
                directoryPath: canonical.appendingPathComponent("child").path)
        }
        // A própria canônica → idem.
        #expect(throws: AccountsModelError.directoryOverlaps) {
            _ = try model.add(
                provider: .claude, label: "Sneaky 2", credentialPath: cred.path,
                directoryPath: canonical.path)
        }
        #expect(model.accounts(for: .claude).isEmpty, "nada foi registrado")

        // Disjoint legítimo → registra.
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-f4-other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        let ok = try model.add(
            provider: .claude, label: "Ok", credentialPath: cred.path, directoryPath: other.path)
        #expect(model.accounts(for: .claude).map(\.accountKey) == [ok.accountKey])
    }

    // MARK: - Caso 6: heartbeat com 30 contas — sem vazamento, payload razoável

    @Test("heartbeat com 30 contas hostis: labels/paths/ids de conta NÃO vazam no payload e o tamanho é limitado")
    func heartbeatWithThirtyAccountsLeaksNothing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-f4-hb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secretPath = root.appendingPathComponent("secret-cred.json")
        try Data("{}".utf8).write(to: secretPath)

        var accounts: [AccountDisplay] = [
            AccountDisplay(
                key: "local", label: "local", active: true, invalidCredential: false,
                display: ProviderDisplay(todayTokens: 1_000))
        ]
        for i in 1...30 {
            let hostile = "acct-\(i) \(secretPath.path) '; DROP TABLE accounts;--"
            accounts.append(AccountDisplay(
                key: hostile, label: hostile, active: true, invalidCredential: false,
                display: ProviderDisplay(todayTokens: Int64(i * 137))))
        }
        var display = ProviderDisplay(todayTokens: 1_000 + 30 * 137)
        display.accounts = accounts

        let payload = E2EHeartbeat.payload(menuBarText: "C:1.2k", providers: [.claude: display])
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)

        #expect(!text.contains("secret-cred"), "path de credencial NUNCA entra no heartbeat")
        #expect(!text.contains("DROP TABLE"), "conteúdo hostil de label não vaza")
        #expect(!text.contains("acct-"), "ids/labels por conta não fazem parte do payload v3")
        #expect(data.count < 8_192, "payload com 31 contas segue minúsculo: \(data.count)B")
    }
}
