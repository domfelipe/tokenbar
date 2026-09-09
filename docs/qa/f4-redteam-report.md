# F4 — Relatório Red Team (Task 4, protocolo Simulador DomHubs)

**Data:** 2026-09-08
**Escopo:** bateria adversarial de 7 casos sobre a superfície F4 — PacingEngine (input de `daily_agg` adversarial), countdown do painel (resetsAt anômalo), frota de 30 contas no ciclo, Add Account com paths hostis, overlap via registro programático, higiene do heartbeat multi-conta e o ticker do countdown com painel aberto. Superfícies F1–F3 (parsers, decoders, DB, migração, export) já batidas em `docs/qa/f2-redteam-report.md` e `docs/qa/f3-redteam-report.md`.
**Método:** cada caso com (a) regressão pinada na suíte quando automatizável e (b) prova de sistema quando o vetor é runtime. Evidência bruta: `docs/qa/evidence/f4-redteam-runtime.log` (bateria runtime, 7 PASS / 0 FAIL) + E2E v4 `docs/qa/evidence/e2e-f4-2026-09-08.log` (62 PASS). **Nota de evidência:** totais de tokens e timings variam entre rodadas (corpus relativo ao instante de geração); a evidência autoritativa é o log commitado — os números citados aqui são os dele.

---

## Resumo

| # | Caso | Resultado | Severidade | Fix | Regressão |
|---|------|-----------|------------|-----|-----------|
| 1 | Pacing com DB adversarial (negativos, Int64.max, 1 ponto, timestamps futuros) | PASS | P3 (camadas documentadas) | — (engine cobre) | `hostileTotalsStayFinite`, `allNegativeTotalsYieldNil`, `singlePointYieldsNil`, `resetInPastIsFlat`, `hostileFractionsDegrade`, `distantResetSaturates`, `hostileDailyAggRowsAreDiscarded` |
| 2 | Countdown com resetsAt no passado/nil/anômalo | PASS | — | — | `pastResetsShowRenewed`, `anomalousResetsStayFinite`, `windowRowsClampAdversarialInput`, `pacingAndUpdatedAdversarial` |
| 3 | 30 contas registradas no mesmo provider → ciclo cobre todas | PASS | — | — | `thirtyAccountsAllCycleInOnePass` (unidade) + E2E v4 §10 (runtime: 31 contas cobertas em 4 s, 16.8M, cpu 0.0%) |
| 4 | Add Account com paths inválidos (permissão negada, /dev/null, FIFO, symlink quebrado) | **FALHA → FIXED (P2)** | **P2** | `FileKind.isRegularFile` guardando os 3 readers + `hasInvalidPath` + warning no form | `RedTeamF4ProviderTests` (FIFO/dir/device/dangling → nil), `fileKindClassification`, `hostileCredentialPathsDegradeToNil`, runtime §RT4 |
| 5 | Overlap: registro programático BYPASSANDO o form | PASS (comportamento documentado) | P3 | Defesa em profundidade: `AccountsModel.add` revalida e lança `directoryOverlaps` | `programmaticOverlapIsBlocked`, `programmaticOverlapDoublesDocumented` (residual), E2E §10 (caminho programático usado como setup) |
| 6 | Heartbeat com 30 contas: sem credencial/paths vazados, payload razoável | PASS | — | — | `heartbeatWithThirtyAccountsLeaksNothing` + E2E §10 (798 B, grep paths/acct- vazio) |
| 7 | Ticker do countdown com painel aberto por 10 min → sem leak | PASS | — | — | Runtime §RT7 (footprint amostrado 1×/min — log commitado) |

**Achados novos da bateria (fora dos 7 casos):**

| Achado | Severidade | Ação |
|---|---|---|
| **FIFO/não-regular como credencial trava o ciclo**: `Data(contentsOf:)` num FIFO SEM escritor bloqueia `open()` para sempre — a conta nunca volta e o provider fica preso em `inFlight`. `/dev/null` (char device), diretório e symlink quebrado também não são credencial legível | **P2** | Fix da Decisão 8 (`decisoes-f4.md`): guard `FileKind.isRegularFile` (segue symlinks — link para `auth.json` real segue válido) nos readers Codex/Z.ai, badge `invalid path` em `hasInvalidPath` e warning no formulário. Runtime provado: 2 contas FIFO + 1 `/dev/null` ciclizando sem hang (4 s/ciclo) |
| `attributesOfItem(atPath:)` NÃO segue symlinks neste toolchain/OS (tipo do link volta `.typeSymbolicLink`) — a primeira versão do guard teria REJEITADO symlink para credencial real (dotfile managers!) | P3 (pego em teste) | Guard resolve a cadeia com `resolvingSymlinksInPath` antes do attributesOfItem; pinado em `fileKindClassification` (link→regular ✓, link→FIFO ✗, dangling ✗) |
| `pacingInput` é cru por contrato: ISO leniente ("2026-13-99") ROLA para data real (leniência do Calendar) e agregado NEGATIVO atravessa a query — a defesa contra negativos é do ENGINE (descarta, satura finito) | P3 (camadas documentadas) | Pinado em `hostileDailyAggRowsAreDiscarded`; registro na Decisão 9 do `decisoes-f4.md` |
| E2E flake de timing (1× na T3, pós-suíte pesada): esperas por conteúdo de 10 s eram justas sob load | P3 (script) | Esperas estendidas para 25 s (semântica mantida: conteúdo, nunca sleep fixo); sem ocorrência nos 3 runs de gate da T4 |

