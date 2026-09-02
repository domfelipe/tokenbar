# TokenBar F1 — Skeleton + Claude Local Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App de menu bar nativo que mostra tokens de hoje do Claude Code (modo local, lendo transcripts JSONL incrementalmente), dentro do orçamento de performance da spec, fechado com E2E + QA + Red Team.

**Architecture:** Single-process SwiftUI `MenuBarExtra`; `TokenBarCore` (domínio, ingest incremental, ledger, watcher, scheduler) sem dependência de UI; `TokenBarProviders` (Claude local-first); `tokenbar` executable com wiring + subcomando `selfcheck`; fixtures sintéticas via target `genfixtures`. Zero dependências externas na F1 (GRDB entra na F3).

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, FSEvents (CoreServices), Foundation, XCTest via `swift test`. Toolchain: Command Line Tools (sem Xcode).

**Spec:** `docs/specs/2026-09-02-design.md` (F1 = seção 12, linha F1; seções 4, 5.2, 7, 9, 10 mandam aqui)

## Global Constraints

- Target **macOS 14+** (`platforms: [.macOS(.v14)]`); Swift tools-version 6.0 (language mode Swift 6 = strict concurrency).
- Compila e testa **só com Command Line Tools** (`swift build`, `swift test`) — nenhum passo pode exigir Xcode/`xcodebuild`/`actool`.
- **Orçamento de performance (spec §7):** CPU ociosa < 0,5% sustentado; RAM (rss) ≤ 40 MB estado estacionário; ingest de 10k eventos sintéticos < 1 s; debounce de watcher 3 s; re-render do ícone só quando a string exibida muda.
- **Credenciais (spec §5, §9):** F1 não lê NENHUMA credencial (nem `auth.json`, nem Keychain, nem env de token). Proibido: literal de credencial em código, teste, fixture ou doc. Fixture de transcript **sempre sintética**.
- **Parsing incremental:** cursor `(path, offset)` por arquivo; nunca re-ler bytes já consumidos; linha final sem `\n` não é consumida.
- **"Hoje"** = dia local do usuário (`Calendar` injetado; produção usa `.current`).
- UI strings em inglês (público OSS); docs internas em PT-BR; README bilíngue na F6.
- Debug affordance E2E: estado vivo escrito em disco **só quando** `TOKENBAR_E2E_DIR` está setado; sem essa env, nada é escrito fora de App Support.
- Overrides de ambiente (usados por testes/E2E): `TOKENBAR_CLAUDE_DIR` (base de transcripts), `TOKENBAR_E2E_DIR` (heartbeat).
- F1 persiste cursores em JSON (`~/Library/Application Support/TokenBar/cursors.json`); migração para a tabela `settings` (SQLite) acontece na F3.
- TDD: teste antes do código em toda task; commit ao fim de cada task.

## File Structure (mapa final da F1)

```
Package.swift
Sources/
  TokenBarCore/
    Domain/{ProviderID,AccountID,UsageEvent,TokenSums}.swift
    Ingest/{FileCursor,FileOffsetStore,TranscriptIngester,TokenLedger}.swift
    Watcher/TranscriptWatcher.swift          (Debouncer + FSEvents)
  TokenBarProviders/
    Claude/{ClaudeTranscriptLine,ClaudeLineParser,ClaudeTranscriptLocator,ClaudeProvider}.swift
  TokenBarUI/
    MenuBarContent.swift                     (abbrev + displayString)
    SnapshotStore.swift                      (@Observable + render gate)
  tokenbar/
    TokenBarApp.swift                        (@main dispatcher + MenuBarExtra)
    AppState.swift                           (wiring ingest loop)
    E2EHeartbeat.swift                       (heartbeat só com TOKENBAR_E2E_DIR)
    SelfCheck.swift                          (subcomando selfcheck)
  genfixtures/GenFixtures.swift
Tests/
  TokenBarCoreTests/   (domínio, offsets, ingester, ledger, debounce, smoke, perf)
  TokenBarProvidersTests/ (parser, provider)
  TokenBarUITests/     (menu bar content + render gate)
scripts/
  make-app.sh  genicon.swift  e2e.sh
docs/
  specs/2026-09-02-design.md  plans/este-arquivo  qa/f1-*.md
```

**Goal E2E (critério de aceite da F1, Task 14 valida):** dado um corpus sintético conhecido, o app bundle real (`TokenBar.app` via `make-app.sh`), lançado com `TOKENBAR_CLAUDE_DIR` apontando pro corpus, exibe no menu bar o total correto de tokens de hoje em ≤ 30 s, atualiza em ≤ 10 s após append de nova linha, fica < 0,5% CPU e ≤ 40 MB rss após 60 s ocioso, e não crasha sob corpus hostil (Task 16).

---

### Task 1: Package skeleton

**Files:**
- Create: `Package.swift`
- Create: `Sources/TokenBarCore/TokenBarCore.swift`
- Create: `Sources/TokenBarProviders/TokenBarProviders.swift`
- Create: `Sources/TokenBarUI/TokenBarUI.swift`
- Create: `Sources/tokenbar/TokenBarApp.swift`
- Create: `Sources/genfixtures/GenFixtures.swift`
- Test: `Tests/TokenBarCoreTests/SmokeTests.swift`

**Interfaces:**
- Produces: targets `TokenBarCore`, `TokenBarProviders`, `TokenBarUI`, executables `tokenbar`, `genfixtures`; `TokenBarCoreInfo.version` (`String`) usado pelo smoke test.

- [ ] **Step 1: Escrever Package.swift e stubs**

`Package.swift`:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "tokenbar", targets: ["tokenbar"]),
        .executable(name: "genfixtures", targets: ["genfixtures"]),
    ],
    targets: [
        .target(name: "TokenBarCore"),
        .target(name: "TokenBarProviders", dependencies: ["TokenBarCore"]),
        .target(name: "TokenBarUI", dependencies: ["TokenBarCore"]),
        .executableTarget(
            name: "tokenbar",
            dependencies: ["TokenBarCore", "TokenBarProviders", "TokenBarUI"]
        ),
        .executableTarget(name: "genfixtures"),
        .testTarget(name: "TokenBarCoreTests", dependencies: ["TokenBarCore"]),
        .testTarget(name: "TokenBarProvidersTests", dependencies: ["TokenBarProviders", "TokenBarCore"]),
        .testTarget(name: "TokenBarUITests", dependencies: ["TokenBarUI", "TokenBarCore"]),
    ]
)
```

`Sources/TokenBarCore/TokenBarCore.swift`:

```swift
public enum TokenBarCoreInfo {
    public static let version = "0.1.0-f1"
}
```

`Sources/TokenBarProviders/TokenBarProviders.swift`:

```swift
public enum ProvidersInfo {
    public static let version = "0.1.0-f1"
}
```

`Sources/TokenBarUI/TokenBarUI.swift`:

```swift
public enum TokenBarUIInfo {
    public static let version = "0.1.0-f1"
}
```

`Sources/tokenbar/TokenBarApp.swift`:

```swift
import Foundation

@main
struct TokenBarMain {
    static func main() async {
        print("tokenbar \(TokenBarCoreInfo.version)")
    }
}
```

`Sources/genfixtures/GenFixtures.swift`:

```swift
print("genfixtures: implemented in Task 11")
```

`Tests/TokenBarCoreTests/SmokeTests.swift`:

```swift
import XCTest
@testable import TokenBarCore

final class SmokeTests: XCTestCase {
    func testCoreVersionIsSet() {
        XCTAssertFalse(TokenBarCoreInfo.version.isEmpty)
    }
}
```

- [ ] **Step 2: Rodar build e testes**

Run: `cd ~/Documents/Projetos/tokenbar && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: build OK; `Executed 1 test, with 0 failures`.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: package skeleton (4 targets, zero deps)"
```

---

### Task 2: Domain types (ProviderID, AccountID, UsageEvent, TokenSums)

**Files:**
- Create: `Sources/TokenBarCore/Domain/ProviderID.swift`
- Create: `Sources/TokenBarCore/Domain/AccountID.swift`
- Create: `Sources/TokenBarCore/Domain/UsageEvent.swift`
- Create: `Sources/TokenBarCore/Domain/TokenSums.swift`
- Test: `Tests/TokenBarCoreTests/DomainTests.swift`

**Interfaces:**
- Produces (usado por todas as tasks seguintes):

```swift
public enum ProviderID: String, Sendable, Codable, CaseIterable  // .claude, .codex, .gemini, .zai, .cursor, .openrouter, .copilot
public struct AccountID: Hashable, Sendable, Codable             // init(provider:key:)
public struct UsageEvent: Sendable, Equatable, Codable           // ts, provider, account, model, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, project
public struct TokenSums: Sendable, Equatable, Codable            // input, output, cacheRead, cacheWrite; var total: Int64; + - += -=
```

- [ ] **Step 1: Escrever testes que falham**

`Tests/TokenBarCoreTests/DomainTests.swift`:

```swift
import XCTest
@testable import TokenBarCore

final class DomainTests: XCTestCase {
    func testProviderIDCodableRoundtrip() throws {
        let original = ProviderID.claude
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ProviderID.self, from: data), original)
    }

    func testAccountIDHashAndEquality() {
        let a = AccountID(provider: .claude, key: "local")
        let b = AccountID(provider: .claude, key: "local")
        let c = AccountID(provider: .claude, key: "work")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(Set([a, b, c]).count, 2)
    }

    func testUsageEventCodableRoundtrip() throws {
        let event = UsageEvent(
            ts: Date(timeIntervalSince1970: 1_788_000_000),
            provider: .claude,
            account: AccountID(provider: .claude, key: "local"),
            model: "claude-sonnet-4-6",
            inputTokens: 100, outputTokens: 200, cacheReadTokens: 300, cacheWriteTokens: 400,
            project: "domhubs-devsquad"
        )
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(UsageEvent.self, from: data), event)
    }

    func testTokenSumsArithmetic() {
        var sums = TokenSums(input: 10, output: 20, cacheRead: 30, cacheWrite: 40)
        XCTAssertEqual(sums.total, 100)
        sums += TokenSums(input: 1, output: 2, cacheRead: 3, cacheWrite: 4)
        XCTAssertEqual(sums, TokenSums(input: 11, output: 22, cacheRead: 33, cacheWrite: 44))
        sums = sums - sums  // zera
        XCTAssertEqual(sums.total, 0)
    }

    func testTokenSumsCodableRoundtrip() throws {
        let sums = TokenSums(input: 1, output: 2, cacheRead: 3, cacheWrite: 4)
        let data = try JSONEncoder().encode(sums)
        XCTAssertEqual(try JSONDecoder().decode(TokenSums.self, from: data), sums)
    }
}
```

- [ ] **Step 2: Rodar e verificar falha**

Run: `swift test --filter DomainTests 2>&1 | tail -3`
Expected: FAIL (tipos não existem).

- [ ] **Step 3: Implementar os tipos**

`Sources/TokenBarCore/Domain/ProviderID.swift`:

```swift
public enum ProviderID: String, Sendable, Codable, CaseIterable {
    case claude, codex, gemini, zai, cursor, openrouter, copilot
}
```

`Sources/TokenBarCore/Domain/AccountID.swift`:

```swift
public struct AccountID: Hashable, Sendable, Codable {
    public let provider: ProviderID
    public let key: String

