# TokenBar — F3 · Decisões Técnicas

Data: 2026-09-07
Projeto: tokenbar (F3 — SQLite + histórico + custo + analytics)
Complemento de `docs/decisoes-f1.md` e `docs/decisoes-f2.md` (mesmo formato: contexto → decisão → consequência). Rulings registradas no ledger SDD durante as Tasks 1–5 e consolidadas aqui na T5.

---

## Decisão 1: F3-SCOPE — histórico + custo + analytics + export; previsão fica na F5

**Contexto:** o plano F3 original arrastava trend forecast para dentro da fase; a spec §12 lista previsão na F5.

**Decisão:** F3 entrega exatamente: eventos persistidos em SQLite, agregados diários, custo ~USD por modelo, linha 7d no painel, aba Analytics (24h/7d/30d), export CSV/JSON e o CLI `history`. Previsão de trend fica na F5 (spec §12). Custo só em USD — conversão R$ fora de escopo (sem fonte de câmbio offline; nunca inventar taxa).

**Consequência:** escopo fechado e verificável pelo critério de pronto §12-F3; a extensão natural da série diária para forecast não exige nada de F3 além da `daily_agg` correta.

## Decisão 2: F3-DB-ENGINE — GRDB como única dependência externa

**Contexto:** spec §6 fixa GRDB (SPM); a alternativa era sqlite3 cru (sem migrations, sem pooling, mais código de colagem).

**Decisão:** GRDB via SPM, versão fixada, `Package.resolved` commitado. `DatabasePool` (WAL: leitores concorrentes + 1 escritor — o CLI `history` lê enquanto o app escreve, provado no E2E §7.5). Migrations v1 = schema §6 completo verbatim (inclui `alert_rules`/`pricing`, usados na F4); reabrir o banco é no-op (registradas em `grdb_migrations`).

**Consequência:** migrations idempotentes de graça (re-run provado no E2E §9); custo é uma dependência no projeto que hoje não tem nenhuma — aceito e ratificado pelo review T1.

## Decisão 3: F3-HWM — dedupe de persistência por marca d'água de byte offset

**Contexto:** rollover de meia-noite e cursor perdido fazem a ingest RELER o arquivo inteiro; sem dedupe no banco o histórico dobraria a cada dia.

**Decisão:** cada lote persistido avança `settings hwm:<provider>:<path>` NA MESMA transação dos eventos (`persistBatch`). Lote com `endOffset <=` marca d'água é descartado. Migração de cursor legado planta `hwm = offset legado` com INSERT OR IGNORE (re-migração nunca rebaixa) — bytes contados antes da F3 não viram eventos retroativos.

**Consequência:** re-scan de rollover e re-semeadura stale (rename falho do migrator — Red Team caso 4) não duplicam nada; a auto-recuperação do cursor stale acontece na 1ª escrita do store vivo (sobrescreve o mapa inteiro). O cursor PODE voltar no tempo (display re-lê); o banco não.

## Decisão 4: F3-GEMINI-FIELDS — herda o split do F2 sem mudança

**Contexto:** o split Gemini (`output = output + thoughts + tool`, `cacheRead = cached`) foi decisão F2 (nº 3); o analytics precisa do mesmo split por evento.

**Decisão:** o provider persiste exatamente os componentes que o ledger conta — uma única fonte de verdade (`UsageEvent` stampado no parser), zero lógica nova de parsing na persistência.

**Consequência:** painel, analytics, export e CLI concordam por construção; divergências futuras seriam bug de UM lugar, não de quatro.

## Decisão 5: custo calculado NA INGEST, não-retroativo por construção

**Contexto:** precificar na leitura exigiria re-precificar o histórico a cada mudança de tabela (e preços passados virariam preços de hoje — dado errado).

**Decisão:** `cost_usd` é calculado na `persistBatch` com a `PricingTable` vigente e gravado na INSERT (evento e `daily_agg`). Modelo sem preço público → NULL (nunca 0 "grátis"); evento já persistido NUNCA é re-precificado (o hwm impede re-leitura). Custo NULL ≠ custo zero em TODAS as leituras (`dailySeries`/`weekTotal`/export: `nil` = sem custo computável; soma SQL só é `nil` quando TODO o grupo é NULL).

**Consequência:** o custo é uma estimativa honesta congelada no momento da ingest; correção de preço vale para eventos futuros. Preço digitado errado num PR de pricing corrige o futuro, não o passado — aceito (documentado no README).

## Decisão 6: CSV usa LF (desvio consciente do RFC 4180 §2.1)

**Contexto:** o RFC pede CRLF como fim de linha; o export/CLI emitem LF (padrão Unix, consistente com o resto do projeto).

**Decisão:** LF com quebra final; o escape RFC 4180 (citação quando há `,` `"` CR LF; aspas dobradas) é mantido — provado por roundtrip com parser RFC completo em campo hostil (10k eventos, Red Team caso 5). Parsers modernos (Python csv, Excel, Numbers) aceitam LF.

**Consequência:** diffs e `git diff` de exports ficam limpos; interoperabilidade não foi perdida (parseado de volta byte-exato nos testes).

## Decisão 7: F3-PERF-SMOKE — flake sob load alto é ambiental, não afrouxa o assert

**Contexto:** o perf smoke (100k eventos ingest+persistence <10s) falhou esporadicamente em máquina sob load.