**Suíte final: 395 testes / 56 suítes verdes** (377 base F4-T3 + 18 regressões Red Team F4). E2E v4: 62 PASS, exit 0.

---

## Caso 1 — Pacing com DB adversarial: PASS (saturação vale, camadas documentadas)

**Ataque (unidade, `RedTeamF4Tests`):** totais `Int64.max`/negativos/misturados na regressão → qualquer forecast devolvido é FINITO (`projectedFraction ≤ 1e6`, `deficitPct`/`exhaustedIn` finitos quando presentes); só-negativos → <2 pontos válidos → nil; 1 ponto → nil; resetsAt NO PASSADO → projeção = uso atual (flat, nunca esgotamento negativo); frações NaN/±inf/fora de 0...1 → nil ou saturadas; reset no ano 9999 com taxa gigante → sem overflow. DB direto (INSERT hostil no `daily_agg`): day strings não-ISO ("garbage", "-2026-08-30") descartadas na query; ISO leniente rola para data real; agregado negativo atravessa a query e é DESCARTADO pelo engine — nenhum número negativo vira "uso".

**Runtime (E2E v4 §3.1, sonda com o app real):** Codex com 2 dias de rollout sintético → pacing PRESENTE e FLAT (`projectedFraction=0.42`, `exhaustedIn=null` — janela `.session` não projeta sobre agregados diários); Z.ai com fração 81% + reset mas ZERO histórico → pacing AUSENTE; Claude sem janela → AUSENTE. A honestidade "<2 pontos → sem chute" provada nos dois sentidos no payload real.

## Caso 2 — Countdown com resetsAt anômalo: PASS

**Ataque (unidade, `RedTeamF4UITests`):** resetsAt no passado (−1 s, −1 ano, epoch, `.distantPast`) → `"renewed"`/`"Renewed"` — NUNCA dígitos negativos; `.distantFuture` → texto finito sem "-"; 1 s restante → mínimo "1m" (nunca "0m"); resetsAt nil → countdown nil (linha sem promessa); frações fora de 0...1 saturam (1.5→100%, −0.2→0%); `pacingText` com `exhaustedIn` negativo → "should last until renew"; `updatedText` com fetchedAt NO FUTURO → delta clamped ("updated 1s ago", epoch → "not updated yet").

## Caso 3 — 30 contas no mesmo provider: PASS (orçamento mantido)

**Unidade (`thirtyAccountsAllCycleInOnePass`):** 30 contas Claude (137 tokens cada, dir própria) + canônica → UM ciclo cobre as 31 (soma exata 4143, 31 linhas por conta no display, 31 namespaces no `daily_agg`); remoção em LOTE volta ao layout F2 (33); remoção no-op é idempotente.

**Runtime (E2E v4 §10, app real):** frota de 30 contas CLAUDE registrada por sqlite3 (ingest local — zero request extra; as provas de rede da §7 já tinham fechado) → "UM ciclo cobre as 31 contas — soma exata (7095607 == 7091347 + 150 + 4110) em 4s" (limite do loop 30 s). Orçamento pós-ingest: phys_footprint **16.8M** ≤ 40 MB, cpu **0.0%** ≤ 0.5%.

## Caso 4 — Add Account com paths inválidos: FALHA → FIXED (P2, o achado da fase)

**Ataque (unidade, `RedTeamF4ProviderTests`):** antes do fix, `CodexAuthReader.read()`/`ZaiCredentialReader` faziam `Data(contentsOf:)` direto — num FIFO SEM escritor o `open()` BLOQUEIA PARA SEMPRE: o fetch da conta nunca volta e o provider fica preso em `inFlight` (DoS por misconfiguração; o formulário aceitava o path porque `fileExists(FIFO) == true`). Com o guard `FileKind.isRegularFile`: FIFO/diretório/`/dev/null`/symlink quebrado → `nil` imediato, degradação normal (`.missing`/badge); caminho legítimo (auth.json regular) segue lendo.

