# TokenBar F2 — Codex + Gemini + Z.ai Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Menu bar mostra limites (%) e tokens dos três providers que o usuário realmente usa — Codex/OpenAI, Gemini CLI e Z.ai (coding plan do ZCode) — com API de usage para Codex/Z.ai, modo local para Gemini, protocolo `UsageProvider` da spec §5 e scheduler adaptativo da §7.

**Architecture:** Extrai o protocolo `UsageProvider` + `UsageSnapshot`/`UsageWindow` (spec §5.2) para Core; camada HTTP própria (timeout 10s, single-flight por provider, base URL injetável p/ testes/E2E); scheduler adaptativo (menu 60s / pressão 30s / ocioso 5min / backoff ×2 teto 30min / pausa em sleep); cada provider = 1 actor com ledger próprio + ingest local herdado da F1; menu bar renderiza múltiplos providers com a tabela de siglas D5.

**Tech Stack:** Como F1 (Swift 6, CLT, zero deps) + URLSession para usage APIs.

**Spec:** `docs/specs/2026-09-02-design.md` (§5 protocolo/matrix, §7 scheduler/orçamento, §12 F2) + `docs/decisoes-f1.md`

## Global Constraints

- Todas as da F1 (macOS 14+, Swift 6 strict, CLT-only, credenciais read-only nunca logadas/persistidas, fixtures sintéticas, `./run-tests.sh` com Swift Testing, E2E por heartbeat).
- **Ruling F2-SCOPE** (controlador, 2026-09-02): F2 = Codex + Gemini + Z.ai (Z.ai puxado de F5 p/ F2 — providers em uso real no usuário). Cursor/OpenRouter/Copilot permanecem F5+.
- **Credenciais**: ler `~/.codex/auth.json` (campo `tokens`), `~/.zcode/v2/credentials.json` (chave `oauth:zai:access_token`) e `~/.gemini/oauth_creds.json` **read-only, em runtime, extraindo só o token em memória**. PROIBIDO: logar, persistir, importar em testes/fixtures, ou imprimir valor (nem truncado). Testes usam tokens fake sintéticos.
- **Rede (spec §5 regras 3–4)**: timeout 10 s; 1 req/provider/ciclo; sem retry imediato (backoff do scheduler); falha de rede/re auth → snapshot anterior mantido + `authState`/timestamp atualizado; NUNCA renovamos OAuth (o CLI dono renova; se o token estiver expirado, marca `.invalid` e segue em modo local).
- **Base URLs injetáveis** p/ testes/E2E: `TOKENBAR_CODEX_API`, `TOKENBAR_ZAI_API` (default: endpoints reais descobertos na Task 1).
- **Degradação**: provider sem credencial ou API falhando opera em modo local (tokens ingeridos, janelas `nil`), badge local na UI — nunca crasha, nunca bloqueia os outros providers.
- M1 (F1): todo caminho de ingest continua serializado por provider (single-flight).
- Saída do menu bar (D5): siglas {claude: C, codex: X, gemini: G, zai: Z, cursor: U, openrouter: O, copilot: P}; formato `X:62% G:12.4k` — **% quando o provider tem janela de limite (API), tokens quando só local**.

**Goal E2E (Task 8 valida):** com credenciais fake + mock server local (via overrides de base URL), o app exibe `X:<n>% Z:<m>% C/G:<tokens>` para 3 providers, atualiza com backoff em erro 500 (sem crash, sem retry storm), e degrada para local quando o mock cai — tudo medido por heartbeat v2 + orçamento de recursos da F1.

---

### Task 1: Descoberta de fontes — doc de referência (spike)

**Files:**
- Create: `docs/specs/f2-data-sources.md`