**Decisão:** stash-test provou que a falha desaparece com a máquina tranquila e reaparece sob load externo — é ruído ambiental, não regressão. O assert permanece em 10s (não afrouxar para "verde fácil"); em CI ou máquina dedicada o orçamento vale como está.

**Consequência:** re-run é o tratamento documentado para flake; uma falha do smoke sob load NÃO bloqueia sem re-run confirmado.

## Decisão 8: createDirectory da support dir no COORDINATOR (review T4, Important)

**Contexto:** o review T4 provou que o selfcheck nunca criava `<tmp>/tokenbar-selfcheck` — `DatabasePool` não abre DB em diretório inexistente, então `history7d` era SEMPRE omitido no selfcheck (e a Decisão 6 do report T4 alegava o contrário — corrigida no report).

**Decisão:** o `createDirectory` mora no init do `ProviderCoordinator` (ponto único onde o DB abre), não no `SelfCheck.run`: cobre o selfcheck (fábricas injetadas nunca criavam o dir) e qualquer chamador futuro; o AppState já criava via `SupportDirectory.resolve` e as fábricas default também criam. Pino: `selfcheckModeWithOwnSupportDirectoryIncludesHistory7d` reproduz o setup EXATO do selfcheck e fica vermelho sem o fix (provado por stash-test).

**Consequência:** selfcheck v3 traz `history7d` honesto (E2E cenário c); nenhum caminho de abertura de banco depende do chamador ter criado o diretório.

## Decisão 9: E2E v3 — migração simulada com cursors extraídos do banco; espera por conteúdo, não por arquivo

**Contexto:** o cenário de migração precisa de um `cursors.json` legado F2 crível. Reproduzir o formato à mão (offsets, paths resolvidos, seenIDs) é frágil; e o app publica o heartbeat a CADA provider — ler o `state.json` cedo demais captura um payload parcial (falso FAIL/FAIL falso).

**Decisão:** (a) os cursors legados são EXTRAÍDOS do banco da fase 1 (`settings cursors:<provider>`) — o mesmo mapa que o `JSONFileOffsetStore` do F2 gravava, byte-fiel por construção; o DB é apagado em seguida (cenário "F2, sem DB"). (b) Todas as esperas de relaunch ancoram em CONTEÚDO: providers esperados presentes + `updatedAt` mudou (prova que o app NOVO publicou, não o arquivo velho). (c) Comparações de histórico são por JANELA (o corpus do genfixtures tem eventos de até 24h no passado, que caem no dia de ontem local): série 3d == 7d (tudo <48h), série 1d == todayTokens (mesmo calendar/filtro do ledger), `history7d ≥ todayTokens`.

**Consequência:** o cenário de migração prova exatamente o que um upgrade F2→F3 faz (rename `.migrated`, zero re-scan via restore do ledger com stamp, zero backfill, evento novo persiste 1×, re-run idempotente) sem duplicar a lógica do formato em bash; os checks não flakeiam com a hora do dia.

---

## Minors e pendências registradas (triagem F3)

Itens menores do ledger que não viraram decisão própria mas precisam de registro:

- **Prefixo `o3` colide com `o3-mini*` (T2):** match de prefixo superestima ~2× se um modelo "o3" puro aparecer; ganha entrada própria na tabela quando relevante.
- **`gpt-5.3` herda preço de `gpt-5` (T2):** aproximação (~-29% de erro potencial) até slug público com preço próprio.
- **`dailyAggRows` normaliza NULL→0 (T1):** reader legado de TESTES — os caminhos de UI/CLI usam `HistoryQueries` (NULL ≠ 0 preservado). Não usar o legado para custo.
- **`try?` no encode JSON do CLI `history` (T4):** falha de encode cai em `[]` silencioso; irrealista (encode de array simples), mas registrado.
- **`--days` sem teto (T4):** `--days 365` é permitido (custo é 1 linha de janela SQL indexada; sem DOS real).
- **`history7d` stale no branch de falha de ingest (T4):** semântica v2 do painel (mantém último valor bom); o heartbeat v3 OMITE o campo na falha — contrato assimétrico consciente.
- **Corrupção pode surfaced na QUERY, não no open (T5, Red Team caso 1):** DB truncado no meio (WAL descartado) pode passar pelo `open` (migrations ok) e falhar na 1ª leitura ("database disk image is malformed"). O contrato do produto cobre os dois caminhos (`try?` no open + `try?`/do-catch nas queries → modo F2), provado em unidade e no runtime; nenhum caminho crasha.
- **Sobrescrita de pricing pelo usuário (spec §6):** emendada na spec — a tabela é a embutida (bundled); mecanismo de override do usuário ficou para fase futura.

## Evidências da T5 (gates finais)

- Suíte: **304 testes / 37 suítes verdes** (`./run-tests.sh`) — 296 base + 1 pin do fix T4 + 7 Red Team (4 `RedTeamF3Tests` + 2 `CoordinatorRedTeamTests` + 1 pin... detalhamento no `f3-redteam-report.md`).
- E2E v3: **39 checks PASS, exit 0** (log integral em `docs/qa/evidence/e2e-f3-2026-09-08.log`).
- Red Team runtime: log integral em `docs/qa/evidence/f3-redteam-runtime.log` (21 PASS / exit 0).