    public init(provider: ProviderID, key: String) {
        self.provider = provider
        self.key = key
    }
}
```

`Sources/TokenBarCore/Domain/UsageEvent.swift`:

```swift
import Foundation

public struct UsageEvent: Sendable, Equatable, Codable {
    public var ts: Date
    public var provider: ProviderID
    public var account: AccountID
    public var model: String?
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheWriteTokens: Int64
    public var project: String?

    public init(
        ts: Date, provider: ProviderID, account: AccountID, model: String?,
        inputTokens: Int64, outputTokens: Int64,
        cacheReadTokens: Int64, cacheWriteTokens: Int64, project: String?
    ) {
        self.ts = ts
        self.provider = provider
        self.account = account
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.project = project
    }
}
```

`Sources/TokenBarCore/Domain/TokenSums.swift`:

```swift
public struct TokenSums: Sendable, Equatable, Codable {
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64

    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Int64 { input + output + cacheRead + cacheWrite }

    public static func + (lhs: TokenSums, rhs: TokenSums) -> TokenSums {
        TokenSums(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }

    public static func - (lhs: TokenSums, rhs: TokenSums) -> TokenSums {
        TokenSums(
            input: lhs.input - rhs.input, output: lhs.output - rhs.output,
            cacheRead: lhs.cacheRead - rhs.cacheRead, cacheWrite: lhs.cacheWrite - rhs.cacheWrite
        )
    }

    public static func += (lhs: inout TokenSums, rhs: TokenSums) { lhs = lhs + rhs }
}
```

- [ ] **Step 4: Rodar e verificar verde**

Run: `swift test --filter DomainTests 2>&1 | tail -3`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): domain types ProviderID/AccountID/UsageEvent/TokenSums"
```

---

### Task 3: Parser de linha de transcript Claude

**Files:**
- Create: `Sources/TokenBarProviders/Claude/ClaudeTranscriptLine.swift`
- Create: `Sources/TokenBarProviders/Claude/ClaudeLineParser.swift`
- Test: `Tests/TokenBarProvidersTests/ClaudeLineParserTests.swift` (target já registrado na Task 1)

**Interfaces:**
- Consumes: `UsageEvent`, `AccountID`, `ProviderID` (Task 2).
- Produces:

```swift
struct ClaudeTranscriptLine: Decodable   // modelo tolerante (todos os campos opcionais)
public struct ClaudeLineParser: Sendable
//   init(account: AccountID, project: String?)
//   func parse(line: String, fileModificationDate: Date) -> UsageEvent?
//   nil para: type != "assistant", usage ausente, timestamp inválido, JSON inválido, linha > 5 MB
```

- [ ] **Step 1: Escrever testes que falham**

`Tests/TokenBarProvidersTests/ClaudeLineParserTests.swift` — fixtures **sintéticas** no formato real de transcript (uma linha JSON por linha):

```swift
import XCTest
@testable import TokenBarCore
@testable import TokenBarProviders

final class ClaudeLineParserTests: XCTestCase {
    let account = AccountID(provider: .claude, key: "local")
    let modDate = Date(timeIntervalSince1970: 1_788_000_000)

    func parser() -> ClaudeLineParser {
        ClaudeLineParser(account: account, project: "fixture-proj")
    }

    func testAssistantLineWithUsageProducesEvent() throws {
        let line = #"{"type":"assistant","timestamp":"2026-09-02T12:00:00.500Z","cwd":"/tmp/proj","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":300,"cache_creation_input_tokens":40}}}"#
        let event = try XCTUnwrap(parser().parse(line: line, fileModificationDate: modDate))
        XCTAssertEqual(event.provider, .claude)
        XCTAssertEqual(event.account, account)
        XCTAssertEqual(event.model, "claude-sonnet-4-6")
        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.outputTokens, 200)
        XCTAssertEqual(event.cacheReadTokens, 300)
        XCTAssertEqual(event.cacheWriteTokens, 40)
        XCTAssertEqual(event.project, "fixture-proj")
        XCTAssertEqual(event.ts.timeIntervalSince1970, 1_788_000_000 + 43_200, accuracy: 1)
    }

    func testUserLineIsSkipped() {
        let line = #"{"type":"user","timestamp":"2026-09-02T12:00:01.000Z","message":{"content":"oi"}}"#
        XCTAssertNil(parser().parse(line: line, fileModificationDate: modDate))
    }

    func testAssistantWithoutUsageIsSkipped() {
        let line = #"{"type":"assistant","timestamp":"2026-09-02T12:00:02.000Z","message":{"model":"claude-sonnet-4-6"}}"#
        XCTAssertNil(parser().parse(line: line, fileModificationDate: modDate))
    }

    func testTruncatedJSONIsSkippedNotFatal() {
        XCTAssertNil(parser().parse(line: #"{"type":"assistant","timestamp":"2026-09-02T1"#, fileModificationDate: modDate))
    }

    func testBinaryGarbageIsSkippedNotFatal() {
        XCTAssertNil(parser().parse(line: "\u{00}\u{01}\u{02}garbage", fileModificationDate: modDate))
    }

    func testInvalidTimestampIsSkipped() {
        let line = #"{"type":"assistant","timestamp":"nao-e-uma-data","message":{"usage":{"input_tokens":5,"output_tokens":5}}}"#
        XCTAssertNil(parser().parse(line: line, fileModificationDate: modDate))
    }

    func testNegativeTokensAreClampedToZero() throws {
        let line = #"{"type":"assistant","timestamp":"2026-09-02T12:00:03.000Z","message":{"usage":{"input_tokens":-10,"output_tokens":5}}}"#
        let event = try XCTUnwrap(parser().parse(line: line, fileModificationDate: modDate))
        XCTAssertEqual(event.inputTokens, 0)
        XCTAssertEqual(event.outputTokens, 5)
    }

    func testAllZeroUsageIsSkipped() {
        let line = #"{"type":"assistant","timestamp":"2026-09-02T12:00:04.000Z","message":{"usage":{"input_tokens":0,"output_tokens":0}}}"#
        XCTAssertNil(parser().parse(line: line, fileModificationDate: modDate))
    }

    func testHugeLineDoesNotCrash() {
        let huge = String(repeating: "a", count: 5_000_000)
        XCTAssertNil(parser().parse(line: huge, fileModificationDate: modDate))
    }
}
```

- [ ] **Step 2: Rodar e verificar falha**

Run: `swift test --filter ClaudeLineParserTests 2>&1 | tail -3`
Expected: FAIL (tipos não existem).

- [ ] **Step 3: Implementar parser**

`Sources/TokenBarProviders/Claude/ClaudeTranscriptLine.swift`:

```swift
struct ClaudeTranscriptLine: Decodable {
    struct Message: Decodable {
        struct Usage: Decodable {
            var input_tokens: Int64?
            var output_tokens: Int64?
            var cache_read_input_tokens: Int64?
            var cache_creation_input_tokens: Int64?
        }
        var model: String?
        var usage: Usage?
    }
    var type: String?
    var timestamp: String?
    var cwd: String?
    var message: Message?
}
```

`Sources/TokenBarProviders/Claude/ClaudeLineParser.swift`:

```swift
import Foundation
import TokenBarCore

/// Parser tolerante de uma linha de transcript do Claude Code.
/// Linhas inválidas/sem uso retornam nil — nunca lançam.
public struct ClaudeLineParser: Sendable {
    private let account: AccountID
    private let project: String?

    // ISO8601DateFormatter é thread-safe para parse; nonisolated(unsafe) pois
    // Foundation não anota Sendable, mas o uso é só-leitura.
    private nonisolated(unsafe) static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()

    public init(account: AccountID, project: String?) {
        self.account = account
        self.project = project
    }

    public func parse(line: String, fileModificationDate: Date) -> UsageEvent? {
        guard line.count <= 5_000_000,
              let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ClaudeTranscriptLine.self, from: data),
              decoded.type == "assistant",
              let usage = decoded.message?.usage
        else { return nil }

        let input = max(0, usage.input_tokens ?? 0)
        let output = max(0, usage.output_tokens ?? 0)
        let cacheRead = max(0, usage.cache_read_input_tokens ?? 0)
        let cacheWrite = max(0, usage.cache_creation_input_tokens ?? 0)
        guard input + output + cacheRead + cacheWrite > 0 else { return nil }

        let ts = decoded.timestamp.flatMap {
            Self.iso8601Fractional.date(from: $0) ?? Self.iso8601.date(from: $0)
        } ?? fileModificationDate

        return UsageEvent(
            ts: ts, provider: .claude, account: account,
            model: decoded.message?.model,
            inputTokens: input, outputTokens: output,
            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
            project: project
        )
    }
}
```

- [ ] **Step 4: Rodar e verificar verde**

Run: `swift test --filter ClaudeLineParserTests 2>&1 | tail -3`
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(providers): parser tolerante de linha de transcript Claude"
```

---

### Task 4: FileOffsetStore (cursores em JSON)

**Files:**
- Create: `Sources/TokenBarCore/Ingest/FileCursor.swift`
- Create: `Sources/TokenBarCore/Ingest/FileOffsetStore.swift`
- Test: `Tests/TokenBarCoreTests/FileOffsetStoreTests.swift`

**Interfaces:**
- Consumes: nada.
- Produces:

```swift
public struct FileCursor: Sendable, Codable, Equatable   // var offset: UInt64
public protocol FileOffsetStoring: Sendable              // cursors() -> [String: FileCursor]; set(_:for:) throws (nil remove)
public final class JSONFileOffsetStore: FileOffsetStoring  // init(url:); JSON em disco; corrompido/ausente = vazio
```

> As implementações de `FileOffsetStoring` são **classes** (o store muta estado interno; com structs, a chamada via `any FileOffsetStoring` em `let` não compilaria).

- [ ] **Step 1: Escrever testes que falham**

`Tests/TokenBarCoreTests/FileOffsetStoreTests.swift`:

```swift
import XCTest
@testable import TokenBarCore

final class FileOffsetStoreTests: XCTestCase {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name + "-" + UUID().uuidString)
    }

    func testSetThenReloadRoundtrip() throws {
        let url = tempURL("cursors")
        do {
            let store = JSONFileOffsetStore(url: url)
            try store.set(FileCursor(offset: 1234), for: "/tmp/a.jsonl")
            try store.set(FileCursor(offset: 0), for: "/tmp/b.jsonl")
        }
        let reloaded = JSONFileOffsetStore(url: url)
        XCTAssertEqual(reloaded.cursors()["/tmp/a.jsonl"], FileCursor(offset: 1234))
        XCTAssertEqual(reloaded.cursors()["/tmp/b.jsonl"], FileCursor(offset: 0))
    }

    func testRemoveWithNil() throws {
        let url = tempURL("cursors")
        let store = JSONFileOffsetStore(url: url)
        try store.set(FileCursor(offset: 10), for: "/tmp/a.jsonl")
        try store.set(nil, for: "/tmp/a.jsonl")
        XCTAssertTrue(store.cursors().isEmpty)
    }

    func testCorruptedFileStartsEmpty() throws {
        let url = tempURL("cursors")
        try "{not json".write(to: url, atomically: true, encoding: .utf8)
        let store = JSONFileOffsetStore(url: url)
        XCTAssertTrue(store.cursors().isEmpty)
    }

    func testMissingFileStartsEmpty() {
        let store = JSONFileOffsetStore(url: tempURL("never-created"))
        XCTAssertTrue(store.cursors().isEmpty)
    }
}
```

- [ ] **Step 2: Rodar e verificar falha**

Run: `swift test --filter FileOffsetStoreTests 2>&1 | tail -3`
Expected: FAIL.

- [ ] **Step 3: Implementar**

`Sources/TokenBarCore/Ingest/FileCursor.swift`:

```swift
public struct FileCursor: Sendable, Codable, Equatable {
    public var offset: UInt64