**Interfaces:**
- Produces: documento de referência que Tasks 3–5 consomem, com, POR PROVIDER:
  1. **Codex usage API**: endpoint exato (fonte: CodexBar `Sources/CodexBarCore/Providers/` — fetcher do Codex; expectativa inicial: `https://chatgpt.com/backend-api/wham/usage` com `Authorization: Bearer <access_token>` do `~/.codex/auth.json` → `tokens.access_token`), headers obrigatórios, shape da resposta (janelas primary/secondary, weekly, resets), e schema local dos `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (como contar tokens por evento — primeira linha é meta; descobrir o evento com `token_count`).
  2. **Z.ai coding plan**: endpoint(s) no plugin `Sources/CodexBarCore/Resources/Plugins/zai.js` e/ou `Providers/Zai/` (região: z.ai vs bigmodel.cn), auth header, shape (limites do plano, janela, resets).
  3. **Gemini local**: schema dos arquivos de sessão sob `~/.gemini/tmp/<projeto>/` (descobrir formato real; sem API de quota — modo local).
  4. Matriz de riscos por fonte (o que muda se o endpoint mudar).

**Método:** ler fontes do CodexBar (MIT) via raw.githubusercontent + inspecionar schemas locais na máquina (jq em `keys`/estrutura — NUNCA imprimir valores de token; NUNCA copiar conteúdo real p/ o doc — exemplos SEMPRE sintéticos).

- [ ] **Step 1:** Coletar e documentar (acima). Cada endpoint com: URL, método, headers, shape sintético de resposta, campo→campo do mapeamento p/ `UsageSnapshot`.
- [ ] **Step 2:** Commit `docs: fontes de dados F2 (Codex/Z.ai/Gemini) — referência de endpoints`
- Report: `.superpowers` workspace `task-1-report.md` com resumo dos endpoints achados.

---

### Task 2: Protocolo UsageProvider + domínio de janelas

**Files:**
- Create: `Sources/TokenBarCore/Providers/UsageProvider.swift` (protocolo + ProviderCapabilities)
- Create: `Sources/TokenBarCore/Domain/UsageSnapshot.swift` (UsageSnapshot, UsageWindow, WindowKind, CreditsInfo, AuthState, DataSource — spec §5.2)
- Create: `Sources/TokenBarCore/Providers/ProviderRegistry.swift`
- Modify: `Sources/TokenBarProviders/Claude/ClaudeProvider.swift` (aderir ao protocolo — `ingestLocal` passa a ser o método do protocolo; manter comportamento F1)
- Test: `Tests/TokenBarCoreTests/ProviderProtocolTests.swift`

**Interfaces (spec §5.2 verbatim):**
```swift
public enum WindowKind: String, Sendable, Codable, CaseIterable { case session, weekly, daily }
public enum AuthState: String, Sendable, Codable { case ok, missing, invalid }
public enum DataSource: String, Sendable, Codable { case api, localOnly }

public struct UsageWindow: Sendable, Equatable, Codable {
    public let kind: WindowKind
    public let usedFraction: Double?   // 0...1; nil = desconhecido
    public let resetsAt: Date?
    public let label: String
}
public struct CreditsInfo: Sendable, Equatable, Codable { public let remaining: Double?; public let unlimited: Bool }
public struct UsageSnapshot: Sendable, Equatable, Codable {
    public let provider: ProviderID, account: AccountID
    public let windows: [UsageWindow]
    public let credits: CreditsInfo?
    public let fetchedAt: Date
    public let source: DataSource
    public let authState: AuthState
}

