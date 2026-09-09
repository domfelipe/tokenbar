import Foundation
import Testing
import TokenBarCore
@testable import TokenBarProviders

// MARK: - URLProtocol stub (mesmo padrão de HTTPClientTests, módulo próprio)

/// Fixtures 100% sintéticas (`fake-token`, hosts `.example.com`) — spec F2 §5.
final class CodexStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Exchange {
        var status: Int = 500
        var body: Data = Data()
        var error: URLError?
    }

    private final class StubState: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (URLRequest) -> Exchange)?
        var lastRequest: URLRequest?
    }

    private static let state = StubState()

    static var lastRequest: URLRequest? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.lastRequest
    }

    static func configure(_ handler: (@Sendable (URLRequest) -> Exchange)?) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.handler = handler
        state.lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.lock.lock()
        Self.state.lastRequest = request
        let handler = Self.state.handler
        Self.state.lock.unlock()

        let exchange = handler?(request) ?? Exchange(error: URLError(.unsupportedURL))
        if let error = exchange.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let url = request.url ?? URL(string: "https://stub.invalid")!
        let response = HTTPURLResponse(
            url: url, statusCode: exchange.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )
        client?.urlProtocol(self, didReceive: response!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: exchange.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Helpers compartilhados

enum CodexFixtures {
    static let codexAccount = AccountID(provider: .codex, key: "local")
    static let localRef = AccountRef(id: AccountID(provider: .codex, key: "local"), label: "local")
    static let now = Date(timeIntervalSince1970: 1_788_000_000)  // mesmo fixo dos testes F1

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// auth.json sintético (shape da spec §1.2, valores fake).
    static func authJSON(
        authMode: String = "chatgpt",
        apiKey: String? = nil,
        accessToken: String? = "fake-token",
        accountID: String? = "fake-account-id",
        idToken: String? = "fake-jwt"
    ) -> String {
        let tokens: String
        if accessToken == nil && idToken == nil && accountID == nil {
            tokens = "null"
        } else {
            let parts = [
                accessToken.map { #""access_token":"\#($0)""# },
                accountID.map { #""account_id":"\#($0)""# },
                idToken.map { #""id_token":"\#($0)""# },
            ].compactMap { $0 }
            tokens = "{\(parts.joined(separator: ","))}"
        }
        let keyPart = apiKey.map { "\"OPENAI_API_KEY\":\"\($0)\"," } ?? "\"OPENAI_API_KEY\":null,"
        return """
        {\(keyPart)"auth_mode":"\(authMode)","last_refresh":"2026-09-02T10:00:00.000Z","tokens":\(tokens)}
        """
    }

    /// Linhas de um rollout sintético conforme spec §1.5: session_meta,
    /// turn_context (model muda no meio), 2× token_count (deltas last 260→117;
    /// total_token_usage cumulativo presente p/ pinar F2-CODEX-DELTA), e uma
    /// response_item sem uso. rate_limits inclui TODAS as chaves extras
    /// observadas (credits, individual_limit, limit_id, limit_name,
    /// rate_limit_reached_type, spend_control_reached).
    static func rolloutLines(ts1: Date, ts2: Date) -> [String] {
        let i1 = iso(ts1), i2 = iso(ts2)
        return [
            #"{"timestamp":"\#(i1)","type":"session_meta","payload":{"id":"fake-session","timestamp":"\#(i1)","cli_version":"0.0.0","cwd":"/tmp/fake-proj","originator":"codex","context_window":272000}}"#,
            #"{"timestamp":"\#(i1)","type":"turn_context","payload":{"model":"gpt-5.2","cwd":"/tmp/fake-proj"}}"#,
            #"{"timestamp":"\#(i1)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"cache_write_input_tokens":10,"output_tokens":110,"reasoning_output_tokens":64,"total_tokens":260},"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"cache_write_input_tokens":10,"output_tokens":110,"reasoning_output_tokens":64,"total_tokens":260},"model_context_window":272000},"rate_limits":{"plan_type":"plus","primary":{"used_percent":42,"resets_at":1800000000,"window_minutes":300},"secondary":{"used_percent":7,"resets_at":1800086400,"window_minutes":10080},"credits":null,"individual_limit":null,"limit_id":null,"limit_name":null,"rate_limit_reached_type":null,"spend_control_reached":null}}}"#,
            #"{"timestamp":"\#(i2)","type":"turn_context","payload":{"model":"gpt-5.3","cwd":"/tmp/fake-proj"}}"#,
            #"{"timestamp":"\#(i2)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":5,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":112,"reasoning_output_tokens":30,"total_tokens":117},"total_token_usage":{"input_tokens":105,"cached_input_tokens":40,"cache_write_input_tokens":10,"output_tokens":222,"reasoning_output_tokens":94,"total_tokens":377},"model_context_window":272000},"rate_limits":{"plan_type":"plus","primary":{"used_percent":43,"resets_at":1800000000,"window_minutes":300},"secondary":{"used_percent":7,"resets_at":1800086400,"window_minutes":10080},"credits":null,"individual_limit":"fake-limit","limit_id":"fake-limit","limit_name":"gpt-5.3","rate_limit_reached_type":"none","spend_control_reached":false}}}"#,
            #"{"timestamp":"\#(i2)","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"fake response"}]}}"#,
        ]
    }

    /// Resposta wham/usage sintética (shape anotado da spec §1.3, com extras).
    static let whamUsageBody = """
    {
      "account_id": "fake-account-id",
      "plan_type": "plus",
      "rate_limit": {
        "primary_window":   { "used_percent": 42, "reset_at": 1800000000, "limit_window_seconds": 18000 },
        "secondary_window": { "used_percent": 7,  "reset_at": 1800086400, "limit_window_seconds": 604800 },
        "individual_limit": null
      },
      "credits": { "has_credits": false, "unlimited": false, "balance": null },
      "additional_rate_limits": [
        {
          "limit_name": "gpt-5.3-codex-spark",
          "metered_feature": null,
          "rate_limit": {
            "primary_window": { "used_percent": 3, "reset_at": 1800000000, "limit_window_seconds": 18000 },
            "secondary_window": null
          }
        }
      ],
      "individual_limit": null,
      "spend_control": {
        "individual_limit": { "limit": 100.0, "used": 12.5, "remaining_percent": 87.5, "resets_at": 1800086400 }
      }
    }
    """

    /// Tolerância de shape (spec §1.3): alias camelCase, números como string,
    /// campos ausentes — primary sem limit_window_seconds cai no fallback.
    static let whamUsageTolerantBody = """
    {
      "accountId": "fake-account-2",
      "planType": "pro",
      "rateLimit": {
        "primaryWindow": { "usedPercent": "55", "resetAt": "1800000000" },
        "secondaryWindow": { "usedPercent": 1.5, "resetAt": 1800086400, "limitWindowSeconds": 604800 }
      }
    }
    """

    /// Payload JWT base64url sintético (fallback de account_id, spec §1.2).
    static func jwtWithClaim(_ claim: String, value: String) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: [claim: value])
        var base64 = payload.base64EncodedString()
        base64 = base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while base64.hasSuffix("=") { base64.removeLast() }
        return "fake-header.\(base64).fake-signature"
    }
}

// MARK: - CodexAuthReader

@Suite
struct CodexAuthReaderTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexauth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func writeAuth(_ content: String, name: String = "auth.json") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func readParsesAccessTokenAndAccount() throws {
        let url = try writeAuth(CodexFixtures.authJSON())
        let auth = try #require(CodexAuthReader(authFileURL: url).read())
        #expect(auth.accessToken == "fake-token")
        #expect(auth.accountID == "fake-account-id")
        #expect(auth.authMode == "chatgpt")
        #expect(auth.hasOAuth)
    }

    @Test func accountIDFallsBackToJWTClaim() throws {
        let jwt = CodexFixtures.jwtWithClaim("chatgpt_account_id", value: "fake-jwt-account")
        let url = try writeAuth(CodexFixtures.authJSON(accountID: nil, idToken: jwt))
        let auth = try #require(CodexAuthReader(authFileURL: url).read())
        #expect(auth.accountID == "fake-jwt-account")
        #expect(auth.hasOAuth)
    }

    @Test func apikeyModeHasNoOAuth() throws {
        let url = try writeAuth(CodexFixtures.authJSON(authMode: "apikey", apiKey: "fake-api-key", accessToken: nil, accountID: nil, idToken: nil))
        let auth = try #require(CodexAuthReader(authFileURL: url).read())
        #expect(!auth.hasOAuth, "auth_mode apikey = sem usage API (spec §1.2)")
    }

    @Test func missingFileReturnsNil() {
        #expect(CodexAuthReader(authFileURL: dir.appendingPathComponent("inexistente.json")).read() == nil)
    }

    @Test func malformedFileReturnsNil() throws {
        let url = try writeAuth("not json at all{{{")
        #expect(CodexAuthReader(authFileURL: url).read() == nil)
    }

    @Test func resolvePrefersEnvironmentOverride() {
        let reader = CodexAuthReader.resolve(
            environment: ["TOKENBAR_CODEX_AUTH": "/tmp/fake/auth.json"],
            home: URL(filePath: "/Users/fake")
        )
        #expect(reader.authFileURL.path == "/tmp/fake/auth.json")
    }

    @Test func resolveDefaultsToHomeDotCodex() {
        let reader = CodexAuthReader.resolve(environment: [:], home: URL(filePath: "/Users/fake"))
        #expect(reader.authFileURL.path == "/Users/fake/.codex/auth.json")
    }
}

// MARK: - CodexLineParser (+ stamp de model/project do CodexSessionIngester)

struct CodexLineParserTests {
    // parser e ingester compartilham o MESMO tracker (é assim que o provider monta)
    let tracker: CodexModelTracker
    let parser: CodexLineParser
    let ingester: CodexSessionIngester

    init() {
        let t = CodexModelTracker()
        tracker = t
        parser = CodexLineParser(account: CodexFixtures.codexAccount, modelTracker: t)
        ingester = CodexSessionIngester(account: CodexFixtures.codexAccount, modelTracker: t)
    }

    let rolloutPath = "/tmp/fake/.codex/sessions/2026/09/02/rollout-1-fake-uuid.jsonl"

    @Test func parsesTokenCountDeltasWithAllFields() throws {
        let lines = CodexFixtures.rolloutLines(ts1: CodexFixtures.now, ts2: CodexFixtures.now)
        // linha 1 session_meta, linha 2 turn_context (registra o model), linha 3 token_count
        #expect(parser.parse(line: lines[1], fileModificationDate: CodexFixtures.now) == nil)
        let event = try #require(parser.parse(line: lines[2], fileModificationDate: CodexFixtures.now))
        #expect(event.provider == .codex)
        #expect(event.account == CodexFixtures.codexAccount)
        #expect(event.ts == CodexFixtures.now)
        #expect(event.inputTokens == 100)
        #expect(event.outputTokens == 110)
        #expect(event.cacheReadTokens == 40)
        #expect(event.cacheWriteTokens == 10)

        // stamp (makeEvent do padrão F1): model + project + account
        let stamped = ingester.stamp(event, path: rolloutPath)
        #expect(stamped.model == "gpt-5.2")
        #expect(stamped.project == "02", "projeto = diretório do arquivo (padrão F1)")
        #expect(stamped.account == CodexFixtures.codexAccount)
    }

    @Test func modelComesFromLastTurnContext() throws {
        let lines = CodexFixtures.rolloutLines(ts1: CodexFixtures.now, ts2: CodexFixtures.now)
        // Ordem do pipeline real: parse → stamp imediato por linha (o makeEvent
        // roda logo após o parse de cada linha no TranscriptIngester).
        _ = parser.parse(line: lines[1], fileModificationDate: CodexFixtures.now)  // turn_context gpt-5.2
        let e1 = try #require(parser.parse(line: lines[2], fileModificationDate: CodexFixtures.now))
        let s1 = ingester.stamp(e1, path: rolloutPath)
        _ = parser.parse(line: lines[3], fileModificationDate: CodexFixtures.now)  // turn_context gpt-5.3
        let e2 = try #require(parser.parse(line: lines[4], fileModificationDate: CodexFixtures.now))
        let s2 = ingester.stamp(e2, path: rolloutPath)
        #expect(s1.model == "gpt-5.2")
        #expect(s2.model == "gpt-5.3", "model do ÚLTIMO turn_context (spec §1.5)")
    }

    @Test func firstEventOfNewFileWithoutTurnContextHasNoModel() throws {
        let lines = CodexFixtures.rolloutLines(ts1: CodexFixtures.now, ts2: CodexFixtures.now)
        _ = parser.parse(line: lines[1], fileModificationDate: CodexFixtures.now)  // gpt-5.2 no arquivo A
        let e1 = try #require(parser.parse(line: lines[2], fileModificationDate: CodexFixtures.now))
        _ = ingester.stamp(e1, path: "/tmp/rollout-a.jsonl")

        let e2 = try #require(parser.parse(line: lines[4], fileModificationDate: CodexFixtures.now))
        let s2 = ingester.stamp(e2, path: "/tmp/rollout-b.jsonl")
        #expect(s2.model == nil, "troca de arquivo sem turn_context não herda model do anterior")
    }

    @Test func skipsNonUsageLines() {
        let lines = CodexFixtures.rolloutLines(ts1: CodexFixtures.now, ts2: CodexFixtures.now)
        #expect(parser.parse(line: lines[0], fileModificationDate: CodexFixtures.now) == nil)  // session_meta
        #expect(parser.parse(line: lines[1], fileModificationDate: CodexFixtures.now) == nil)  // turn_context
        #expect(parser.parse(line: lines[5], fileModificationDate: CodexFixtures.now) == nil)  // response_item
        #expect(parser.parse(line: "linha lixo não-json", fileModificationDate: CodexFixtures.now) == nil)
    }

    @Test func tokenCountWithoutInfoYieldsNoEvent() {
        let line = #"{"timestamp":"\#(CodexFixtures.iso(CodexFixtures.now))","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}"#
        #expect(parser.parse(line: line, fileModificationDate: CodexFixtures.now) == nil)
    }

    @Test func zeroTotalUsageYieldsNoEvent() {
        let line = #"{"timestamp":"\#(CodexFixtures.iso(CodexFixtures.now))","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0}}}}"#
        #expect(parser.parse(line: line, fileModificationDate: CodexFixtures.now) == nil)
    }

    @Test func invalidTimestampYieldsNoEvent() {
        let line = #"{"timestamp":"not-a-date","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":10}}}}"#
        #expect(parser.parse(line: line, fileModificationDate: CodexFixtures.now) == nil)
    }
}

// MARK: - CodexProvider (ingest local + resolve)

@Suite
final class CodexProviderTests {
    let dir: URL

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexprov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Escreve o rollout sintético na árvore YYYY/MM/DD de verdade (o scan é
    /// recursivo); devolve o byte length do arquivo.
    @discardableResult
    func writeRolloutFixture(ts1: Date? = nil, ts2: Date? = nil) throws -> Int {
        let day = dir.appendingPathComponent("2026/09/02", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let lines = CodexFixtures.rolloutLines(ts1: ts1 ?? CodexFixtures.now, ts2: ts2 ?? CodexFixtures.now)
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: day.appendingPathComponent("rollout-1-fake-uuid.jsonl"), atomically: true, encoding: .utf8)
        return content.utf8.count
    }

    func makeProvider(offsetStore: FileOffsetStoring = InMemoryOffsetStore(), calendar: Calendar? = nil) -> CodexProvider {
        CodexProvider(
            sessionsDirectory: dir,
            authReader: CodexAuthReader(authFileURL: dir.appendingPathComponent("auth.json")),
            client: UsageHTTPClient(baseURL: URL(string: "https://codex.example.com")!),
            offsetStore: offsetStore,
            calendar: calendar ?? self.calendar
        )
    }

    func makeUTCCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // MARK: identidade no protocolo

    @Test func conformsToUsageProviderBasics() async {
        let provider: any UsageProvider = makeProvider()
        #expect(provider.id == .codex)
        #expect(provider.capabilities == [.apiUsage, .localIngest, .multiAccount])  // F4: contas com auth file registrado
        #expect(CodexProvider.localDailyWindowLabel == "Hoje", "mesmo padrão pt-BR do ClaudeProvider")
    }

    @Test func resolveSessionsDirectoryOverrideAndDefault() {
        #expect(
            CodexProvider.resolveSessionsDirectory(environment: ["TOKENBAR_CODEX_DIR": "/tmp/fake-sessions"], home: URL(filePath: "/Users/fake")).path
                == "/tmp/fake-sessions"
        )
        #expect(
            CodexProvider.resolveSessionsDirectory(environment: [:], home: URL(filePath: "/Users/fake")).path
                == "/Users/fake/.codex/sessions"
        )
    }

    @Test func resolveBaseURLOverrideAndDefault() {
        #expect(
            CodexProvider.resolveBaseURL(environment: ["TOKENBAR_CODEX_API": "https://proxy.example.com"])
                == URL(string: "https://proxy.example.com")
        )
        #expect(CodexProvider.resolveBaseURL(environment: [:]) == URL(string: "https://chatgpt.com"))
        #expect(CodexProvider.resolveBaseURL(environment: ["TOKENBAR_CODEX_API": ""]) == URL(string: "https://chatgpt.com"))
    }

    // MARK: ingest local (padrão F1 + schema Codex)

    /// F2-CODEX-DELTA: soma SOMENTE last_token_usage (delta por evento);
    /// total_token_usage é cumulativo e NÃO entra. Esperado:
    /// (100+40+10+110) + (5+0+0+112) = 377 — e não 377+377+260 etc.
    @Test func ingestCountsOnlyLastTokenUsageDeltas() async throws {
        let byteLength = try writeRolloutFixture()
        let store = InMemoryOffsetStore()
        let provider = makeProvider(offsetStore: store)

        let batch = try await provider.ingestLocal(CodexFixtures.localRef, from: IngestCursor(), now: CodexFixtures.now)

        #expect(batch.eventsApplied == 2)
        let expected: Int64 = (100 + 40 + 10 + 110) + (5 + 0 + 0 + 112)
        #expect(batch.providerTotals[.codex] == expected)

        let path = try #require(batch.nextCursor.fileOffsets.keys.first)
        #expect(path.hasSuffix("rollout-1-fake-uuid.jsonl"))
        #expect(batch.nextCursor.fileOffsets[path]?.offset == UInt64(byteLength))
        #expect(batch.nextCursor.fileOffsets == store.cursors())
    }

    @Test func ingestTwiceDoesNotDuplicate() async throws {
        try writeRolloutFixture()
        let provider = makeProvider()

        let first = try await provider.ingestLocal(CodexFixtures.localRef, from: IngestCursor(), now: CodexFixtures.now)
        let second = try await provider.ingestLocal(CodexFixtures.localRef, from: first.nextCursor, now: CodexFixtures.now)

        #expect(first.eventsApplied == 2)
        #expect(second.eventsApplied == 0)
        let expected: Int64 = 377
        #expect(second.providerTotals[.codex] == expected, "segunda passada mantém total")
    }

    @Test func missingSessionsDirectoryYieldsZero() async throws {
        let provider = CodexProvider(
            sessionsDirectory: URL(filePath: "/nonexistent-\(UUID().uuidString)"),
            authReader: CodexAuthReader(authFileURL: dir.appendingPathComponent("auth.json")),
            client: UsageHTTPClient(baseURL: URL(string: "https://codex.example.com")!),
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar
        )
        let batch = try await provider.ingestLocal(CodexFixtures.localRef, from: IngestCursor(), now: CodexFixtures.now)
        #expect(batch.eventsApplied == 0)
        #expect(batch.providerTotals.isEmpty)
    }

    /// O caso de rollover pinado na F1 (regressão 43c6e0d): na virada de dia
    /// o scan re-ingere o arquivo inteiro e o nextCursor reflete o que o ciclo
    /// de fato consumiu.
    @Test func rolloverRescansFullFileOnDayChange() async throws {
        let c = makeUTCCalendar()
        let startDay1 = c.startOfDay(for: CodexFixtures.now)
        let eventDate = c.date(byAdding: .hour, value: 10, to: startDay1)!
        let now1 = c.date(byAdding: .hour, value: 11, to: startDay1)!
        let now2 = c.date(byAdding: .day, value: 1, to: now1)!
        let byteLength = try writeRolloutFixture(ts1: eventDate, ts2: c.date(byAdding: .minute, value: 30, to: eventDate)!)

        let store = InMemoryOffsetStore()
        let provider = makeProvider(offsetStore: store, calendar: c)

        let day1 = try await provider.ingestLocal(CodexFixtures.localRef, from: IngestCursor(), now: now1)
        #expect(day1.eventsApplied == 2)
        #expect(day1.providerTotals[.codex] == 377)

        let day2 = try await provider.ingestLocal(CodexFixtures.localRef, from: day1.nextCursor, now: now2)
        #expect(day2.eventsApplied == 2, "rollover re-entrega (contrato F1)")
        #expect(day2.providerTotals.isEmpty, "eventos são do dia-1: total do dia-2 zerado")
        let path = try #require(day2.nextCursor.fileOffsets.keys.first)
        #expect(day2.nextCursor.fileOffsets[path]?.offset == UInt64(byteLength))
        #expect(day2.nextCursor.fileOffsets == store.cursors())
    }

    @Test func ingestLocalRejectsUnknownAccount() async throws {
        let provider = makeProvider()
        let stranger = AccountRef(id: AccountID(provider: .codex, key: "outra"), label: "?")
        await #expect(throws: CodexProviderError.self) {
            try await provider.ingestLocal(stranger, from: IngestCursor(), now: CodexFixtures.now)
        }
    }

    /// Red Team F2 caso 7: restart mid-day — ledger novo, mesmo cursor store
    /// (instância compartilhada simula a persistência) + snapshot do dia → o
    /// total de hoje sobrevive ao relançamento (era 0 até o rollover).
    @Test func restartMidDayRestoresTodayTotals() async throws {
        try writeRolloutFixture()  // 377 (só last_token_usage, F2-CODEX-DELTA)
        let cursors = InMemoryOffsetStore()
        let ledgerURL = dir.appendingPathComponent("codex-ledger.json")

        func make(snapshots: JSONLedgerSnapshotStore?) -> CodexProvider {
            CodexProvider(
                sessionsDirectory: dir,
                authReader: CodexAuthReader(authFileURL: dir.appendingPathComponent("auth-ausente.json")),
                client: UsageHTTPClient(baseURL: URL(string: "https://codex.example.com")!),
                offsetStore: cursors,
                calendar: calendar,
                ledgerSnapshotStore: snapshots
            )
        }

        let outcome = try await make(snapshots: JSONLedgerSnapshotStore(url: ledgerURL))
            .ingestLocal(CodexFixtures.localRef, from: IngestCursor(fileOffsets: cursors.cursors()), now: CodexFixtures.now)
        #expect(outcome.providerTotals[.codex] == 377)

        // "Restart": provider novo, cursor semeado do store fresco (contrato).
        let after = try await make(snapshots: JSONLedgerSnapshotStore(url: ledgerURL))
            .ingestLocal(CodexFixtures.localRef, from: IngestCursor(fileOffsets: cursors.cursors()), now: CodexFixtures.now)
        #expect(after.providerTotals[.codex] == 377)
    }

    /// Red Team T8 (auditoria do fix 42d42e9): cursor de path FORA da raiz de
    /// scan atual sobrevive no store (stores nunca podam) e o stamp do snapshot
    /// carimbado com ele BATE — sem o escopo da raiz, o total morto volta no
    /// restore (menu bar dobrava entre runs no e2e de 2026-09-03).
    @Test func staleTotalsWithSurvivingCursorsAreNotRestored() async throws {
        try writeRolloutFixture()  // 377
        let cursors = InMemoryOffsetStore()
        let ledgerURL = dir.appendingPathComponent("codex-ledger.json")
        let stalePath = "/tmp/tokenbar-e2e.anterior/codex/rollout-velho.jsonl"
        try cursors.set(FileCursor(offset: 99), for: stalePath)
        let stale = LedgerSnapshot(
            day: calendar.startOfDay(for: CodexFixtures.now),
            files: [stalePath: TokenSums(input: 4_000_000)],
            cursorStamp: LedgerSnapshotStamp.make(cursors.cursors())
        )
        JSONLedgerSnapshotStore(url: ledgerURL).save(stale)

        let provider = CodexProvider(
            sessionsDirectory: dir,
            authReader: CodexAuthReader(authFileURL: dir.appendingPathComponent("auth-ausente.json")),
            client: UsageHTTPClient(baseURL: URL(string: "https://codex.example.com")!),
            offsetStore: cursors,
            calendar: calendar,
            ledgerSnapshotStore: JSONLedgerSnapshotStore(url: ledgerURL)
        )
        let outcome = try await provider.ingestLocal(
            CodexFixtures.localRef, from: IngestCursor(fileOffsets: cursors.cursors()), now: CodexFixtures.now
        )
        #expect(outcome.providerTotals[.codex] == 377, "total de path fora da raiz de scan não volta no restore")
    }
}

