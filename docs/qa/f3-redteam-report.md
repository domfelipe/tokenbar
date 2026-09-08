# F3 — Relatório Red Team (Task 5, protocolo Simulador DomHubs)

**Data:** 2026-09-08
**Escopo:** bateria adversarial de 7 casos sobre a camada de persistência F3 (SQLite/GRDB, migração de cursores, marca d'água de persistência, export CSV/JSON, queries de leitura) e o orçamento de recursos com o banco aberto, conforme brief da T5. Superfície F2 (parsers, decoders, credenciais, scheduler) já batida em `docs/qa/f2-redteam-report.md` — re-ataques só onde a F3 mudou o caminho (ingest agora persiste; stores de cursor agora moram no DB).
**Método:** cada caso com (a) regressão pinada na suíte quando automatizável e (b) runtime com o app real quando a prova é de sistema. Evidência bruta: `docs/qa/evidence/f3-redteam-runtime.log` (bateria runtime, 21 PASS / 0 FAIL). **Nota de evidência:** totais de tokens/custo e timings variam entre rodadas (o corpus do genfixtures é relativo ao instante de geração e o agendamento da máquina varia); a evidência autoritativa é o log commitado — os números citados neste relatório são os dele.

---

## Resumo

| # | Caso | Resultado | Severidade | Fix | Regressão |
|---|------|-----------|------------|-----|-----------|
| 1 | DB corrompido/truncado → reabre sem crash | PASS (com achado documentado) | P3 (achado) | — (contrato já cobre) | `corruptDatabaseThrowsOnOpen`, `truncatedDatabaseDoesNotCrashOnOpen`, `corruptDatabaseDegradesToModeF2` |
| 2 | Disco cheio durante persist → app vivo | PASS | — | — | `readOnlySupportDirectoryDegradesGracefully` + `persistenceFailureDoesNotBreakIngest` (T1) |
| 3 | Migration re-run (abrir app 2×) → idempotente | PASS | — | — | E2E v3 §9 (3º launch) + `migrationsCreateSchemaAndAreIdempotent` (T1) |
| 4 | Migrator com rename falho persistente → re-semeadura stale | PASS (valida o design T1) | — | — | `staleReMigrationDoesNotDuplicateAndRecovers` + runtime chflags uchg |
| 5 | Export hostil: 10k eventos, model com vírgula/aspas/quebra → CSV RFC 4180 | PASS | — | — | `exportHostileModelsRoundTripsRFC4180` (parse de volta byte-exato) |
| 6 | SQL injection via strings (model/path) → prepared statements | PASS | — | — | `hostileSQLStringsStayBound` + runtime com corpus hostil |
| 7 | Corpus grande + DB: 100k eventos → orçamento | PASS | — | — | `perfSmoke100kEventsInUnder10Seconds` (T1) + runtime (métricas §Caso 7) |

**Achados novos da bateria (fora dos 7 casos):**

| Achado | Severidade | Ação |
|---|---|---|
| Corrupção pode surfaced na QUERY, não no `open`: DB truncado no meio de página (com WAL descartado) pode passar pelo `open` (migrations ok) e falhar na 1ª leitura ("database disk image is malformed") | **P3** — o contrato do produto cobre os dois caminhos (`try?` no open + `try?`/do-catch nas queries → modo F2; provado em unidade e runtime) | Documentado (decisão/minor no `decisoes-f3.md`) + testes que pinnam a capturabilidade |
| WAL vivo "desfaz" o truncamento do arquivo principal: truncar só o `.sqlite` com WAL intacto mantém os dados legíveis (consulta funciona, `history7d` presente) | Info (comportamento correto do SQLite — dado íntegro = consulta ok) | Teste de corrupção descarta o WAL para exercitar o caminho real |

**Suíte final: 304 testes verdes** (296 base T4 + 7 desta task + 1 pin do fix T4). E2E v3: 39 PASS, exit 0.

---

## Caso 1 — DB corrompido/truncado → reabre vazio sem crash, F2 mode: PASS + achado P3

**Ataque (unidade):** (a) 8 KB de bytes aleatórios no lugar do `.sqlite` (sem header SQLite) → `AppDatabase.open` lança Swift Error capturável — nunca crash; (b) banco saudável com 500 eventos truncado no meio de página → reabertura não crasha; ou responde coerente ou falha capturável (`count == nil || count == 200`).

**Ataque (runtime, app real):** support dir com `.sqlite` = bytes lixo → app relança → **processo vivo**, heartbeat com ingest correta (`todayTokens > 0`), `history7d` **OMITIDO** (modo F2 honesto — nada fake) e o CLI `tokenbar history` sobre o DB lixo degrada com `[]` no stdout, aviso no STDERR e exit 0. Log: `f3-redteam-runtime.log` §RT1 (4 PASS).

**Coordenador (regressão `corruptDatabaseDegradesToModeF2`):** DB truncado real no support do coordinator → ingest segue, `history7d` omitido, `menuBarText` correto — o `try?` do init degrada exatamente como projetado.

**Achado (P3, documentado):** no cenário truncado, a corrupção pode aparecer na 1ª QUERY em vez do `open` (as migrations podem rodar antes do contato com a página faltante). Nenhum caminho crasha — o erro é Swift Error nos dois casos — e nenhum número é inventado (`history7d` omitido, CLI `[]`). Registro no `decisoes-f3.md` (minor "Corrupção pode surfaced na QUERY").

## Caso 2 — Disco cheio durante persist → app vivo: PASS

**Ataque (runtime):** support directory em modo readonly (chmod 555 — equivalente a volume cheio para toda escrita do app) com o app lançando sobre ele → **processo vivo**, heartbeat do claude correto (`todayTokens > 0`), `history7d` omitido (DB não abriu) e **nenhum arquivo SQLite criado** no dir readonly. Log: §RT2 (4 PASS).

**Falha DURANTE a persist (o banco abriu e o disco encheu depois):** coberta pela regressão da T1 `persistenceFailureDoesNotBreakIngest` — `persistBatch` throws → o provider LOGA e segue; o display do dia permanece correto (`eventsApplied == 1`, `providerTotals` exato). Por camada: ingest sobrevive à falha de persistência em qualquer ponto (abertura, hot loop, escrita de cursor — `try?`).

## Caso 3 — Migration re-run (abrir app 2×) → idempotente: PASS

**Ataque (E2E v3 §9, app real):** o banco é reaberto em 3 launches sobre o MESMO schema: fase 1 (cria), migração (recria após cenário F2), re-run deliberado. Provas do re-run: `cursors.json` já renomeados → migração no-op; `usage_events` **ainda == 1** (não dobrou); `daily_agg` **ainda == 300 tokens**; claude no heartbeat **4288522 == 4288522** no 3º launch. Unidade: `migrationsCreateSchemaAndAreIdempotent` (reabrir não re-roda a migration — registradas em `grdb_migrations`).

## Caso 4 — Migrator com rename falho persistente → re-semeadura stale, auto-recupera no rollover: PASS (design T1 validado)

**Ataque (runtime, app real):** `cursors.json` legado plantado e marcado **imutável** (`chflags uchg`) — o rename do migrator falha PERSISTENTEMENTE enquanto o DB segue saudável. Resultado (log §RT4, 5 PASS): o conteúdo migrou para `settings` mesmo com rename falho; o arquivo ficou no lugar (sem `.migrated`); app vivo; **2º relaunch** re-semeou o mapa stale e o banco NÃO duplicou (0 eventos novos — a marca d'água `INSERT OR IGNORE` nunca rebaixa); removido o `uchg`, o **3º relaunch convergiu** (`.migrated` apareceu).

**Unidade (`staleReMigrationDoesNotDuplicateAndRecovers`):** reproduz o mecanismo ponta a ponta — re-migração reescreve `cursors:claude` com o offset VELHO (re-semeadura confirmada: `DBOffsetStore` vê 100), o re-ingest do trecho antigo é descartado pelo hwm (sem o 999 duplicado), a 1ª escrita do store vivo sobrescreve o mapa (auto-recuperação — o "rollover"/ciclo normal corrige o stale) e bytes novos persistem exatamente 1×. Complementa `cursorMigrationNeverLowersHighWater` (T1).

## Caso 5 — Export hostil: 10k eventos com model contendo vírgula/aspas/quebra de linha → CSV RFC 4180 válido: PASS

**Ataque (`exportHostileModelsRoundTripsRFC4180`):** 10.000 eventos persistidos via `persistBatch` com modelo hostil `"a,b\"c\nd;'--\tDROP"` (vírgula, aspas, LF, aspas de SQL, tab) alternado com `claude-sonnet-4-6` → `exportAll` → o CSV é PARSEADO DE VOLT por um parser RFC 4180 completo (estado: citação, aspas dobradas, LF/CRLF) escrito no teste:

- 10.001 linhas (header + 10k), 5.000 com o modelo hostil;
- o campo hostil volta EXATO (vírgula, aspas e quebra de linha preservados pela citação);
- modelo sem preço → `cost_usd` VAZIO (nunca "0");
- JSON: mesmo dado estruturado, `model`/`costUSD` nulos explícitos, roundtrip Codable íntegro.

Nota (decisão 6 do `decisoes-f3.md`): fim de linha LF, desvio consciente do RFC §2.1 — o escape é 100% RFC e o parser de volta aceita.

## Caso 6 — SQL injection via strings de model/path → prepared statements seguram: PASS

**Ataque (unidade, `hostileSQLStringsStayBound`):** `model = "x'); DROP TABLE usage_events;--"` e `path = "/p/'; DROP TABLE settings;--.jsonl"` em `persistBatch` → as três tabelas sobrevivem (`sqlite_master` íntegro), o dado hostil é recuperável EXATO (roundtrip, não mutação: `dailyAggRows` contém o model literal, `highWater` do path hostil == 4242), queries da UI rodam com o dado hostil no banco e o re-ingest do mesmo path é dedupado pelo hwm.

**Ataque (runtime, app real — corpus hostil):** transcript Claude com o model hostil injetado → app vivo, ingest contou o evento (777 no display), o model hostil está no banco **recuperado via bind parameter** (COUNT exato == 1 via `sqlite3` com bind em Python), `sqlite_master` tem as 6 tabelas do schema §6 + migrator e `daily_agg` íntegra com o evento. Log: §RT6 (4 PASS).

Por construção: toda statement do projeto usa argumentos vinculados (GRDB `arguments:`/`cachedStatement`) — nenhum caminho interpola string em SQL (grep de `execute(sql:` sem `arguments` confere).

## Caso 7 — Corpus grande + DB: 100k eventos → DB size sane, footprint ≤40MB, history não bloqueia o menu: PASS

**Ataque (runtime, app real):** corpus de **100.000 linhas** (10 sessões × 10k, genfixtures) → ingest frio com o app real; footprint amostrado por `vmmap` a cada 0,5s DURANTE a ingest.

| Métrica | Orçamento | Medido |
|---|---|---|
| 1º heartbeat (ingest + persistence de 100k) | <10s (T1) | **9 s** |
| phys_footprint pico durante ingest | ≤ 40 MB | **29,6 MB** |
| DB size (.sqlite + WAL) | < 20 MB | **17,6 MB** |
| Query `history --days 7` DURANTE a ingest (WAL, escritor ativo) | não bloquear o menu (fora da MainActor) | **2,92 s** de ponta a ponta do CLI (compilação inclusa) |
| Estacionário após 60s ocioso com DB aberto | ≤ 40 MB / cpu < 0,5% | **17,2 MB / 0,0%** |
| `history7d` do corpus completo | linhas por dia×provider, custo > 0 | ✔ (claude 767.594.672 tokens com custo) |

O pico de memória não escala com o corpus (janela de streaming + lote em transação) — coerente com o `perfSmoke100kEventsInUnder10Seconds` da T1 (5,7s na T1; 9s aqui inclui o ciclo completo do app + watcher + heartbeat). A query de leitura não bloqueia o menu: roda em `Task.detached` fora da MainActor (coordinator) e o CLI respondeu enquanto o escritor estava ativo.

## Preocupações residuais (documentadas, sem ação na F3)

1. **Backfill fora de escopo:** upgrade F2→F3 não re-persiste eventos anteriores ao cursor legado (hwm plantado no offset; decisão T1) — o histórico do banco começa nos eventos NOVOS. Provado no E2E §9 (history vazio pós-migração).
2. **Custo não-retroativo:** correção de preço na tabela vale para eventos futuros apenas (decisão 5 do `decisoes-f3.md`).
3. **`--days` sem teto** no CLI (365 é permitido): custo é 1 query indexada; sem vetor real de DoS, registrado como minor.
4. **Conteúdo do `settings` cresce com os paths** (`hwm`/`cursors` por arquivo): dezenas de bytes por transcript; podar entradas órfãs segue como candidate para F4+ (mesma pendência dos stores JSON da F2).

## Artefatos

- **Regressões (commit de teste):** `Tests/TokenBarCoreTests/RedTeamF3Tests.swift` (4), `Tests/TokenBarUITests/CoordinatorRedTeamTests.swift` (2), pin `selfcheckModeWithOwnSupportDirectoryIncludesHistory7d` (1).
- **Runtime:** `docs/qa/evidence/f3-redteam-runtime.log` (bateria completa, 21 PASS / exit 0).
- **E2E:** `docs/qa/evidence/e2e-f3-2026-09-08.log` (cenário §9 cobre os casos 3 e a auto-recuperação do 4 na superfície de sistema).