**Runtime (§RT4 do log commitado, 7 PASS / 0 FAIL):** app real com 3 contas hostis registradas (2× FIFO codex/zai + 1× `/dev/null` claude) → ciclo cobriu em 4 s (claude 203 == 66 local + 137 da conta devnull), processo vivo, codex/zai `.missing` sem request, 2º ciclo idem (degradação finita e repetível). Badge honesto: a linha da conta FIFO mostra "invalid path" (render de evidência `account-rows.png`).

**Nota de método:** a prova VERMELHA do hang é por inspeção do `open(2)` — um teste sem o guard penduraria a suíte (sem timeout padrão no Swift Testing); o teste verde pós-fix pins o comportamento.

## Caso 5 — Overlap via registro programático: PASS (documentado + defesa em profundidade)

**Comportamento registrado:** o guard de overlap mora na UI (`AddAccountForm.validate` — bloqueia) e agora TAMBÉM em `AccountsModel.add` (revalida; lança `AccountsModelError.directoryOverlaps`) — qualquer chamador futuro do app herda o guard. O `AccountRegistry.add` (Core) permanece SEM guard por construção (não conhece as raízes canônicas): chamado direto, aceita dirs sobrepostas e o corpus conta 2× — `programmaticOverlapDoublesDocumented` pina o comportamento (33+10+10, sem re-dobra no 2º ciclo — hwm por conta NÃO colide; a dobragem é entre contas, persistente, sem crash). Nenhum caminho de usuário alcança o registry direto; o E2E v4 §10 usa exatamente esse caminho programático (sqlite3) como setup — é contrato documentado, não bug de produto. **Severidade: P3** (uso interno futuro errado; mitigação barata já no lugar).

## Caso 6 — Heartbeat com 30 contas: PASS (higiene total)

**Unidade (`heartbeatWithThirtyAccountsLeaksNothing`):** 31 contas com labels/keys hostis (path de credencial + `'; DROP TABLE accounts;--`) → o payload v3 NÃO contém nenhum label/path/id de conta (`grep acct-` vazio), 798 B no E2E real (limite checado 64 KB). O heartbeat é por provider — contas não vazam por construção; os campos F4 (`monthTokens`/`monthCostUsd`/`pacing`) são agregados/derivados.

## Caso 7 — Ticker com painel aberto 10 min: PASS

**Runtime (§RT7 do log commitado):** app release real, painel aberto (menuDidOpen provado pelo refresh imediato do heartbeat), phys_footprint amostrado 1×/min por 10 min — estável, sem crescimento (números no log; padrão estacionário ~17 MB). O ticker de 30 s vive só enquanto a view está instalada (`.onAppear`/`onReceive`); fechar o painel cancela a subscrição. Minor registrado: o `Timer.publish` re-ancora a fase a cada render do pai (decisões-f4) — sem efeito de corretude nem de footprint.

## Preocupações residuais (documentadas, sem ação na F4)

1. **`pacingInput` cru** (caso 1): camada de query não filtra negativos/ISO leniente — defesa no engine. Se um dia outra view consumir `pacingInput` direto, replicar o filtro.
2. **Overlap no registry puro** (caso 5): INSERT direto/`registry.add` dobram contagem — contrato Core documentado; a dobragem não é limpa pela remoção (limitação já registrada na F3 para rewrites).
3. **Cursor de conta não watched**: dirs de contas registradas não têm FSEvents próprio — o ciclo delas roda na cadência do provider (FSEvents da canônica + fallback 15 min + scheduler). Para a F4 (mecanismo) é suficiente; watcher por conta é candidato natural da F5 (junto com troca de credencial).

## Artefatos

- **Regressões (commit de teste):** `Tests/TokenBarCoreTests/RedTeamF4Tests.swift` (8), `Tests/TokenBarProvidersTests/RedTeamF4ProviderTests.swift` (1), `Tests/TokenBarUITests/RedTeamF4UITests.swift` (7), `Tests/TokenBarUITests/MultiAccountCoordinatorTests.swift` (+2: frota 30, overlap programático).
- **Fixes de produto:** `Sources/TokenBarCore/Domain/FileKind.swift` (novo), guards em `CodexAuthReader.swift`/`ZaiCredentialReader.swift`, `hasInvalidPath` regular-file/diretório, warning no `AddAccountForm.validate`, overlap guard em `AccountsModel.add`.
- **Runtime:** `docs/qa/evidence/f4-redteam-runtime.log` (7 PASS / 0 FAIL + §RT7 ticker).
- **E2E:** `docs/qa/evidence/e2e-f4-2026-09-08.log` (§3.1 sonda de pacing, §5.1 heartbeat fields, §10 multi-conta/frota/orçamento).