// MARK: - CodexProvider (usage API via stub)

@Suite(.serialized)
final class CodexUsageAPITests {
    let dir: URL

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexapi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func writeAuth(_ content: String) throws -> URL {
        let url = dir.appendingPathComponent("auth.json")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func makeProvider(authFile: URL?) -> CodexProvider {
        CodexProvider(
            sessionsDirectory: dir.appendingPathComponent("sessions"),
            authReader: CodexAuthReader(authFileURL: authFile ?? dir.appendingPathComponent("missing.json")),
            client: UsageHTTPClient(baseURL: URL(string: "https://codex.example.com")!, session: stubbedSession()),
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar
        )
    }

    @Test func discoverAccountsRequiresAuthFile() async throws {
        let withAuth = makeProvider(authFile: try writeAuth(CodexFixtures.authJSON()))
        #expect(await withAuth.discoverAccounts() == [CodexFixtures.localRef])

        let withoutAuth = makeProvider(authFile: nil)
        #expect(await withoutAuth.discoverAccounts() == [])
    }

    @Test func fetchUsageMapsWhamShapeAndSendsContractedHeaders() async throws {
        CodexStubURLProtocol.configure { _ in
            CodexStubURLProtocol.Exchange(status: 200, body: Data(CodexFixtures.whamUsageBody.utf8), error: nil)
        }
        let provider = makeProvider(authFile: try writeAuth(CodexFixtures.authJSON()))

        let snapshot = try await provider.fetchUsage(CodexFixtures.localRef)

        // Requisição: URL canônica + headers da spec §1.1
        let request = try #require(CodexStubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://codex.example.com/backend-api/wham/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "fake-account-id")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("TokenBar/") == true)

        // Mapeamento spec §1.4
        #expect(snapshot.provider == .codex)
        #expect(snapshot.account == AccountID(provider: .codex, key: "fake-account-id"))
        #expect(snapshot.source == .api)
        #expect(snapshot.authState == .ok)
        #expect(snapshot.credits == CreditsInfo(remaining: nil, unlimited: false))
        #expect(snapshot.windows.count == 2)

        let primary = snapshot.windows[0]
        #expect(primary.kind == .session)
        #expect(primary.label == "5h")
        #expect(primary.usedFraction == 0.42)
        #expect(primary.resetsAt == Date(timeIntervalSince1970: 1_800_000_000), "epoch em SEGUNDOS")

        let secondary = snapshot.windows[1]
        #expect(secondary.kind == .weekly)
        #expect(secondary.label == "Semanal")
        #expect(secondary.usedFraction == 0.07)
        #expect(secondary.resetsAt == Date(timeIntervalSince1970: 1_800_086_400))
    }

    /// Decoder tolerante: alias camelCase, números como string, primary sem
    /// limit_window_seconds (fallback), sem credits — spec §1.3.
    @Test func fetchUsageToleratesAliasesAndStringNumbers() async throws {
        CodexStubURLProtocol.configure { _ in
            CodexStubURLProtocol.Exchange(status: 200, body: Data(CodexFixtures.whamUsageTolerantBody.utf8), error: nil)
        }
        let provider = makeProvider(authFile: try writeAuth(CodexFixtures.authJSON()))

        let snapshot = try await provider.fetchUsage(CodexFixtures.localRef)

        #expect(snapshot.account == AccountID(provider: .codex, key: "fake-account-2"))
        #expect(snapshot.credits == nil)
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows[0].kind == .session)
        #expect(snapshot.windows[0].label == "5h", "sem limit_window_seconds usa fallback da posição")
        #expect(snapshot.windows[0].usedFraction == 0.55)
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(snapshot.windows[1].kind == .weekly)
        #expect(snapshot.windows[1].label == "Semanal")
        #expect(snapshot.windows[1].usedFraction == 0.015)
    }