public struct ProviderCapabilities: OptionSet, Sendable { public static let apiUsage, localIngest, credits, multiAccount: ProviderCapabilities }
public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var capabilities: ProviderCapabilities { get }
    func discoverAccounts() async -> [AccountRef]
    func fetchUsage(_ account: AccountRef) async throws -> UsageSnapshot
    func ingestLocal(_ account: AccountRef, from cursor: IngestCursor) async throws -> IngestBatch
}
```
(`AccountRef` = AccountID + label; `IngestCursor`/`IngestBatch` = tipos novos que embrulham o que a F1 já faz — o ClaudeProvider adapta, sem mudar semântica; os testes F1 existentes têm que continuar verdes.)

- [ ] Steps TDD: teste do protocolo (registry registra/resgata; snapshot codable roundtrip; capability math) → implementar → `./run-tests.sh` 53+ verdes → commit `feat(core): protocolo UsageProvider e domínio de snapshots`

---

### Task 3: Camada HTTP + scheduler adaptativo

**Files:**
- Create: `Sources/TokenBarCore/Network/UsageHTTPClient.swift`
- Create: `Sources/TokenBarCore/Scheduler/AdaptiveScheduler.swift`
- Test: `Tests/TokenBarCoreTests/SchedulerTests.swift`, `Tests/TokenBarCoreTests/HTTPClientTests.swift`

**Interfaces:**
```swift
public struct UsageHTTPClient: Sendable {
    public init(baseURL: URL, timeout: Duration = .seconds(10), session: URLSession = .shared)
    // GET JSON com Authorization bearer; timeout 10s; nunca retry interno; erro tipado (network|http(status)|decode|unauthorized)
    public func getJSON(path: String, bearer: String?, headers: [String: String] = [:]) async throws -> Data
}
public actor AdaptiveScheduler {
    // clock injetável (padrão F1 Debouncer); 1 task por provider×conta
    public init(clock: any Clock<Duration>)
    public func register(provider: ProviderID, onFire: @escaping @Sendable () async -> Void)
    public func noteResult(provider: ProviderID, ok: Bool, pressure: Double?)  // ajusta intervalo
    public func noteMenuOpened()       // intervalo 60s
    public func pauseForSleep()/resumeFromSleep()  // NSWorkspace notifications no wiring
}
```
Intervalos (spec §7): pressão ≥ 0.8 → 30s; menu aberto → 60s; ocioso → 5min; erro → backoff ×2 (teto 30min); jitter ±10%; NUNCA 2 fires simultâneos do mesmo provider (single-flight — herda M1). Testes com clock virtual (padrão `VirtualClock` da F1): sequência de intervalos, backoff, jitter bounds, single-flight.

- [ ] Steps TDD → commit `feat(core): http client com timeout e scheduler adaptativo`

---

### Task 4: CodexProvider (API + local)

**Files:**
- Create: `Sources/TokenBarProviders/Codex/CodexProvider.swift` (UsageProvider completo)
- Create: `Sources/TokenBarProviders/Codex/CodexAuthReader.swift` (lê `~/.codex/auth.json` → token em memória; override `TOKENBAR_CODEX_AUTH` p/ testes)
- Create: `Sources/TokenBarProviders/Codex/CodexSessionIngester.swift` (rollout-*.jsonl → UsageEvents; incremental com FileOffsetStore, herda padrão F1)
- Test: `Tests/TokenBarProvidersTests/CodexProviderTests.swift` (fixtures sintéticas: auth.json fake, session jsonl sintético conforme schema da Task 1, resposta de usage sintética via URLProtocol stub)

**Comportamento:** `fetchUsage` → GET `<base>/backend-api/wham/usage` (base injetável) → UsageSnapshot com janelas 5h (session), weekly, resets, source .api; 401 → `.invalid` + degrada; `ingestLocal` → tokens por sessão. Menu: `X:62%`.

- [ ] Steps TDD → commit `feat(providers): Codex com usage API e ingest de sessões`

---

### Task 5: ZaiProvider (coding plan)

**Files:**
- Create: `Sources/TokenBarProviders/Zai/ZaiProvider.swift`
- Create: `Sources/TokenBarProviders/Zai/ZaiCredentialReader.swift` (lê `~/.zcode/v2/credentials.json` chave `oauth:zai:access_token`; override `TOKENBAR_ZAI_AUTH`)
- Test: `Tests/TokenBarProvidersTests/ZaiProviderTests.swift` (mesma disciplina de fixtures)

**Comportamento:** endpoint/shape conforme Task 1 (fonte CodexBar zai.js/Providers/Zai); janela do plano → `%`; sem credencial → modo local. Menu: `Z:81%`.

- [ ] Steps TDD → commit `feat(providers): Z.ai coding plan com usage API`

---

### Task 6: GeminiProvider (modo local)

**Files:**
- Create: `Sources/TokenBarProviders/Gemini/GeminiProvider.swift`
- Create: `Sources/TokenBarProviders/Gemini/GeminiSessionIngester.swift` (schema da Task 1; incremental)
- Test: `Tests/TokenBarProvidersTests/GeminiProviderTests.swift`

**Comportamento:** `fetchUsage` retorna snapshot `.localOnly` com `windows: []` e `authState` conforme oauth_creds presente; tokens por ingest local. Menu: `G:12.4k`.

- [ ] Steps TDD → commit `feat(providers): Gemini local-first`

---

### Task 7: Menu multi-provider + wiring + heartbeat v2 + selfcheck v2

**Files:**
- Modify: `Sources/TokenBarUI/MenuBarContent.swift` (siglas D5; % p/ provider com janela, tokens p/ local; **implementa a tabela** que a F1 deixou como prefix(1) — testes de display atualizados)
- Modify: `Sources/TokenBarUI/SnapshotStore.swift` (estado por provider: `[ProviderID: ProviderDisplay]` onde ProviderDisplay = {percent: Double?, todayTokens: Int64, authState, fetchedAt})
- Modify: `Sources/tokenbar/AppState.swift` (registry com os 4 providers; scheduler por provider; pausa em sleep via NSWorkspace; M1-guard por provider)
- Modify: `Sources/tokenbar/E2EHeartbeat.swift` + `Sources/tokenbar/SelfCheck.swift` (v2: `{"providers":{"claude":{"menuBar":"C:12.4k","percent":null,"todayTokens":N},...},"menuBarText":"..."}`)
- Modify: `Tests/TokenBarUITests/MenuBarContentTests.swift` (novos formatos)

**Comportamento:** menu bar ex. `C:12.4k X:62% Z:81% G:3.1k` (providers sem dados somem); menu passa a listar cada provider com % e tokens. Cor por pressão fica p/ F3 (só texto na F2, como F1).

- [ ] Steps TDD → smoke manual (lança com overrides; heartbeat mostra os 4) → commit `feat(app): menu bar multi-provider com scheduler`

---

### Task 8: E2E v2 + QA + Red Team + docs

**Files:**
- Modify: `scripts/e2e.sh` (Goal E2E do header: mock server python http.server com respostas sintéticas p/ Codex+Z.ai via TOKENBAR_CODEX_API/TOKENBAR_ZAI_API; cenário de degradação: derruba o mock → app segue vivo em modo local; orçamento de recursos F1)
- Create: `docs/qa/f2-qa-report.md`, `docs/qa/f2-redteam-report.md`
- Modify: `docs/decisoes-f1.md` → renomeia conteúdo p/ `docs/decisoes.md` e acrescenta decisões F2 (ou novo `docs/decisoes-f2.md`)

**Red Team focos:** tokens nunca em log/heartbeat/e2e artifacts (grep + log stream); credenciais lidas read-only (nunca escritas); 401/403 storm não gera retry storm (backoff válido); mock cai no meio do ciclo; corpus gigante multi-provider dentro do orçamento; heartbeat não vaza paths. Achados P1/P2 → fix + regressão (padrão F1).

- [ ] `./run-tests.sh` + `./scripts/e2e.sh` verdes → QA checklist manual (4 itens visuais via AX, padrão F1) → Red Team 7 casos adaptados → relatórios → commit `test(f2): e2e v2, QA e Red Team com fixes` → docs commit

---

## Critério de pronto da F2

Menu bar mostra os 3 providers do usuário com % (Codex/Z.ai) e tokens (Gemini/local) · scheduler adaptativo com backoff e sleep · degradação graciosa comprovada no E2E · zero credencial em log/fixture/doc · suíte verde · QA 6/6 · Red Team com fixes · docs atualizados.
