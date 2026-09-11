import Darwin
import Foundation
import Testing
import TokenBarCore
@testable import TokenBarUI

/// Red Team F5 (Task 7) — UI/ciclo: bypass programático residual do guard de
/// overlap (registro direto no banco por baixo do form), higiene do gateway de
/// captura de alertas do e2e e do heartbeat aditivo (credits/alertsStatus).
///
/// F4 documentou a dobragem por overlap programático como residual (decisão 7
/// de `docs/decisoes-f4.md`) — F5 FECHA o caso contra a raiz canônica: o CICLO
/// defende (conta sobreposta não ingere; o canônico já cobre aqueles arquivos).
@MainActor
struct RedTeamF5UITests {
    // MARK: - overlapsCanonical (puro)

    @Test("overlapsCanonical: igual, descendente e ancestral sobrepõem; irmão e fronteira de componente não")
    func overlapsCanonicalMatrix() {
        let canonical = URL(fileURLWithPath: "/Users/fake/.claude/projects", isDirectory: true)
        // Igual → sobrepõe.
        #expect(ProviderCoordinator.overlapsCanonical(
            accountDirectory: "/Users/fake/.claude/projects", canonicalRoot: canonical))
        // Descendente (conta DENTRO da raiz canônica) → sobrepõe.
        #expect(ProviderCoordinator.overlapsCanonical(
            accountDirectory: "/Users/fake/.claude/projects/acme", canonicalRoot: canonical))
        // Ancestral (raiz canônica DENTRO da dir da conta) → sobrepõe.
        #expect(ProviderCoordinator.overlapsCanonical(
            accountDirectory: "/Users/fake/.claude", canonicalRoot: canonical))
        // Irmão → NÃO sobrepõe (conta legítima fora da raiz canônica).
        #expect(!ProviderCoordinator.overlapsCanonical(
            accountDirectory: "/Users/fake/claude-work", canonicalRoot: canonical))
        // Fronteira de componente: "/…projects-x" NÃO é dentro de "/…projects".
        #expect(!ProviderCoordinator.overlapsCanonical(
            accountDirectory: "/Users/fake/.claude/projects-x/acme", canonicalRoot: canonical))
        // Dir vazia / raiz ausente → false (nada a proteger/conflitar).
        #expect(!ProviderCoordinator.overlapsCanonical(accountDirectory: "", canonicalRoot: canonical))
        #expect(!ProviderCoordinator.overlapsCanonical(
            accountDirectory: "/tmp/qualquer", canonicalRoot: nil))
        // Trailing slash e path não-padronizado caem no mesmo lugar.
        #expect(ProviderCoordinator.overlapsCanonical(
            accountDirectory: "/Users/fake/.claude/projects/", canonicalRoot: canonical))
    }

    // MARK: - Bypass programático no CICLO (fechamento do residual F4)

    private struct Fixture {
        let root: URL
        let canonicalDir: URL  // TOKENBAR_CLAUDE_DIR = raiz canônica do claude
        let credential: URL

        static func make() throws -> Fixture {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("rt5-bypass-\(UUID().uuidString)", isDirectory: true)
            let canonicalDir = root.appendingPathComponent("claude-projects", isDirectory: true)
            let support = root.appendingPathComponent("support", isDirectory: true)
            let e2e = root.appendingPathComponent("e2e", isDirectory: true)
            for dir in [root, canonicalDir, support, e2e] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let credential = root.appendingPathComponent("fake-credential.json")
            try Data("{\"synthetic\": true}".utf8).write(to: credential)
            return Fixture(root: root, canonicalDir: canonicalDir, credential: credential)
        }

        func writeLine(_ tokens: String, to directory: URL, file: String) throws {
            let project = directory.appendingPathComponent("proj", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let line =
                #"{"type":"assistant","timestamp":"\#(f.string(from: Date()))","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":\#(tokens),"output_tokens":0}}}"#
            try (line + "\n").write(to: project.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    private func makeCoordinator(_ fixture: Fixture) -> ProviderCoordinator {
        ProviderCoordinator(config: ProviderCoordinatorConfig(
            environment: ["TOKENBAR_CLAUDE_DIR": fixture.canonicalDir.path],
            home: fixture.root,
            supportDirectory: fixture.root.appendingPathComponent("support"),
            e2eDirectory: fixture.root.appendingPathComponent("e2e")
        ))
    }

    @Test("bypass programático (INSERT direto com dir == raiz canônica): ciclo NÃO dobra — conta sobreposta não ingere e continua visível p/ remoção")
    func cycleDefendsAgainstProgrammaticCanonicalOverlap() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeLine("33", to: fixture.canonicalDir, file: "canon.jsonl")

        let coordinator = makeCoordinator(fixture)
        let registry = try #require(coordinator.accountRegistry)
        // INSERT direto (o form/AccountsModel bloquearia): dir da conta IGUAL à
        // raiz canônica — exatamente o caso em que o F4 dobrava.
        // O MESMO caminho do Red Team F4 caso 5 (registry direto, sem form):
        // nem o registry nem o form conhece a raiz canônica como restrição de
        // dir IGUAL — a defesa fica no ciclo.
        _ = try registry.add(
            provider: .claude, label: "Evil Overlap",
            credentialPath: fixture.credential.path,
            directoryPath: fixture.canonicalDir.path)

        await coordinator.refreshAllNow()

        let display = try #require(coordinator.store.providers[.claude])
        #expect(display.todayTokens == 33, "o corpus canônico conta 1× — a conta sobreposta NÃO ingere")
        #expect(display.accounts.count == 1, "só a canônica ciclada")
        #expect(display.accounts[0].key == "local")

        // A conta segue gerenciável: registry mantém a linha (remoção via UI).
        let registered = try registry.accounts(provider: .claude)
        #expect(registered.count == 1)
        #expect(registered[0].label == "Evil Overlap")
        #expect(registered[0].directoryPath == fixture.canonicalDir.path)

        // Segundo ciclo: estável (não re-dobra, não ingera tardiamente).
        await coordinator.refreshAllNow()
        #expect(coordinator.store.providers[.claude]?.todayTokens == 33)

        // Sibling legítimo continua ciclando normalmente (o guard não pinta
        // todo mundo com o mesmo pincel).
        let sibling = fixture.root.appendingPathComponent("claude-sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try fixture.writeLine("10", to: sibling, file: "sib.jsonl")
        let entry = try registry.add(
            provider: .claude, label: "Sibling", credentialPath: fixture.credential.path,
            directoryPath: sibling.path)
        await coordinator.refreshAllNow()
        #expect(coordinator.store.providers[.claude]?.todayTokens == 43,
                "conta legítima (fora da canônica) soma: 33 + 10")
        #expect(entry.active)
    }
}

/// Gateway de captura do e2e: autorização simulada, linhas JSON com o MESMO
/// identificador/render do gateway real (dedupe por identifier é o que colapsa
/// banners repetidos), nunca toca no UNUserNotificationCenter.
struct RedTeamF5CaptureGatewayTests {
    @Test("E2EAlertCaptureGateway: deliver grava JSONL com identifier/render reais; mesma causa → mesmo identifier")
    func captureWritesStableIdentifiers() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt5-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let gateway = E2EAlertCaptureGateway(fileURL: dir.appendingPathComponent("alerts.jsonl"))
        #expect(await gateway.requestAuthorization() == true)
        #expect(await gateway.authorizationState() == .granted)

        let account = AccountID(provider: .zai, key: "local")
        let firedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let resetsAt = firedAt.addingTimeInterval(2 * 3_600 + 15 * 60)
        func event(_ threshold: Int) -> AlertEvent {
            AlertEvent(
                kind: .threshold, provider: .zai, account: account, windowKind: .session,
                thresholdPct: threshold, usedFraction: 0.96, resetsAt: resetsAt, firedAt: firedAt)
        }
        await gateway.deliver(event(95))
        await gateway.deliver(event(95))  // mesma causa → identifier idêntico
        await gateway.deliver(event(90))  // causa distinta → identifier distinto

        let raw = try String(contentsOf: dir.appendingPathComponent("alerts.jsonl"), encoding: .utf8)
        let lines = raw.split(separator: "\n")
        #expect(lines.count == 3)
        let decoded = try lines.map { line -> [String: Any] in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let ids = decoded.map { $0["identifier"] as? String ?? "" }
        #expect(ids[0] == ids[1], "dedupe de banner: mesma chave (provider, conta, janela, causa)")
        #expect(ids[0] == "tokenbar.alert.zai.local.session.t95")
        #expect(ids[2] == "tokenbar.alert.zai.local.session.t90")
        #expect(decoded[0]["title"] as? String == "Z.ai · 95% of session window used")
        #expect(decoded[0]["body"] as? String == "Resets in 2h 15m")

        // Evento sem resetsAt → "Reset time unknown" (nada inventado).
        let noReset = AlertEvent(
            kind: .threshold, provider: .claude, account: account, windowKind: .weekly,
            thresholdPct: 50, usedFraction: 0.6, resetsAt: nil, firedAt: firedAt)
        await gateway.deliver(noReset)
        let raw2 = try String(contentsOf: dir.appendingPathComponent("alerts.jsonl"), encoding: .utf8)
        #expect(raw2.contains("Reset time unknown"))
    }

    @Test("heartbeat: credits presente só com dado real; alertsStatus top-level")
    func heartbeatCreditsAndAlertsStatus() throws {
        var display = ProviderDisplay(percent: 42, todayTokens: 7)
        display.credits = CreditsInfo(remaining: 62.8, unlimited: false)
        var payload = E2EHeartbeat.payload(menuBarText: "TB", providers: [.openrouter: display], alertsStatus: .enabled)
                let providersPayload = try #require(payload["providers"] as? [String: Any])
        var openrouter = try #require(providersPayload.values.first as? [String: Any])
        var credits = try #require(openrouter["credits"] as? [String: Any])
        #expect(credits["remaining"] as? Double == 62.8)
        #expect(credits["unlimited"] as? Bool == false)
        #expect(payload["alertsStatus"] as? String == "enabled")

        // Sem credits → chave ausente (nada fake); status nil → campo ausente.
        display.credits = nil
        payload = E2EHeartbeat.payload(menuBarText: "TB", providers: [.openrouter: display])
        openrouter = try #require((payload["providers"] as? [String: Any])?.values.first as? [String: Any])
        #expect(openrouter["credits"] == nil)
        #expect(payload["alertsStatus"] == nil)

        // Unlimited → remaining null EXPLÍCITO.
        display.credits = CreditsInfo(remaining: nil, unlimited: true)
        payload = E2EHeartbeat.payload(menuBarText: "TB", providers: [.openrouter: display])
        openrouter = try #require((payload["providers"] as? [String: Any])?.values.first as? [String: Any])
        credits = try #require(openrouter["credits"] as? [String: Any])
        #expect(credits["remaining"] is NSNull)
        #expect(credits["unlimited"] as? Bool == true)
    }
}