    public init(offset: UInt64) {
        self.offset = offset
    }
}
```

`Sources/TokenBarCore/Ingest/FileOffsetStore.swift`:

```swift
import Foundation

public protocol FileOffsetStoring: Sendable {
    func cursors() -> [String: FileCursor]
    func set(_ cursor: FileCursor?, for path: String) throws
}

/// Persiste cursores como JSON. Arquivo ausente ou corrompido = estado vazio
/// (re-ingest completa; sem crash).
public final class JSONFileOffsetStore: FileOffsetStoring {
    private let url: URL
    private let lock = NSLock()
    private var cache: [String: FileCursor]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: FileCursor].self, from: data) {
            self.cache = decoded
        } else {
            self.cache = [:]
        }
    }

    public func cursors() -> [String: FileCursor] {
        lock.lock(); defer { lock.unlock() }
        return cache
    }

    public func set(_ cursor: FileCursor?, for path: String) throws {
        lock.lock()
        if let cursor { cache[path] = cursor } else { cache.removeValue(forKey: path) }
        let snapshot = cache
        lock.unlock()
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Rodar e verificar verde**

Run: `swift test --filter FileOffsetStoreTests 2>&1 | tail -3`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): cursor store JSON com tolerância a corrupção"
```

---

### Task 5: TranscriptIngester (ingest incremental)

**Files:**
- Create: `Sources/TokenBarCore/Ingest/TranscriptIngester.swift`
- Test: `Tests/TokenBarCoreTests/TranscriptIngesterTests.swift`

**Interfaces:**
- Consumes: `FileCursor` (Task 4), `UsageEvent` (Task 2); parser injetado `(String, Date) -> UsageEvent?` (Task 3 fornece a closure real).
- Produces:

```swift
public struct FileIngestResult: Sendable, Equatable {
    public let path: String
    public let newEvents: [UsageEvent]
    public let cursor: FileCursor        // novo cursor
    public let resetToZero: Bool         // arquivo encolheu → re-leitura total
}

public struct TranscriptIngester: Sendable {
    public init(parseLine: @escaping @Sendable (String, Date) -> UsageEvent?)
    // Varre `directory` recursivamente por *.jsonl; 1 resultado por arquivo alterado.
    // makeEvent deixa o caller injetar account/project (o ingester não conhece providers).
    public func ingestChangedFiles(
        under directory: URL,
        cursors: [String: FileCursor],
        makeEvent: (UsageEvent, String) -> UsageEvent
    ) throws -> [FileIngestResult]
}
```

Regras (validadas nos testes): lê só bytes a partir de `cursor.offset`; linha final sem `\n` não é consumida; `size < offset` → `resetToZero` + re-leitura do zero; arquivo com `size == offset` não é retornado.

- [ ] **Step 1: Escrever testes que falham**

`Tests/TokenBarCoreTests/TranscriptIngesterTests.swift`:

```swift
import XCTest
@testable import TokenBarCore

final class TranscriptIngesterTests: XCTestCase {
    private var dir: URL!
    private let fixedDate = Date(timeIntervalSince1970: 1_788_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Parser de teste: linha "T<tokens>" vira evento de output=<tokens>; qualquer outra coisa → nil.
    private func countingParser(_ line: String, _ mod: Date) -> UsageEvent? {
        guard line.hasPrefix("T"), let n = Int64(line.dropFirst()) else { return nil }
        return UsageEvent(
            ts: mod, provider: .claude,
            account: AccountID(provider: .claude, key: "local"), model: nil,
            inputTokens: 0, outputTokens: n, cacheReadTokens: 0, cacheWriteTokens: 0, project: nil
        )
    }

    private func identityTag(_ e: UsageEvent, _ path: String) -> UsageEvent { e }

    private func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    func testFirstIngestReadsWholeFile() throws {
        try "T10\nT20\nT30\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].newEvents.map(\.outputTokens), [10, 20, 30])
        XCTAssertEqual(Int(results[0].cursor.offset), 12, "3 linhas de 4 bytes, tudo consumido")
        XCTAssertFalse(results[0].resetToZero)
    }

    func testSecondIngestReadsOnlyAppend() throws {
        try "T10\nT20\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let first = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        let sizeAfterFirst = try FileManager.default
            .attributesOfItem(atPath: path("a.jsonl"))[.size] as! Int64

        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("a.jsonl"))
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("T70\n".utf8))
        try handle.close()

        let second = try ingester.ingestChangedFiles(
            under: dir,
            cursors: [path("a.jsonl"): first[0].cursor],
            makeEvent: identityTag
        )
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].newEvents.map(\.outputTokens), [70])
        XCTAssertEqual(Int(second[0].cursor.offset), Int(sizeAfterFirst) + 4)
    }

    func testIncompleteTrailingLineIsNotConsumed() throws {
        try "T10\nT2".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        XCTAssertEqual(results[0].newEvents.map(\.outputTokens), [10], "'T2' sem \\n não vira evento")
        XCTAssertEqual(Int(results[0].cursor.offset), 4, "cursor para depois do 1º \\n")
    }

    func testTruncatedFileResetsToZero() throws {
        try "T10\nT20\nT30\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let first = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        XCTAssertTrue(first[0].cursor.offset > 0)

        try "T99\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let second = try ingester.ingestChangedFiles(
            under: dir,
            cursors: [path("a.jsonl"): first[0].cursor],
            makeEvent: identityTag
        )
        XCTAssertTrue(second[0].resetToZero)
        XCTAssertEqual(second[0].newEvents.map(\.outputTokens), [99])
    }

    func testGarbageLinesAreSkippedButConsumed() throws {
        try "X\nT10\nBROKEN\nT20\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        XCTAssertEqual(results[0].newEvents.map(\.outputTokens), [10, 20])
    }

    func testUnchangedFileIsNotReturned() throws {
        try "T10\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let first = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        let second = try ingester.ingestChangedFiles(
            under: dir,
            cursors: [path("a.jsonl"): first[0].cursor],
            makeEvent: identityTag
        )
        XCTAssertTrue(second.isEmpty)
    }

    func testSubdirectoriesAreScanned() throws {
        let sub = dir.appendingPathComponent("proj-session", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "T10\n".write(to: sub.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        XCTAssertEqual(results.count, 1)
    }

    /// Orçamento spec §7: ingest de 10k eventos < 1 s.
    func testTenThousandEventsUnderOneSecond() throws {
        var big = ""
        big.reserveCapacity(60_000)
        for i in 0..<10_000 { big += "T\(i % 1000)\n" }
        try big.write(to: dir.appendingPathComponent("big.jsonl"), atomically: true, encoding: .utf8)
        let ingester = TranscriptIngester(parseLine: countingParser)
        let start = Date()
        let results = try ingester.ingestChangedFiles(under: dir, cursors: [:], makeEvent: identityTag)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(results[0].newEvents.count, 10_000)
        XCTAssertLessThan(elapsed, 1.0, "ingest de 10k levou \(elapsed)s")
    }
}
```

- [ ] **Step 2: Rodar e verificar falha**

Run: `swift test --filter TranscriptIngesterTests 2>&1 | tail -3`
Expected: FAIL (tipo não existe).

- [ ] **Step 3: Implementar**

`Sources/TokenBarCore/Ingest/TranscriptIngester.swift`:

```swift
import Foundation

public struct FileIngestResult: Sendable, Equatable {
    public let path: String
    public let newEvents: [UsageEvent]
    public let cursor: FileCursor
    public let resetToZero: Bool
}

public struct TranscriptIngester: Sendable {
    private let parseLine: @Sendable (String, Date) -> UsageEvent?

    public init(parseLine: @escaping @Sendable (String, Date) -> UsageEvent?) {
        self.parseLine = parseLine
    }

    public func ingestChangedFiles(
        under directory: URL,
        cursors: [String: FileCursor],
        makeEvent: (UsageEvent, String) -> UsageEvent
    ) throws -> [FileIngestResult] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }

        var results: [FileIngestResult] = []
        for path in try Self.scanJSONL(under: directory) {
            let attrs = try fm.attributesOfItem(atPath: path)
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attrs[.modificationDate] as? Date) ?? Date()
            let previous = cursors[path]?.offset ?? 0

            // Inalterado (nada além do cursor): pula. Encolheu: reset.
            guard size != previous else { continue }
            let startOffset: UInt64 = size < previous ? 0 : previous
            let reset = size < previous

            guard size > startOffset, let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            if startOffset > 0 { try? handle.seek(toOffset: startOffset) }
            let chunk = (try? handle.read(upToCount: Int(size - startOffset))) ?? Data()

            // Só consome até o último \n; cauda parcial fica pro próximo ciclo.
            let consumed: Data
            if let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) {
                consumed = Data(chunk[chunk.startIndex...lastNewline])
            } else {
                consumed = Data()
            }
            if consumed.isEmpty { continue }

            var events: [UsageEvent] = []
            for lineData in consumed.split(separator: UInt8(ascii: "\n")) {
                let line = String(decoding: lineData, as: UTF8.self)
                if let event = parseLine(line, modified) {
                    events.append(makeEvent(event, path))
                }
            }

            results.append(FileIngestResult(
                path: path,
                newEvents: events,
                cursor: FileCursor(offset: startOffset + UInt64(consumed.count)),
                resetToZero: reset
            ))
        }
        return results
    }

    private static func scanJSONL(under directory: URL) throws -> [String] {
        let fm = FileManager.default
        var files: [String] = []
        let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        )
        while let item = enumerator?.nextObject() as? URL {
            let isRegular = (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            if isRegular && item.pathExtension == "jsonl" {
                files.append(item.path)
            }
        }
        return files.sorted()
    }
}
```

- [ ] **Step 4: Rodar e verificar verde**

Run: `swift test --filter TranscriptIngesterTests 2>&1 | tail -3`
Expected: `Executed 8 tests, with 0 failures` (incluindo o de 10k < 1 s).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): ingest incremental de transcripts com cursor e reset"
```