    /// 401/403 → authState .invalid + snapshot degradado .localOnly (nunca erro).
    @Test func fetchUsageDegradesOn401And403() async throws {
        for status in [401, 403] {
            CodexStubURLProtocol.configure { _ in CodexStubURLProtocol.Exchange(status: status, body: Data(), error: nil) }
            let provider = makeProvider(authFile: try writeAuth(CodexFixtures.authJSON()))

            let snapshot = try await provider.fetchUsage(CodexFixtures.localRef)

            #expect(snapshot.source == .localOnly)
            #expect(snapshot.authState == .invalid)
            #expect(snapshot.credits == nil)
            #expect(snapshot.windows.count == 1)
            #expect(snapshot.windows[0].kind == .daily)
            #expect(snapshot.windows[0].usedFraction == nil)
            #expect(snapshot.windows[0].label == "Hoje")
            #expect(snapshot.windows[0].resetsAt != nil && snapshot.windows[0].resetsAt! > snapshot.fetchedAt)
        }
    }

    /// auth.json ausente → discoverAccounts [] e fetchUsage .missing/.localOnly.
    @Test func missingCredentialReportsMissingAndLocalOnly() async throws {
        let provider = makeProvider(authFile: nil)
        #expect(await provider.discoverAccounts() == [])

        let snapshot = try await provider.fetchUsage(CodexFixtures.localRef)
        #expect(snapshot.source == .localOnly)
        #expect(snapshot.authState == .missing)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].kind == .daily)
        #expect(snapshot.windows[0].label == "Hoje")
        #expect(snapshot.windows[0].usedFraction == nil)
    }

