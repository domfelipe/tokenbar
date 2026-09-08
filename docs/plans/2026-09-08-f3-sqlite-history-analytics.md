# TokenBar F3 — SQLite + Histórico + Custo + Analytics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O que hoje só existe como "tokens de hoje" vira história persistida: SQLite local com eventos e agregados diários, custo estimado por modelo, gráficos 7d/30d no painel, aba analytics com export — mantendo o orçamento de performance da spec.

**Architecture:** GRDB (SPM, única dependência do projeto — decisão da spec §6) com schema da §6 (usage_events, daily_agg, accounts, pricing, alert_rules [usada na F4], settings); ingest dos providers passa a PERSISTIR eventos (hoje é apply-and-discard no ledger) com agregação diária na mesma transação; cursores JSON migram para a tabela `settings` na primeira abertura; pricing é JSON versionado embutido (contribuível via PR) com custo calculado na persistência e exibido como "~USD".

**Tech Stack:** Como F2 + GRDB + Swift Charts (framework do SDK).

**Spec:** `docs/specs/2026-09-02-design.md` (§6 persistência, §8 analytics/export, §12-F3) + `docs/decisoes-f2.md` (contexto F2)

## Global Constraints

- Todas as herdadas (macOS 14+, Swift 6 strict, CLT-only build local, credenciais read-only, fixtures sintéticas, Swift Testing via `./run-tests.sh`, E2E por heartbeat, single-flight por provider, cursor por provider).
- **Zero leitura de credencial nova**; pricing JSON contém apenas nomes de modelo e preços públicos.
- **Custo sempre "~" (estimativa)**; moeda USD (conversão R$ fora de escopo — sem fonte de câmbio offline).
- **Orçamento**: CPU ociosa <0,5%, footprint ≤40MB estacionário, ingest+persistence de 100k eventos <10s com memória bounded; DB em `TOKENBAR_SUPPORT_DIR` (e2e isolado) ou `~/Library/Application Support/TokenBar/tokenbar.sqlite`.
- **Migração não-destrutiva**: cursors.json existentes migram para `settings` na primeira abertura (idempotente); se migração falhar, app segue com estado vazio + re-ingest (nunca crash).
- UI strings EN (padrão), docs PT-BR.
- Ruling F3-SCOPE (controlador): previsão de trend fica na F5 (spec §12); F3 entrega histórico+custo+analytics+export.

## Tasks

### Task 1: GRDB + schema + migração de cursores
- `Package.swift`: dependência GRDB (versão fixada via SPM); `Sources/TokenBarCore/Persistence/Database.swift` (abertura WAL, migrations v1 com o schema da spec §6 completo), `CursorMigrator.swift` (JSON → settings, idempotente).
- Providers passam a receber o DB e persistem eventos+agg na ingest (mesma transação), preservando ledger em memória para o display do dia (o display NÃO consulta o DB a cada render — gate da F1 permanece).
- Testes: migrations idempotentes, migração de cursor legado (fixture cursors.json F1/F2), roundtrip evento→daily_agg, perf smoke 100k <10s.
- Commit: `feat(persistence): sqlite via grdb com schema da spec e migração de cursores`

### Task 2: Pricing table + custo estimado
- `Sources/TokenBarCore/Pricing/PricingTable.swift` + `Resources/pricing.json` (modelos claude-*, gpt-*/codex, gemini-*, glm-* com preços públicos por MTok: input/output/cache read/write; fonte documentada no JSON; modelo ausente → custo nil, nunca chute).
- Persistência calcula cost_usd na ingest; painel passa a exibir `C:12.4k ~$0.08` por provider com custo do dia.
- Testes: cálculo com cache tiers, modelo desconhecido → nil, arredondamento.
- Commit: `feat(pricing): tabela versionada e custo estimado na persistência`

### Task 3: Histórico no painel + Analytics view + export
- Painel: linha por provider ganha "7d: X tok ~$Y"; `AnalyticsView` (Swift Charts): barras dia/semana/mês por provider e por modelo, seletor de período 24h/7d/30d.
- Export CSV/JSON: item de menu "Export history…" → grava em `App Support/TokenBar/exports/` com reveal no Finder.
- Views só existem com painel aberto (lazy — orçamento RAM).
- Testes: queries de agregação vs. eventos conhecidos; formato CSV/JSON estável.
- Commit: `feat(ui): histórico 7d no painel, analytics com charts e export`

### Task 4: selfcheck/history CLI + heartbeat v3
- `tokenbar history [--days N] [--format csv|json]` lê o DB (mesma fonte da UI); heartbeat ganha `history7d` resumido (por provider) para o E2E.
- Commit: `feat(app): subcomando history e heartbeat com histórico`

### Task 5: E2E v3 + QA + Red Team + docs
- E2E: cenários F2 + (a) ingest → `history` CSV/JSON consistente; (b) migração de cursors.json legado no arranque; (c) orçamento com DB (100k eventos no e2e? — usar corpus médio + perf smoke nos testes).
- Red Team: DB corrompido/truncado → reabre vazio sem crash; disco cheio durante persist → app vivo; SQL injection via strings de modelo/path (prepared statements); migrations re-run.
- QA manual: painel com custo, analytics renderiza, export gera arquivo válido.
- Docs: `docs/decisoes-f3.md`, README (DB, export, pricing), spec §6 emenda se GRDB divergir.
- Commit: `test(f3): e2e v3, QA e Red Team` + `docs: decisões F3`

**Critério de pronto (spec §12-F3):** gráficos 24h/7d/30d corretos vs. ingest ✓ · custo ~USD exibido ✓ · migração de cursores sem perda ✓ · orçamento de performance mantido ✓ · E2E+QA+RedTeam verdes ✓ · docs ✓