---

### Task 6: TokenLedger (totais de hoje, auto-corretivo)

**Files:**
- Create: `Sources/TokenBarCore/Ingest/TokenLedger.swift`
- Test: `Tests/TokenBarCoreTests/TokenLedgerTests.swift`

**Interfaces:**
- Consumes: `FileIngestResult`, `TokenSums` (Tasks 2 e 5).
- Produces:

```swift
public actor TokenLedger {
    public init(calendar: Calendar)
    public func apply(_ results: [FileIngestResult], now: Date)
    public func todayTotal(now: Date) -> Int64
    public func todayByProvider(now: Date) -> [ProviderID: Int64]
    public func rolloverIfNeeded(now: Date)      // virou o dia → zera e marca rescan
    public var needsFullRescan: Bool             // scheduler consome e faz re-ingest do zero
    public func clearRescanFlag()
}
```

Semântica anti-duplicação: soma de tokens **por arquivo** (só eventos do dia corrente contam); `resetToZero` zera a contribuição do arquivo antes de somar a re-leitura — truncamento se auto-corrige sem duplicar.

- [ ] **Step 1: Escrever testes que falham**

`Tests/TokenBarCoreTests/TokenLedgerTests.swift`:

```swift
import XCTest
@testable import TokenBarCore

final class TokenLedgerTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return c
    }
    private let today = Date(timeIntervalSince1970: 1_788_000_000)          // 2026-09-02 ~09:20 BRT
    private let yesterday = Date(timeIntervalSince1970: 1_788_000_000 - 86_400)

    private func event(_ output: Int64, ts: Date, path: String, provider: ProviderID = .claude) -> FileIngestResult {
        FileIngestResult(
            path: path,
            newEvents: [UsageEvent(
                ts: ts, provider: provider,
                account: AccountID(provider: provider, key: "local"), model: nil,
                inputTokens: 0, outputTokens: output, cacheReadTokens: 0, cacheWriteTokens: 0, project: nil
            )],
            cursor: FileCursor(offset: 100), resetToZero: false
        )
    }

    func testAccumulatesAcrossFilesAndCycles() async {
        let ledger = TokenLedger(calendar: calendar)
        await ledger.apply([event(10, ts: today, path: "/a"), event(20, ts: today, path: "/b")], now: today)
        await ledger.apply([event(5, ts: today, path: "/a")], now: today)
        let byProvider = await ledger.todayByProvider(now: today)
        XCTAssertEqual(byProvider[.claude], 35)
    }

    func testYesterdayEventsDoNotCountForToday() async {
        let ledger = TokenLedger(calendar: calendar)
        await ledger.apply([event(10, ts: yesterday, path: "/a")], now: today)
        let total = await ledger.todayTotal(now: today)
        XCTAssertEqual(total, 0)
    }

    func testTruncationSelfCorrects() async {
        let ledger = TokenLedger(calendar: calendar)
        await ledger.apply([event(10, ts: today, path: "/a")], now: today)
        let correction = FileIngestResult(
            path: "/a",
            newEvents: [UsageEvent(
                ts: today, provider: .claude,
                account: AccountID(provider: .claude, key: "local"), model: nil,
                inputTokens: 0, outputTokens: 3, cacheReadTokens: 0, cacheWriteTokens: 0, project: nil
            )],
            cursor: FileCursor(offset: 3), resetToZero: true
        )
        await ledger.apply([correction], now: today)
        let total = await ledger.todayTotal(now: today)
        XCTAssertEqual(total, 3, "truncamento substitui, não soma")
    }

    func testRolloverClearsTotalsAndFlagsRescan() async {
        let ledger = TokenLedger(calendar: calendar)
        await ledger.apply([event(10, ts: today, path: "/a")], now: today)
        let tomorrow = today.addingTimeInterval(86_400)
        await ledger.rolloverIfNeeded(now: tomorrow)
        let needsRescan = await ledger.needsFullRescan
        XCTAssertTrue(needsRescan)
        let total = await ledger.todayTotal(now: tomorrow)
        XCTAssertEqual(total, 0)
    }

    func testMultiProviderBreakdown() async {
        let ledger = TokenLedger(calendar: calendar)
        await ledger.apply(
            [event(10, ts: today, path: "/a"), event(7, ts: today, path: "/c", provider: .codex)],
            now: today
        )
        let byProvider = await ledger.todayByProvider(now: today)
        XCTAssertEqual(byProvider[.claude], 10)
        XCTAssertEqual(byProvider[.codex], 7)
    }
}
```

- [ ] **Step 2: Rodar e verificar falha**

Run: `swift test --filter TokenLedgerTests 2>&1 | tail -3`
Expected: FAIL.

- [ ] **Step 3: Implementar**

`Sources/TokenBarCore/Ingest/TokenLedger.swift`:

```swift
import Foundation

/// Totais de "hoje" por arquivo, auto-corretivos contra truncamento.
/// actor: chamado pelo ingest loop fora da MainActor.
public actor TokenLedger {
    private struct FileLedger {
        var todaySums: TokenSums
        var day: Date  // startOfDay em que todaySums acumulou
    }

    private let calendar: Calendar
    private var files: [String: FileLedger] = [:]
    private var providerByPath: [String: ProviderID] = [:]
    private var currentDay: Date
    public private(set) var needsFullRescan = false

    public init(calendar: Calendar) {
        self.calendar = calendar
        self.currentDay = calendar.startOfDay(for: Date())
    }

    public func apply(_ results: [FileIngestResult], now: Date) {
        let today = calendar.startOfDay(for: now)
        for result in results {
            var ledger = result.resetToZero
                ? FileLedger(todaySums: .init(), day: today)
                : (files[result.path] ?? FileLedger(todaySums: .init(), day: today))

            var added = TokenSums()
            for event in result.newEvents where calendar.startOfDay(for: event.ts) == today {
                added += TokenSums(
                    input: event.inputTokens, output: event.outputTokens,
                    cacheRead: event.cacheReadTokens, cacheWrite: event.cacheWriteTokens
                )
            }
            ledger.todaySums += added
            ledger.day = today
            files[result.path] = ledger

            if let provider = result.newEvents.first?.provider {
                providerByPath[result.path] = provider
            }
        }
    }

    public func todayTotal(now: Date) -> Int64 {
        todayByProvider(now: now).values.reduce(0, +)
    }

    public func todayByProvider(now: Date) -> [ProviderID: Int64] {
        let today = calendar.startOfDay(for: now)
        var byProvider: [ProviderID: Int64] = [:]
        for (path, ledger) in files where ledger.day == today {
            let provider = providerByPath[path] ?? .claude
            byProvider[provider, default: 0] += ledger.todaySums.total
        }
        return byProvider.filter { $0.value > 0 }
    }

    public func rolloverIfNeeded(now: Date) {
        let today = calendar.startOfDay(for: now)
        guard today != currentDay else { return }
        currentDay = today
        files = [:]
        needsFullRescan = true
    }

    public func clearRescanFlag() {
        needsFullRescan = false
    }
}
```

- [ ] **Step 4: Rodar e verificar verde**

Run: `swift test --filter TokenLedgerTests 2>&1 | tail -3`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): ledger de tokens do dia auto-corretivo e multi-provider"
```

---

### Task 7: MenuBarContent + SnapshotStore (formatação e render gate)

**Files:**
- Create: `Sources/TokenBarUI/MenuBarContent.swift`
- Create: `Sources/TokenBarUI/SnapshotStore.swift`
- Test: `Tests/TokenBarUITests/MenuBarContentTests.swift`

**Interfaces:**
- Consumes: `ProviderID` (Task 2).
- Produces:

```swift
public func abbrevTokens(_ n: Int64) -> String
// 0→"0"; 999→"999"; 1_000→"1.0k"; 1_234→"1.2k"; 12_345→"12.3k"; 2_300_000→"2.3M"; 1_200_000_000→"1.2G"

public struct MenuBarContent: Equatable, Sendable {
    public let todayTokens: [ProviderID: Int64]
    public static let empty: MenuBarContent
    public func displayString() -> String
    // [:] → "TB"; [.claude: 12_400] → "C:12.4k"; dois providers → "C:12.4k O:999"
}

@MainActor @Observable public final class SnapshotStore {
    public private(set) var menuBarText: String   // muda só quando a string exibida muda
    public func apply(_ content: MenuBarContent)
}
```

- [ ] **Step 1: Escrever testes que falham**

`Tests/TokenBarUITests/MenuBarContentTests.swift`:

```swift
import XCTest
import Observation
import TokenBarCore
@testable import TokenBarUI

final class MenuBarContentTests: XCTestCase {
    func testAbbrevTokens() {
        XCTAssertEqual(abbrevTokens(0), "0")
        XCTAssertEqual(abbrevTokens(999), "999")
        XCTAssertEqual(abbrevTokens(1_000), "1.0k")
        XCTAssertEqual(abbrevTokens(1_234), "1.2k")
        XCTAssertEqual(abbrevTokens(12_345), "12.3k")
        XCTAssertEqual(abbrevTokens(2_300_000), "2.3M")
        XCTAssertEqual(abbrevTokens(1_200_000_000), "1.2G")
    }

