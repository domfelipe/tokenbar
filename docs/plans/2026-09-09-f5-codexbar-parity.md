# TokenBar F5 — Paridade CodexBar (alertas, settings, providers extras) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fechar o gap com a referência do usuário: notificações de limite, janela de Settings (⌘,) com launch-at-login, os providers da barra de referência (Cursor, OpenRouter, Qwen/Alibaba, Antigravity, DeepSeek, Grok) e polish de densidade do painel — tudo sobre o motor F2–F4 (history, pacing, multi-conta).

**Architecture:** `AlertEngine` (Core) avalia thresholds sobre os snapshots do ciclo e dispara `UNUserNotificationCenter` com dedupe por (provider, conta, janela, threshold) até reset; settings persistem em `settings` (SQLite) + `SettingsWindow` (SwiftUI `Settings` scene) edita intervalos, thresholds, providers visíveis no menu bar e launch-at-login (`SMAppService`); novos providers = módulos `UsageProvider` com endpoints portados da referência MIT (CodexBar `Sources/CodexBarCore/Providers/<X>/`), cada um com fixture-replay e degradação local-first (credencial ausente = some da barra, nunca erro).

**Tech Stack:** Como F4 + UserNotifications + SMAppService.

**Spec:** `docs/specs/2026-09-02-design.md` (§8 alertas/settings — agora cumpridos; §12-F5) + `docs/decisoes-f4.md`

## Global Constraints

- Todas as herdadas (macOS 14+, Swift 6 strict, CLT-only, credenciais read-only nunca logadas, fixtures sintéticas `fake-*`, Swift Testing via `./run-tests.sh`, E2E heartbeat, single-flight por provider×conta, cursor/hwm/ledger por conta, orçamento RAM ≤40MB/CPU <0,5%).
- **Ruling F5-SCOPE** (usuário: "idêntico ao CodexBar" / "vamos terminar"): providers extras limitados aos 6 acima (portados da referência MIT com endpoints documentados em `docs/specs/f5-providers.md`); os outros ~50 da referência ficam como exercício de contribuição (o protocolo é o guia). Trend já entregue (F4). Alertas de reset = lembrete opcional por provider.
- **Notificações pedem permissão** (UNUserNotificationCenter) — pedido na 1ª ativação de alerta nas settings, nunca no launch; sem permissão → alerts off honesto na UI.
- **Launch at login**: `SMAppService.mainApp.register()` com feedback de erro na UI (nunca crash).
- Endpoints portados: SEMPRE com fonte (path do arquivo MIT da referência) citada no módulo + em `docs/specs/f5-providers.md`; degradação por provider isolada (provider novo quebrado NÃO afeta os existentes).
- UI strings EN; docs PT-BR; nenhum artwork de terceiro (sigla D5 como logo fallback dos novos providers até contribuições autorais).

## Tasks

### Task 1: AlertEngine + notificações
- `Sources/TokenBarCore/Alerts/AlertEngine.swift`: thresholds default [50,75,90,95]% (configuráveis), avaliação sobre `UsageWindow.usedFraction` por provider×conta a cada ciclo; estado de dedupe em `alert_rules`/settings (dispara 1× por threshold até fração cair abaixo ou reset); lembrete opcional N min antes de `resetsAt`.
- Wiring: `UNUserNotificationCenter` (permissão pedida só ao ativar alerts nas settings); sem permissão → estado honesto na UI.
- Testes: thresholds/dedupe/re-arm, reset reminder scheduling, clock injetado.
- Commit: `feat(alerts): engine de thresholds com dedupe e notificações`

### Task 2: Settings window (⌘,) + launch at login
- `Settings` scene: geral (launch at login via SMAppService, intervalos de refresh menu/ocioso), alertas (on/off global, thresholds por slider, lembrete de reset), menu bar (quais providers aparecem no texto), persistência em `settings` (SQLite) — lida pelo coordinator (intervalos vivos, sem restart).
- Testes: roundtrip settings, efeito de intervalo no scheduler (clock virtual), launch-at-login registro/erro honesto.
- Commit: `feat(settings): janela de ajustes com launch at login e config de alertas`

### Task 3: Providers batch A — Cursor + OpenRouter (referência MIT)
- Descoberta (T3 inclui): endpoints em `Sources/CodexBarCore/Providers/{Cursor,OpenRouter}/` da referência → `docs/specs/f5-providers.md` (fonte citada).
- `CursorProvider` (session token de `~/.cursor` — read-only), `OpenRouterProvider` (API key: entrada manual na UI multi-conta existente; capabilities `.multiAccount` real).
- Fixtures sintéticas fixture-replay; degradação local-first; siglas D5 (cursor=U, openrouter=O).
- Commit: `feat(providers): Cursor e OpenRouter via referência MIT`

### Task 4: Providers batch B — Qwen/Alibaba + Antigravity + DeepSeek + Grok
- Mesma disciplina (referência MIT; credenciais locais quando existirem, entrada manual quando API key; modo local/degradação quando não há dado).
- Siglas D5: qwen/alibaba=Q/A?, antigravity=A, deepseek=D, grok=G→ conflito com gemini! → usar tabela D5 estendida: {alibaba: A, antigravity: V, deepseek: D, grok: K} (decidir no T4 e documentar em decisoes-f5).
- Commit: `feat(providers): Qwen, Antigravity, DeepSeek e Grok via referência MIT`

### Task 5: UI polish + Codex credits (se o dado existir)
- Passada de densidade no painel (referência: screenshot do usuário — tipografia/espaçamento/barra estilo); linha "credits" do Codex SE os extras do `wham/usage` (additional_rate_limits/credits) trouxerem o dado (investigar; se não existir no payload → registrar e pular, sem invenção).
- Commit: `feat(ui): polish de densidade e credits do codex (se aplicável)`

### Task 6: E2E v5 + QA + Red Team + docs
- E2E: cenários F4 + provider novo com mock + alerta disparado (permissão de notificação em teste = flag interna de captura, sem UNUserNotificationCenter real no e2e).
- QA 6/6 (evidência autoritativa, padrão F3/F4) · Red Team: alert storm (fração oscilando 94-96%), 50 providers em settings, settings corrompidas → defaults, providers novos com respostas hostis · docs: `docs/decisoes-f5.md`, README (providers), spec §8/§12 emendas.
- PROVAS FINAIS: `./run-tests.sh` && `./scripts/e2e.sh`.
- Commits: `test(f5): e2e v5, QA e Red Team` + `docs: decisões F5 e README`

**Critério de pronto:** alertas notificam com dedupe ✓ · Settings ⌘, funcional (launch at login, intervalos, thresholds) ✓ · 6 providers novos com degradação isolada ✓ · painel na densidade da referência ✓ · gates verdes ✓ · docs ✓
