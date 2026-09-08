# TokenBar F4 — Painel Rico (paridade CodexBar) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O painel .window vira a experiência da referência do usuário (screenshot CodexBar, 2026-09-08): abas por provider, barra de progresso da janela com countdown de reset, aviso de esgotamento (pacing), totais hoje/30d com custo, chart diário dentro do painel, e "+ Add account" — tudo com os dados que a F2/F3 já persistem.

**Architecture:** `ProviderPanelView` (SwiftUI) substitui a lista de texto: linha de chips-abas (um por provider com dado; siglas D5 + SF Symbol), view de detalhe por provider selecionado (windows com `ProgressView` + countdown Text, totais hoje/30d de `HistoryQueries`, `Chart` 30d lazy, botão add-account). Pacing novo em Core: `PacingEngine` (regressão linear sobre `daily_agg` → fração projetada vs. janela → "esgota em Xh Ym" ou "déficit N%"), clock-injetável. Multi-conta: scaffold de registry (`accounts` table já existe no schema §6) com add/remove/ativa para providers com capabilities `.multiAccount` — F4 entrega o mecanismo + UI; troca efetiva de credencial por provider é F5 (quando Cursor/OpenRouter entrarem).

**Tech Stack:** Como F3 + SF Symbols (sem asset catalog — CLT-safe).

**Spec:** `docs/specs/2026-09-02-design.md` (§8 painel/sparkline — agora cumprido por inteiro; §12-F4 multi-conta/alertas; trend da §12-F5 antecipado) + `docs/decisoes-f3.md`

## Global Constraints

- Todas as herdadas (macOS 14+, Swift 6 strict, CLT-only, credenciais read-only, fixtures sintéticas, Swift Testing via `./run-tests.sh`, E2E heartbeat, single-flight, cursor/DB por provider).
- **Ruling F4-SCOPE** (usuário, screenshot): painel rico prioritário; alertas notificáveis (spec F4 original) deslizam para F5 junto com Cursor/OpenRouter/Copilot; status page e "Armazenamento" fora de escopo (sem fonte de dados).
- **Orçamento RAM**: painel é `.window` e já é lazy; o chart do painel carrega MÁXIMO 30 pontos agregados (daily_agg, nunca eventos crus); views de detalhe só existem com painel aberto.
- **Pacing honesto**: rotulado "estimado com base no uso — não é uma previsão garantida" (padrão do referencial); <2 pontos de dados → sem pacing (nil, sem chute); janela sem `resetsAt` → só contagem.
- Nenhum dado novo de rede nesta fase — tudo vem do SQLite + snapshots existentes.
- UI strings EN; docs PT-BR.

## Tasks

### Task 1: PacingEngine (Core)
- `Sources/TokenBarCore/Pacing/PacingEngine.swift`: dado `[day: TokenSums]` (daily_agg do provider), janela `UsageWindow` (usedFraction, resetsAt) e `now`: regressão linear simples dos últimos 14 dias → taxa/dia → fração projetada no fim da janela → `PacingForecast { exhaustedIn: TimeInterval?, projectedFraction: Double, deficitPct: Double? }`; <2 pontos → nil; janela sem resetsAt → pacing contra 100% do limite diário implícito? NÃO — nil (sem chute).
- Testes com fixtures sintéticas: tendência crescente/flat/decrescente, 0-1 pontos, janela sem reset, boundary de dias.
- Commit: `feat(core): pacing engine com regressão sobre agregados`

### Task 2: Painel rico — abas + detalhe
- `Sources/TokenBarUI/ProviderPanelView.swift`: chips-abas (sigla D5 + ícone SF Symbol por provider, provider selecionado destacado), scroll de detalhe: header (nome + "updated Xs ago" + auth badge), seção de janelas (`WindowBarRow`: ProgressView + "Semanal 74% usado" + "Renova em 6d 16h" countdown relativo), seção custos (Hoje ~$X · 30d ~$Y + tokens 30d), pacing row quando forecast existe ("Estimado — esgota em 2h 44m"), `Chart` 30d lazy (daily_agg), botões (Refresh, Analytics…, Export…, Quit) preservados.
- `MenuBarContent`/`SnapshotStore` ganham o estado de seleção e os dados de detalhe (30d totals + série) carregados 1×/ciclo fora da MainActor; countdown atualiza por Timer de 30s SÓ com painel aberto.
- Testes: view-model puro (seleção, dados de detalhe, countdown formatting, pacing row conditional); visual fica p/ QA T5.
- Commit: `feat(ui): painel rico com abas, barras de janela e pacing`

### Task 3: Multi-conta — registry + "+ Add account"
- `accounts` table (§6) vira fonte de `discoverAccounts()` para providers `.multiAccount`-capable: UI "+ Add account…" → sheet com formulário (label + credential path override ou API key em keychain? NÃO keychain nesta fase — o formulário grava path/label no registro; resolução de credencial continua read-only nos paths registrados). Provider sem suporte → botão oculto.
- Refresh de contas no ciclo; conta ativa por provider (toggle no painel).
- Testes: registry CRUD, wiring de contas múltiplas com 2 fixtures de credencial sintéticas (Codex aceita 2 auth files via paths registrados), degradação de conta inválida.
- Commit: `feat(accounts): registry multi-conta com add/remove e conta ativa`

### Task 4: E2E + QA + Red Team + docs
- E2E: heartbeat estendido com pacing/30d? — heartbeat v2+fields aditivos (30d totals); cenários F3 mantidos; painel rico validado por QA visual (screenshot se Screen Recording liberado).
- QA 6/6: abas renderizam, barra semanal com countdown, pacing presente p/ provider com histórico, add-account sheet abre e registra, analytics/export intactos.
- Red Team: pacing com dados adversariais no DB (valores negativos/gigantes → sem crash/sem forecast absurdo), countdown com resetsAt no passado, 30 contas registradas, sheet com paths inválidos.
- Docs: `docs/decisoes-f4.md`, README (painel/multi-conta), spec §8 emenda (paridade cumprida).
- Commit: `test(f4): e2e, QA e Red Team do painel rico` + `docs: decisões F4`

**Critério de pronto:** painel com abas/barras/countdown/pacing/chart 30d/hoy+30d custos ✓ · "+ Add account" registra e aparecem contas no ciclo ✓ · orçamento RAM mantido ✓ · gates verdes ✓ · docs ✓