    func testEmptyContentShowsPlaceholder() {
        XCTAssertEqual(MenuBarContent.empty.displayString(), "TB")
    }

    func testSingleProviderFormat() {
        XCTAssertEqual(MenuBarContent(todayTokens: [.claude: 12_400]).displayString(), "C:12.4k")
    }

    func testMultipleProvidersFormat() {
        let content = MenuBarContent(todayTokens: [.claude: 12_400, .codex: 999])
        XCTAssertEqual(content.displayString(), "C:12.4k O:999")
    }

    @MainActor
    func testRenderGateSkipsEqualContent() {
        let store = SnapshotStore()
        let content = MenuBarContent(todayTokens: [.claude: 12_400])
        store.apply(content)

        var changes = 0
        withObservationTracking {
            _ = store.menuBarText
        } onChange: { changes += 1 }

        store.apply(content)                                         // igual → NÃO marca
        store.apply(MenuBarContent(todayTokens: [.claude: 12_401]))  // diferente → marca 1×
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(store.menuBarText, "C:12.4k")
    }
}
```

- [ ] **Step 2: Rodar e verificar falha**

Run: `swift test --filter MenuBarContentTests 2>&1 | tail -3`
Expected: FAIL.

- [ ] **Step 3: Implementar**

`Sources/TokenBarUI/MenuBarContent.swift`:

```swift
import TokenBarCore

public func abbrevTokens(_ n: Int64) -> String {
    switch n {
    case ..<1_000:
        return String(n)
    case ..<1_000_000:
        return String(format: "%.1fk", Double(n) / 1_000)
    case ..<1_000_000_000:
        return String(format: "%.1fM", Double(n) / 1_000_000)
    default:
        return String(format: "%.1fG", Double(n) / 1_000_000_000)
    }
}

public struct MenuBarContent: Equatable, Sendable {
    public let todayTokens: [ProviderID: Int64]

    public static let empty = MenuBarContent(todayTokens: [:])

    public init(todayTokens: [ProviderID: Int64]) {
        self.todayTokens = todayTokens
    }

    public func displayString() -> String {
        guard !todayTokens.isEmpty else { return "TB" }
        return todayTokens
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue.prefix(1).uppercased()):\(abbrevTokens($0.value))" }
            .joined(separator: " ")
    }
}
```

`Sources/TokenBarUI/SnapshotStore.swift`:

```swift
import Observation
import TokenBarCore

/// Fonte única de verdade da UI. Render gate: `menuBarText` só publica
/// (e re-renderiza o item de menu) quando a string exibida de fato muda.
@MainActor
@Observable
public final class SnapshotStore {
    private var content: MenuBarContent = .empty

    public private(set) var menuBarText: String = "TB"

    public init() {}

    public func apply(_ newContent: MenuBarContent) {
        guard newContent != content else { return }
        content = newContent
        menuBarText = newContent.displayString()
    }
}
```

- [ ] **Step 4: Rodar e verificar verde**

Run: `swift test --filter MenuBarContentTests 2>&1 | tail -3`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(ui): menu bar content com abbrev e render gate"
```

---

### Task 8: ClaudeProvider + TranscriptLocator

**Files:**
- Create: `Sources/TokenBarProviders/Claude/ClaudeTranscriptLocator.swift`
- Create: `Sources/TokenBarProviders/Claude/ClaudeProvider.swift`
- Test: `Tests/TokenBarProvidersTests/ClaudeProviderTests.swift`

**Interfaces:**
- Consumes: `TranscriptIngester`, `FileOffsetStoring` (Tasks 4–5), `ClaudeLineParser` (Task 3), domínio (Task 2).
- Produces:

```swift
public struct ClaudeTranscriptLocator: Sendable {
    public let projectsDirectory: URL
    public init(projectsDirectory: URL)
    public static func resolve(environment: [String: String], home: URL) -> ClaudeTranscriptLocator
    // Ordem: TOKENBAR_CLAUDE_DIR → ~/.claude/projects (spec §5.1)
    public static func resolve() -> ClaudeTranscriptLocator
}

public struct IngestOutcome: Sendable, Equatable {
    public let eventsApplied: Int
    public let providerTotals: [ProviderID: Int64]
}

public final class ClaudeProvider: Sendable {
    public init(projectsDirectory: URL, offsetStore: any FileOffsetStoring, calendar: Calendar)
    public var account: AccountID { AccountID(provider: .claude, key: "local") }
    public func ingestOnce(now: Date) async throws -> IngestOutcome
}
```

Modo local puro: sem rede, sem credenciais (spec §5.1 regra 2). O provider é o dono do ledger e dos cursores entre ciclos.

- [ ] **Step 1: Escrever testes que falham**

`Tests/TokenBarProvidersTests/ClaudeProviderTests.swift`:

```swift
import XCTest
import TokenBarCore
@testable import TokenBarProviders

final class InMemoryOffsetStore: FileOffsetStoring, @unchecked Sendable {
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

final class ClaudeProviderTests: XCTestCase {
    private var dir: URL!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }
    private let now = Date(timeIntervalSince1970: 1_788_000_000)  // fixo: determinístico

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudeprov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testResolvePrefersEnvironmentOverride() {
        let locator = ClaudeTranscriptLocator.resolve(
            environment: ["TOKENBAR_CLAUDE_DIR": "/tmp/corpus"],
            home: URL(filePath: "/Users/fake")
        )
        XCTAssertEqual(locator.projectsDirectory.path, "/tmp/corpus")
    }

    func testResolveFallsBackToHomeClaude() {
        let locator = ClaudeTranscriptLocator.resolve(environment: [:], home: URL(filePath: "/Users/fake"))
        XCTAssertEqual(locator.projectsDirectory.path, "/Users/fake/.claude/projects")
    }

    private func writeFixture() throws {
        let session = dir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let line1 = #"{"type":"assistant","timestamp":"\#(Self.isoAt(hoursAgo: 1))","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":200}}}"#
        let line2 = #"{"type":"assistant","timestamp":"\#(Self.isoAt(hoursAgo: 0))","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":3000}}}"#
        try (line1 + "\n" + line2 + "\n")
            .write(to: session.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
    }

    private static func isoAt(hoursAgo: Int) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: 1_788_000_000 - Double(hoursAgo) * 3_600))
    }

    func testIngestOnceCountsTokensFromRealFormatFixture() async throws {
        try writeFixture()
        let provider = ClaudeProvider(projectsDirectory: dir, offsetStore: InMemoryOffsetStore(), calendar: calendar)
        let outcome = try await provider.ingestOnce(now: now)
        XCTAssertEqual(outcome.eventsApplied, 2)
        XCTAssertEqual(outcome.providerTotals[.claude], 100 + 200 + 10 + 20 + 3000)
    }

    func testIngestTwiceDoesNotDuplicate() async throws {
        let line = #"{"type":"assistant","timestamp":"\#(Self.isoAt(hoursAgo: 0))","message":{"usage":{"input_tokens":50,"output_tokens":50}}}"#
        try (line + "\n").write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

        let provider = ClaudeProvider(projectsDirectory: dir, offsetStore: InMemoryOffsetStore(), calendar: calendar)
        let first = try await provider.ingestOnce(now: now)
        let second = try await provider.ingestOnce(now: now)

        XCTAssertEqual(first.providerTotals[.claude], 100)
        XCTAssertEqual(second.eventsApplied, 0)
        XCTAssertEqual(second.providerTotals[.claude], 100, "segunda passada mantém total")
    }

    func testMissingDirectoryYieldsZero() async throws {
        let provider = ClaudeProvider(
            projectsDirectory: URL(filePath: "/nonexistent-\(UUID().uuidString)"),
            offsetStore: InMemoryOffsetStore(),
            calendar: calendar
        )
        let outcome = try await provider.ingestOnce(now: now)
        XCTAssertEqual(outcome.eventsApplied, 0)
        XCTAssertEqual(outcome.providerTotals[.claude] ?? 0, 0)
    }
}
```

> Os fixtures usam timestamps derivados de `now` fixo (1h atrás e agora) com o timezone local do teste — assim "hoje" do ledger coincide com os eventos, sem depender da hora de execução.

- [ ] **Step 2: Rodar e verificar falha**

Run: `swift test --filter ClaudeProviderTests 2>&1 | tail -3`
Expected: FAIL.

- [ ] **Step 3: Implementar**

`Sources/TokenBarProviders/Claude/ClaudeTranscriptLocator.swift`:

```swift
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
```

`Sources/TokenBarProviders/Claude/ClaudeProvider.swift`:

```swift
import Foundation
import TokenBarCore

public struct IngestOutcome: Sendable, Equatable {
    public let eventsApplied: Int
    public let providerTotals: [ProviderID: Int64]
}

/// Provider do Claude Code em modo local (F1): lê transcripts JSONL de
/// `projectsDirectory`, mantém ledger do dia e cursores por arquivo.
/// Sem rede, sem credenciais.
public final class ClaudeProvider: Sendable {
    public var account: AccountID { AccountID(provider: .claude, key: "local") }

    private let projectsDirectory: URL
    private let offsetStore: any FileOffsetStoring
    private let ledger: TokenLedger
    private let ingester: TranscriptIngester

    public init(projectsDirectory: URL, offsetStore: any FileOffsetStoring, calendar: Calendar) {
        self.projectsDirectory = projectsDirectory
        self.offsetStore = offsetStore
        self.ledger = TokenLedger(calendar: calendar)
        let account = AccountID(provider: .claude, key: "local")
        self.ingester = TranscriptIngester { line, modified in
            ClaudeLineParser(account: account, project: nil)
                .parse(line: line, fileModificationDate: modified)
        }
    }

    /// Um ciclo completo: rollover → varre → parseia → aplica no ledger → persiste cursores.
    public func ingestOnce(now: Date) async throws -> IngestOutcome {
        await ledger.rolloverIfNeeded(now: now)

        // Virada de dia: re-ingest completa (cursores zerados).
        if await ledger.needsFullRescan {
            for path in offsetStore.cursors().keys {
                try? offsetStore.set(nil, for: path)
            }
            await ledger.clearRescanFlag()
        }

        let results = try ingester.ingestChangedFiles(
            under: projectsDirectory,
            cursors: offsetStore.cursors(),
            makeEvent: { [account] event, path in
                var e = event
                e.account = account
                e.project = e.project ?? URL(filePath: path).deletingLastPathComponent().lastPathComponent
                return e
            }
        )
        let applied = results.reduce(0) { $0 + $1.newEvents.count }
        await ledger.apply(results, now: now)
        for result in results {
            try? offsetStore.set(result.cursor, for: result.path)
        }
        let totals = await ledger.todayByProvider(now: now)
        return IngestOutcome(eventsApplied: applied, providerTotals: totals)
    }
}
```