    /// auth_mode apikey → sem usage API; snapshot .localOnly (spec §1.6), mas a
    /// conta existe para o ingest local.
    @Test func apikeyModeHasAccountButNoAPIUsage() async throws {
        let authFile = try writeAuth(CodexFixtures.authJSON(authMode: "apikey", apiKey: "fake-api-key", accessToken: nil, accountID: nil, idToken: nil))
        let provider = makeProvider(authFile: authFile)

        #expect(await provider.discoverAccounts() == [CodexFixtures.localRef])

        let snapshot = try await provider.fetchUsage(CodexFixtures.localRef)
        #expect(snapshot.source == .localOnly)
        #expect(snapshot.authState == .missing)
    }

    /// Erro de rede → rethrow (o scheduler trata backoff; spec §5 regra 3).
    @Test func networkErrorRethrows() async throws {
        CodexStubURLProtocol.configure { _ in
            CodexStubURLProtocol.Exchange(status: 0, body: Data(), error: URLError(.timedOut))
        }
        let provider = makeProvider(authFile: try writeAuth(CodexFixtures.authJSON()))

        await #expect(throws: UsageHTTPError.network(URLError(.timedOut))) {
            try await provider.fetchUsage(CodexFixtures.localRef)
        }
    }

    @Test func fetchUsageRejectsUnknownAccount() async throws {
        let provider = makeProvider(authFile: try writeAuth(CodexFixtures.authJSON()))
        let stranger = AccountRef(id: AccountID(provider: .codex, key: "outra"), label: "?")
        await #expect(throws: CodexProviderError.self) {
            try await provider.fetchUsage(stranger)
        }
    }
}