- [ ] **Step 4: Rodar e verificar verde**

Run: `swift test --filter ClaudeProviderTests 2>&1 | tail -3`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(providers): ClaudeProvider modo local com ingest incremental"
```

---

### Task 9: Debouncer + TranscriptWatcher (FSEvents, debounce 3 s)

**Files:**
- Create: `Sources/TokenBarCore/Watcher/TranscriptWatcher.swift`
- Test: `Tests/TokenBarCoreTests/DebounceTests.swift`

**Interfaces:**
- Produces:

```swift
public actor Debouncer<ClockType: Clock> where ClockType.Duration == Duration {
    public init(quiesce: Duration, clock: ClockType)
    public func touch()            // reinicia a janela de quiescência
    public func wait() async       // retorna `quiesce` depois do último touch
}

public struct PathEvent: Sendable, Equatable { public let path: String }

public final class TranscriptWatcher: @unchecked Sendable {
    public init(directory: URL, latency: Double = 0.5)
    public func events() -> AsyncStream<PathEvent>   // chamar ANTES de start()
    public func start()
    public func stop()
}
```

O `Debouncer` é genérico no clock para teste com clock virtual (tempo 100% coerente entre `now` e `sleep`). O watcher real é exercitado no E2E (Task 14).

- [ ] **Step 1: Escrever testes que falham**

`Tests/TokenBarCoreTests/DebounceTests.swift`:

```swift
import XCTest
@testable import TokenBarCore

/// Clock virtual: sleep registra waiter; advance(by:) desperta os vencidos.
final class VirtualClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant

    private let lock = NSLock()
    private var nowValue: Instant
    private var waiters: [(deadline: Instant, continuation: CheckedContinuation<Void, Error>)] = []

    init(start: Instant = .now) {
        nowValue = start
    }

    var now: Instant {
        lock.lock(); defer { lock.unlock() }
        return nowValue
    }

    func sleep(forDuration duration: Instant.Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            waiters.append((nowValue.advanced(by: duration), continuation))
            lock.unlock()
        }
    }

    /// Avança o relógio virtual e desperta waiters cujo deadline passou.
    func advance(by duration: Instant.Duration) {
        lock.lock()
        nowValue = nowValue.advanced(by: duration)
        let due = waiters.filter { $0.deadline <= nowValue }
        waiters.removeAll { $0.deadline <= nowValue }
        lock.unlock()
        for waiter in due { waiter.continuation.resume(returning: ()) }
    }
}

final class DebounceTests: XCTestCase {
    func testWaitReturnsOnlyAfterQuiesceWindow() async throws {
        let clock = VirtualClock()
        let debouncer = Debouncer(quiesce: .seconds(3), clock: clock)

        let task = Task { await debouncer.wait() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(task.isFinished, false, "janela intacta: wait bloqueia")

        await debouncer.touch()
        await clock.advance(by: .seconds(2))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(task.isFinished, false, "passou 2 s de 3 s: ainda bloqueia")

        await clock.advance(by: .seconds(1))
        _ = await task.value  // chegou aqui = retornou após quiescência
    }

    func testTouchResetsWindow() async throws {
        let clock = VirtualClock()
        let debouncer = Debouncer(quiesce: .seconds(3), clock: clock)

        let task = Task { await debouncer.wait() }
        try await Task.sleep(for: .milliseconds(50))
        await debouncer.touch()
        await clock.advance(by: .seconds(2))
        await debouncer.touch()                    // reinicia: deadline vai a +3 s deste ponto
        await clock.advance(by: .seconds(2))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(task.isFinished, false, "touch reiniciou a janela: 4 s totais < 3 s do último touch")

        await clock.advance(by: .seconds(1))
        _ = await task.value
    }
}
```

- [ ] **Step 2: Rodar e verificar falha**

Run: `swift test --filter DebounceTests 2>&1 | tail -3`
Expected: FAIL.

- [ ] **Step 3: Implementar**

`Sources/TokenBarCore/Watcher/TranscriptWatcher.swift`:

```swift
import Foundation
@preconcurrency import CoreServices

public struct PathEvent: Sendable, Equatable {
    public let path: String
    public init(path: String) { self.path = path }
}

/// Janela de quiescência: wait() retorna `quiesce` após o último touch().
/// Genérico no clock para tornar o tempo virtual coerente em testes.
public actor Debouncer<ClockType: Clock> where ClockType.Duration == Duration {
    private let quiesce: Duration
    private let clock: ClockType
    private var lastTouch: ClockType.Instant

    public init(quiesce: Duration, clock: ClockType) {
        self.quiesce = quiesce
        self.clock = clock
        self.lastTouch = clock.now
    }

    public func touch() {
        lastTouch = clock.now
    }

    public func wait() async {
        while true {
            let elapsed = lastTouch.duration(to: clock.now)
            if elapsed >= quiesce { return }
            try? await clock.sleep(for: quiesce - elapsed)
            // acordou (deadline ou advance): recalcular — touch pode ter reiniciado a janela
        }
    }
}

/// Wrapper FSEvents: emite paths alterados sob o diretório.
public final class TranscriptWatcher: @unchecked Sendable {
    private let directory: URL
    private let latency: CFTimeInterval
    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private nonisolated(unsafe) var continuation: AsyncStream<PathEvent>.Continuation?

    public init(directory: URL, latency: Double = 0.5) {
        self.directory = directory
        self.latency = latency
    }

    /// Registrar o consumidor ANTES de start() para não perder eventos iniciais.
    public func events() -> AsyncStream<PathEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, let paths, count > 0 else { return }
            let watcher = Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
            let found = unsafeBitCast(paths, to: NSArray.self) as! [String]
            for path in found.prefix(Int(count)) {
                watcher.continuation?.yield(PathEvent(path: path))
            }
        }
        guard let streamRef = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            directory.path as CFString,
            FSEventStreamEventId(kFSEventStreamSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        stream = streamRef
        FSEventStreamScheduleWithRunLoop(streamRef, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(streamRef)
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        continuation?.finish()
        continuation = nil
    }

    deinit { stop() }
}
```

> **Atenção à ordem no consumidor (AppState, Task 10):** `let events = watcher.events()` **antes** de `watcher.start()`. O callback do FSEvents roda na main runloop; `AsyncStream.Continuation.yield` é thread-safe.

- [ ] **Step 4: Rodar e verificar verde**

Run: `swift test --filter DebounceTests 2>&1 | tail -3`
Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): FSEvents watcher + debouncer de quiescência com clock genérico"
```

---

### Task 10: Wiring do app (MenuBarExtra + ingest loop + heartbeat E2E)

**Files:**
- Modify: `Sources/tokenbar/TokenBarApp.swift` (substitui stub inteiro)
- Create: `Sources/tokenbar/AppState.swift`
- Create: `Sources/tokenbar/E2EHeartbeat.swift`

**Interfaces:**
- Consumes: tudo anterior.
- Produces: app UI rodando; `E2EHeartbeat.write(menuBarText:totals:directory:)`; `AppState.forceIngest()`.

- [ ] **Step 1: Implementar E2EHeartbeat**

`Sources/tokenbar/E2EHeartbeat.swift`:

```swift
import Foundation
import TokenBarCore

/// Afördança de teste E2E: escreve estado vivo só quando TOKENBAR_E2E_DIR está setado.
/// Conteúdo: somas e string de exibição — nunca paths nem conteúdo de transcript.
enum E2EHeartbeat {
    static func write(menuBarText: String, totals: [ProviderID: Int64], directory: URL) {
        let payload: [String: Any] = [
            "menuBarText": menuBarText,
            "todayTokens": totals.mapValues { $0 },
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }
}
```

- [ ] **Step 2: Implementar AppState**

`Sources/tokenbar/AppState.swift`:

```swift
import Foundation
import TokenBarCore
import TokenBarProviders
import TokenBarUI

@MainActor
final class AppState {
    let store = SnapshotStore()

    private let provider: ClaudeProvider
    private let watcher: TranscriptWatcher
    private let debouncer: Debouncer<ContinuousClock>
    private var loopTask: Task<Void, Never>?
    private let e2eDir: URL?

    init() {
        let env = ProcessInfo.processInfo.environment
        let locator = ClaudeTranscriptLocator.resolve(environment: env, home: URL(filePath: NSHomeDirectory()))
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        provider = ClaudeProvider(
            projectsDirectory: locator.projectsDirectory,
            offsetStore: JSONFileOffsetStore(url: supportDir.appendingPathComponent("cursors.json")),
            calendar: .current
        )
        watcher = TranscriptWatcher(directory: locator.projectsDirectory)
        debouncer = Debouncer(quiesce: .seconds(3), clock: ContinuousClock())
        e2eDir = env["TOKENBAR_E2E_DIR"].map { URL(filePath: $0) }
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task.detached { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        watcher.stop()
        loopTask?.cancel()
        loopTask = nil
    }

    func forceIngest() async {
        await ingestNow()
    }

    private func ingestNow() async {
        let outcome = (try? await provider.ingestOnce(now: Date())) ??
            IngestOutcome(eventsApplied: 0, providerTotals: [:])
        let content = MenuBarContent(todayTokens: outcome.providerTotals)
        store.apply(content)
        if let e2eDir {
            E2EHeartbeat.write(menuBarText: store.menuBarText, totals: outcome.providerTotals, directory: e2eDir)
        }
    }

    /// Ciclo F1: subscribe nos eventos ANTES de iniciar o watcher; primeiro ingest
    /// imediato; depois FSEvents → debounce 3 s; fallback: poll de 15 min caso o
    /// volume não suporte FSEvents. (Scheduler adaptativo de rede completo = F2.)
    private func runLoop() async {
        let events = watcher.events()
        watcher.start()
        await ingestNow()

        let fallback = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))
                await self?.ingestNow()
            }
        }
        defer { fallback.cancel() }

        for await _ in events {
            await debouncer.touch()
            await debouncer.wait()
            if Task.isCancelled { break }
            await ingestNow()
        }
    }
}
```

- [ ] **Step 3: Implementar TokenBarApp (substitui o stub inteiro de TokenBarApp.swift)**

`Sources/tokenbar/TokenBarApp.swift`:

```swift
import SwiftUI
import TokenBarUI

@main
struct TokenBarApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            Text("TokenBar F1 — local mode")
            Divider()
            Button("Refresh now") {
                Task { await appState.forceIngest() }
            }
            Divider()
            Button("Quit TokenBar") {
                appState.stop()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Text(appState.store.menuBarText)
        }
    }
}
```

> O dispatcher de subcomandos (`selfcheck`) entra na Task 12, trocando o `@main` por um enum dispatcher. Na Task 10, `@main struct TokenBarApp: App` direto.

- [ ] **Step 4: Build e smoke manual**

Run:
```bash
swift build 2>&1 | tail -5
TOKENBAR_CLAUDE_DIR=/tmp TOKENBAR_E2E_DIR=/tmp/tb-state .build/debug/tokenbar &
APP_PID=$!; sleep 3; cat /tmp/tb-state/state.json 2>/dev/null; kill $APP_PID
```
Expected: build OK; `state.json` existe com `menuBarText` (`"TB"` se /tmp não tem jsonl). Corrija erros de strict concurrency conforme o compilador (sem `@unchecked` além dos previstos no watcher).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(app): wiring MenuBarExtra + ingest loop + heartbeat E2E"
```

---

### Task 11: genfixtures (corpus sintético com totais conhecidos)

**Files:**
- Modify: `Sources/genfixtures/GenFixtures.swift` (substitui stub)

**Interfaces:**
- Produces (CLI):

```
genfixtures --out DIR --sessions 5 --lines 200 --seed 42 [--poison]
# Escreve DIR/session-<n>/<uuid>.jsonl com linhas no formato real de transcript.
# Timestamps espalhados nas últimas 24 h (parte cai em "ontem" — proposital).
# Imprime em stdout: {"cacheRead":N,"cacheWrite":N,"events":N,"files":N,"input":N,"output":N}
# --poison injeta linhas inválidas (JSON truncado, binário) que NÃO alteram os totais.
```

- [ ] **Step 1: Implementar**

`Sources/genfixtures/GenFixtures.swift`:

```swift
import Foundation

struct SeededRandom: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }
}

@main
struct GenFixtures {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("genfixtures error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        var out = URL(filePath: "corpus")
        var sessions = 5
        var lines = 200
        var seed: UInt64 = 42
        var poison = false

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--out": out = URL(filePath: args[i + 1]); i += 2
            case "--sessions": sessions = Int(args[i + 1])!; i += 2
            case "--lines": lines = Int(args[i + 1])!; i += 2
            case "--seed": seed = UInt64(args[i + 1])!; i += 2
            case "--poison": poison = true; i += 1
            default: i += 1
            }
        }

        var rng = SeededRandom(seed: seed)
        let fm = FileManager.default
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        var input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0
        var events = 0, fileCount = 0
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for s in 0..<sessions {
            let dir = out.appendingPathComponent("session-\(s)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
            var body = ""
            body.reserveCapacity(lines * 240)
            for _ in 0..<lines {
                let ts = iso.string(from: now.addingTimeInterval(TimeInterval(-rng.int(0...86_400))))
                let i = Int64(rng.int(0...5_000)), o = Int64(rng.int(0...2_000))
                let cr = Int64(rng.int(0...20_000)), cw = Int64(rng.int(0...1_000))
                input += i; output += o; cacheRead += cr; cacheWrite += cw
                events += 1
                if poison && rng.int(0...20) == 0 {
                    // linha inválida (JSON truncado): não conta nos totais
                    body += "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"message\":{\"usage\":{\"input_tok\n"
                } else {
                    body += #"{"type":"assistant","timestamp":"\#(ts)","cwd":"/tmp/fixture","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":\#(i),"output_tokens":\#(o),"cache_read_input_tokens":\#(cr),"cache_creation_input_tokens":\#(cw)}}}"# + "\n"
                }
                if poison && rng.int(0...40) == 0 { body += "\u{00}\u{01}garbage\n" }
            }
            try body.write(to: file, atomically: true, encoding: .utf8)
            fileCount += 1
        }

        let summary: [String: Any] = [
            "input": input, "output": output, "cacheRead": cacheRead,
            "cacheWrite": cacheWrite, "events": events, "files": fileCount,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
```

> A interpolação `\#(...)` dentro do literal `#"..."#` é sintaxe raw-string do Swift. Confira uma linha gerada contra o `ClaudeLineParser` (o teste da Task 8 usa o mesmo formato).

- [ ] **Step 2: Rodar e validar**

Run:
```bash
swift build && .build/debug/genfixtures --out /tmp/tb-corpus --sessions 2 --lines 50 --seed 42 --poison
head -3 /tmp/tb-corpus/session-0/*.jsonl
```
Expected: JSON de totais impresso; arquivo com linhas válidas + ocasionais inválidas.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(tools): genfixtures com totais conhecidos e modo poison"
```

---

### Task 12: selfcheck (subcomando CLI) + dispatcher

**Files:**
- Create: `Sources/tokenbar/SelfCheck.swift`
- Modify: `Sources/tokenbar/TokenBarApp.swift` (troca `@main` por dispatcher; App continua no arquivo)

**Interfaces:**
- Produces:

```
tokenbar selfcheck [DIR]
# Ingest one-shot sobre DIR (default: locator padrão). Imprime:
# {"eventsApplied":N,"menuBarText":"...","todayTokens":{"claude":N}}
```

- [ ] **Step 1: Implementar SelfCheck**

`Sources/tokenbar/SelfCheck.swift`:

```swift
import Foundation
import TokenBarCore
import TokenBarProviders
import TokenBarUI

enum SelfCheck {
    static func run(arguments: [String]) async throws {
        let dir = arguments.count > 1 ? arguments[1] : nil
        let locator = dir.map { ClaudeTranscriptLocator(projectsDirectory: URL(filePath: $0)) }
            ?? ClaudeTranscriptLocator.resolve()
        let provider = ClaudeProvider(
            projectsDirectory: locator.projectsDirectory,
            offsetStore: SelfCheckOffsetStore(),
            calendar: .current
        )
        let outcome = try await provider.ingestOnce(now: Date())
        let content = MenuBarContent(todayTokens: outcome.providerTotals)
        let payload: [String: Any] = [
            "menuBarText": content.displayString(),
            "todayTokens": outcome.providerTotals.mapValues { $0 },
            "eventsApplied": outcome.eventsApplied,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}

private final class SelfCheckOffsetStore: FileOffsetStoring, @unchecked Sendable {
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
```

- [ ] **Step 2: Trocar o @main por dispatcher (em TokenBarApp.swift)**

Substitua apenas o bloco `@main struct TokenBarApp: App` do topo por (o corpo do App fica igual, sem `@main`):

```swift
@main
enum TokenBarMain {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == "selfcheck" {
            try? await SelfCheck.run(arguments: Array(arguments.dropFirst()))
            return
        }
        TokenBarApp.main()
    }
}

struct TokenBarApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            Text("TokenBar F1 — local mode")
            Divider()
            Button("Refresh now") {
                Task { await appState.forceIngest() }
            }
            Divider()
            Button("Quit TokenBar") {
                appState.stop()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Text(appState.store.menuBarText)
        }
    }
}
```

- [ ] **Step 3: Validar (idempotência determinística)**

Run:
```bash
swift build
rm -rf /tmp/tb-corpus2
.build/debug/genfixtures --out /tmp/tb-corpus2 --sessions 1 --lines 30 --seed 9 --poison
A=$(.build/debug/tokenbar selfcheck /tmp/tb-corpus2)
B=$(.build/debug/tokenbar selfcheck /tmp/tb-corpus2)
echo "$A"; echo "$B"
[ "$A" = "$B" ] && echo "IDEMPOTENTE"
```
Expected: dois JSONs idênticos (`eventsApplied` na 2ª = 0, totais mantidos) e `IDEMPOTENTE`. Determinismo: ambos os runs processam o mesmo corpus no mesmo dia pela mesma pipeline.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(app): subcomando selfcheck com dispatcher de argumentos"
```

---

### Task 13: make-app.sh (bundle assinado ad-hoc, sem Xcode)

**Files:**
- Create: `scripts/make-app.sh`
- Create: `scripts/genicon.swift`

**Interfaces:**
- Produces: `build/TokenBar.app` (LSUIElement, assinatura ad-hoc) — consumido pelo E2E.

- [ ] **Step 1: Escrever genicon.swift** (desenha PNG 1024; icns via sips+iconutil)

```swift
import AppKit

let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSColor.clear.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
let rect = NSRect(x: 64, y: 64, width: size - 128, height: size - 128)
NSColor.systemTeal.setFill()
NSBezierPath(roundedRect: rect, xRadius: 180, yRadius: 180).fill()
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 560, weight: .bold),
    .foregroundColor: NSColor.white,
]
let str = NSAttributedString(string: "T", attributes: attrs)
let bounds = str.boundingRect(with: rect.size, options: .usesLineFragmentOrigin)
str.draw(at: NSPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2))
image.unlockFocus()

let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(filePath: CommandLine.arguments[1]))
```

- [ ] **Step 2: Escrever make-app.sh**

```bash
#!/bin/bash
# Monta TokenBar.app sem Xcode: swift build + bundle manual + codesign ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN=".build/$CONFIG/tokenbar"
APP="build/TokenBar.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/tokenbar"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>tokenbar</string>
  <key>CFBundleIdentifier</key><string>app.tokenbar.TokenBar</string>
  <key>CFBundleName</key><string>TokenBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>TokenBar</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# ícone: PNG → iconset → icns (sips + iconutil: presentes no macOS base, sem Xcode)
swift scripts/genicon.swift build/icon-1024.png
mkdir -p build/TokenBar.iconset
for s in 16 32 64 128 256 512 1024; do
  sips -z $s $s build/icon-1024.png --out "build/TokenBar.iconset/icon_${s}x${s}.png" >/dev/null
done
iconutil -c icns build/TokenBar.iconset -o "$APP/Contents/Resources/TokenBar.icns"
codesign --force --sign - "$APP"
echo "OK: $APP"
```

- [ ] **Step 3: Rodar e validar**

Run: `chmod +x scripts/make-app.sh && ./scripts/make-app.sh && codesign -dv build/TokenBar.app 2>&1 | head -3 && ls build/TokenBar.app/Contents build/TokenBar.app/Contents/Resources`
Expected: `OK: build/TokenBar.app`; `Signature=adhoc`; `Contents` com `MacOS/tokenbar`, `Info.plist`, `Resources/TokenBar.icns`.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "build: make-app.sh bundle ad-hoc sem Xcode + genicon"
```

---

### Task 14: e2e.sh (goal E2E automatizado)

**Files:**
- Create: `scripts/e2e.sh`

**Interfaces:**
- Consumes: `genfixtures`, `make-app.sh`, `tokenbar selfcheck`, heartbeat `state.json`.
- Produces: exit 0/1 + relatório no stdout — prova do **Goal E2E** do header.

- [ ] **Step 1: Escrever e2e.sh**

```bash
#!/bin/bash
# E2E F1: corpus sintético → app real → menu bar correto, live update, orçamento de recursos.
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/tokenbar-e2e.XXXXXX)"
CORPUS="$TMP/corpus"; STATE="$TMP/state"
mkdir -p "$STATE"
FAILURES=0
say() { echo "[e2e] $*"; }
check() {  # check <nome> <condição shell>
  if eval "$2"; then say "PASS: $1"; else say "FAIL: $1"; FAILURES=$((FAILURES+1)); fi
}
json_field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))$2)" "$1" 2>/dev/null || echo MISSING; }

say "TMP=$TMP"

# 1. corpus determinístico (timestamps espalham 24h; totais de "hoje" vêm do selfcheck,
#    que roda a MESMA pipeline do app sobre o MESMO corpus no MESMO dia — comparação exata)
say "gerando corpus"
swift run -c release genfixtures --out "$CORPUS" --sessions 4 --lines 150 --seed 7 --poison

# 2. verdade de referência (fora da UI)
SELFCHECK="$(swift run -c release tokenbar selfcheck "$CORPUS")"
say "selfcheck: $SELFCHECK"
SC_TEXT="$(echo "$SELFCHECK" | python3 -c "import json,sys;print(json.load(sys.stdin)['menuBarText'])")"

# 3. app bundle real com overrides
./scripts/make-app.sh release
TOKENBAR_CLAUDE_DIR="$CORPUS" TOKENBAR_E2E_DIR="$STATE" \
  "build/TokenBar.app/Contents/MacOS/tokenbar" &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null; sleep 0.3; rm -rf "$TMP"' EXIT

# 4. menu bar correto em ≤ 30 s
for i in $(seq 1 30); do
  [ -f "$STATE/state.json" ] && break
  sleep 1
done
check "heartbeat criado em 30s" "[ -f '$STATE/state.json' ]"
APP_TEXT="$(json_field "$STATE/state.json" "['menuBarText']")"
check "menu bar text igual ao selfcheck ('$APP_TEXT' == '$SC_TEXT')" "[ '$APP_TEXT' = '$SC_TEXT' ]"

# 5. live update: append de linha válida → atualiza em ≤ 10 s (Δ +333)
BEFORE_TOTAL="$(json_field "$STATE/state.json" "['todayTokens'].get('claude',0)")"
LINE='{"type":"assistant","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'","message":{"usage":{"input_tokens":111,"output_tokens":222}}}'
echo "$LINE" >> "$(ls "$CORPUS"/session-0/*.jsonl | head -1)"
UPDATED=0
for i in $(seq 1 10); do
  sleep 1
  AFTER_TOTAL="$(json_field "$STATE/state.json" "['todayTokens'].get('claude',0)")"
  if [ "$AFTER_TOTAL" != "MISSING" ] && [ "$AFTER_TOTAL" -ge "$((BEFORE_TOTAL + 333))" ] 2>/dev/null; then
    UPDATED=1; break
  fi
done
check "live update após append (Δ=+333 observado)" "[ '$UPDATED' = '1' ]"

# 6. orçamento de recursos após 60 s ocioso
say "aguardando 60s para medir recursos..."
sleep 60
RSS_KB="$(ps -o rss= -p $APP_PID | tr -d ' ')"
CPU="$(ps -o %cpu= -p $APP_PID | tr -d ' ')"
check "processo vivo (sem crash)" "kill -0 $APP_PID"
check "rss ${RSS_KB:-MISSING}KB ≤ 40960KB" "[ '${RSS_KB:-999999}' -le 40960 ]"
check "cpu ${CPU:-MISSING}% ≤ 0.5%" "python3 -c \"exit(0 if float('${CPU:-99}'.replace(',','.')) <= 0.5 else 1)\""

say "concluído: $FAILURES falha(s)"
[ "$FAILURES" = "0" ] && exit 0 || exit 1
```

> Notas: (a) `ps %cpu` no macOS é média decaindo — após 60 s ocioso deve ficar ≤ 0,5; falso-positivo registrado vai pro QA manual (Task 15, Activity Monitor). (b) Se o live update falhar, suspeito clássico: runloop do FSEvents em app LSUIElement — verificar que `start()` agenda na main runloop e que o app roda o loop de eventos (SwiftUI App lifecycle garante).

- [ ] **Step 2: Rodar E2E completo**

Run: `chmod +x scripts/e2e.sh && ./scripts/e2e.sh`
Expected: 6 PASS, exit 0.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "test(e2e): script end-to-end com orçamento de recursos e live update"
```

---

### Task 15: QA gate (protocolo skill QA DomHubs)

**Files:**
- Create: `docs/qa/f1-qa-report.md`

**Interfaces:**
- Consumes: app F1 completo; produz relatório com evidência por requisito.

- [ ] **Step 1: Suite completa + E2E**

Run:
```bash
swift test 2>&1 | tail -5 && ./scripts/e2e.sh
```
Expected: testes todos verdes; e2e exit 0. **Evidência:** saída integral colada no relatório.

- [ ] **Step 2: Checklist manual com o app rodando (protocolo `skills/qa/SKILL.md` do domhubs-devsquad)**

Itens, cada um com evidência (screenshot ou saída de comando anexada ao relatório):
1. `open build/TokenBar.app` → item aparece na menu bar com `C:<n>` (ou `TB` sem dados)
2. Clique no item → menu com "Refresh now" e "Quit TokenBar" (⌘Q)
3. "Refresh now" responde (heartbeat `updatedAt` avança)
4. Texto da menu bar == `tokenbar selfcheck` sobre `~/.claude/projects` na mesma hora (dados reais; leitura only)
5. Robustez: `TOKENBAR_CLAUDE_DIR=/não-existe` sobe sem crash; corpus `--poison` exibe total consistente (igual ao selfcheck do corpus)
6. Quit encerra sem processo zumbi (`pgrep -fl tokenbar` vazio)

Critério do gate: **nenhum item "não verificado"**.

- [ ] **Step 3: Escrever relatório**

`docs/qa/f1-qa-report.md`: tabela requisito → evidência → status.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "docs(qa): relatório QA F1 com evidências"
```

---

### Task 16: Red Team (protocolo skill Simulador DomHubs)

**Files:**
- Create: `docs/qa/f1-redteam-report.md`
- Create/Modify (achados): correções + testes de regressão nos módulos afetados

**Interfaces:**
- Consumes: app F1 completo; produz achados adversariais com fixes testados.

- [ ] **Step 1: Bateria adversarial (protocolo `skills/simulador/SKILL.md` do domhubs-devsquad; cada caso replicável vira teste automatizado)**

1. **Fuzz do parser**: 1.000 linhas aleatórias (bytes 0x00–0xFF, JSON profundo, unicode hostil, linha de 5 MB, `{"usage":{"input_tokens":1e999}}`) → app não crasha, não loga conteúdo
2. **Corpus gigante**: `genfixtures --out X --sessions 10 --lines 100000` → ingest < 10 s; rss ≤ 40 MB; memória estável em 10 ciclos de ingest consecutivos (comparar rss do 1º e do 10º)
3. **Truncamento concorrente**: loop de 100 iterações alternando append e truncate em arquivo monitorado → sem crash; totais se autocorrigem (ledger cobre em teste unitário; validar no processo real)
4. **Arquivos hostis** no diretório monitorado: symlink para fora, arquivo chmod 000, FIFO nomeado `x.jsonl` → sem crash, sem hang
5. **Offset corrompido**: editar `cursors.json` com `0xFFFFFFFFFFFFFFFF` e valores negativos → re-ingest ou ignora; nunca crash nem loop infinito
6. **Segurança**: `grep -rniE "credentials|auth\.json|keychain|oauth" Sources/` → zero match na F1; `log stream --predicate 'process == "tokenbar"'` durante ingest não mostra conteúdo de transcript; heartbeat contém só somas (sem paths)
7. **Diretório some no meio**: `rm -rf` do corpus monitorado → sem crash; fallback poll assume; recriação do diretório retoma ingest

- [ ] **Step 2: Corrigir achados com teste de regressão**

Achado P1/P2 → teste que falha → fix → teste verde. P3 documentado com justificativa.

- [ ] **Step 3: Relatório e commit**

`docs/qa/f1-redteam-report.md`: caso → resultado → severidade → fix/teste.

```bash
git add -A && git commit -m "test(redteam): bateria adversarial F1 com fixes e regressões"
```

---

### Task 17: Documentação mínima F1 + fechamento

**Files:**
- Create: `README.md`
- Create: `docs/decisoes-f1.md`

- [ ] **Step 1: README.md** (EN; estrutura final da F6 com status F1):

````markdown
# TokenBar

Native macOS menu bar app that keeps your AI coding usage visible — light enough to never think about it.

**Status: F1** — Claude Code local token counting. Full roadmap: `docs/specs/2026-09-02-design.md` (pt-BR).

## Build (no Xcode required)

```bash
swift build && swift test
./scripts/make-app.sh          # → build/TokenBar.app
./scripts/e2e.sh               # full end-to-end incl. resource budget
```

## Privacy

Read-only on your CLI session files. No credentials, no network, no telemetry in F1.
````

- [ ] **Step 2: docs/decisoes-f1.md** — decisões tomadas na implementação, formato do `docs/decisoes/` do domhubs-devsquad (data, contexto, decisão, consequência). Mínimo esperado: semântica de truncamento com substituição (não soma); fallback poll 15 min; heartbeat E2E só com env; cursores em JSON até a F3; ordem subscribe-antes-de-start no watcher.

- [ ] **Step 3: Sanidade final e commit**

Run: `swift test 2>&1 | tail -3 && ./scripts/e2e.sh`
Expected: verde + exit 0.

```bash
git add -A && git commit -m "docs: README F1 e decisões de implementação"
```

---

## Fim do plano F1

Critério de pronto da F1 (spec §12): uso de tokens do dia visível na menu bar ✓ (Tasks 10, 14) · CPU/RAM dentro do orçamento ✓ (Task 14) · testes verdes ✓ (Tasks 1–9, 15) · QA com evidência ✓ (Task 15) · Red Team com fixes ✓ (Task 16) · documentado ✓ (Task 17).

Próximos planos (um por fase, criados quando a fase anterior fechar): F2 Codex+Gemini+scheduler adaptativo+APIs de usage · F3 SQLite+histórico+custo+analytics · F4 alertas+multi-conta · F5 providers extras+trend · F6 polish OSS.
