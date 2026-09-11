# QA F5 — Paridade CodexBar: polish/credits + alertas/settings/providers (Tasks 6–7, execução de 2026-09-10)

- **Data:** 2026-09-10
- **Branch:** `f5-codexbar-parity` @ Tasks 6–7 (commits de gate no §Verificação)
- **Ambiente:** macOS 26 (arm64), toolchain Command Line Tools (sem Xcode)
- **Protocolo:** prova de conclusão requisito por requisito (evidência autoritativa commitada — valores citados == logs commitados)
- **Veredito do gate:** 🟢 **APROVADO — 6/6 no checklist, suíte 565/565 verdes (exit 0), E2E v5 81 PASS / 0 FAIL / exit 0, Red Team fechado** (ver `docs/qa/f5-redteam-report.md`).

**Nota de evidência (padrão F3/F4):** os números citados neste relatório são os dos artefatos COMMITADOS — suíte: `docs/qa/evidence/run-tests-2026-09-10-f5-final.log` ("Test run with 565 tests in 90 suites passed"), E2E: `docs/qa/evidence/e2e-f5-2026-09-10.log` ("concluído: 0 falha(s)", 81 PASS), renders: `f5-panel-codex-t6.png` e `f5-design-side-by-side-t6.png`.

---

## 1. Checklist — 6/6

| # | Item | Evidência | Status |
|---|------|-----------|--------|
| 1 | **PAINEL 1:1 com a referência + linha de alertas honesta** | Render da view real com os dados do lab: `f5-panel-codex-t6.png` — header ("Codex" + "Updated just now" + badge auth), barra segmentada (**Weekly 74% used · Renews in 6d 16h**) com faixa de pacing vermelha, meta **"69% in deficit · Exhausts in 2h 44m"**, linha **"Credits: $4.20"** (T6 — só com saldo real), KPIs (**$0.00 / $1,116.52 / 216M / 8.9B**), chart com pico **$282**, detalhes ("Last 7 days: $585.43 · 3.1B tokens", "Top model: gpt-5.6-sonnet", disclaimer), ações na ordem da referência (**Add account… → Usage dashboard → Export**) e rodapé Refresh ⌘R / Settings… ⌘, / About / Quit ⌘Q. Lado a lado com o screenshot da referência: `f5-design-side-by-side-t6.png`. Linha de alertas honesta: `alertsStatusText` pinado em unidade (enabled = silêncio; disabled/notConfigured/blocked = texto) — `NotificationGatewayTests`; estado REAL no e2e: `alertsStatus: "enabled"` no heartbeat com o gateway de captura (log §F5 alerts) | ✅ PASS |
| 2 | **SETTINGS abre e persiste** | Persistência e wiring vivo pinados em unidade: `SettingsModelTests` (roundtrip de intervalos/thresholds/visibilidade; leitura única da config via `AlertEngine.readConfig`; toggle de alertas chama `requestAuthorization` EXPLICITAMENTE) e `SettingsCoordinatorWiringTests` (intervalos persistidos viram estado inicial do scheduler sem restart; republish da visibilidade; aviso `requiresApproval` honesto). A janela vive na scene `Settings` via `\.openSettings` (SettingsView/SettingsMenuRow). Mesma limitação de ambiente da F4 (OBS-2 lá): a janela não é AX-enumerável nesta sessão — comportamento coberto pelas regressões acima + render das strings | ✅ PASS |
| 3 | **ADD ACCOUNT no provider novo** | `OpenRouterMultiKeyTests`: 2 contas registradas (1 key = 1 conta), descoberta merge, instância por key com saldos/janelas ISOLADOS e Bearer de cada request atribuído à própria key. `F5RegistrySmokeTests`: os 6 novos têm capability `.multiAccount` e conta registrada aparece na descoberta. O formulário é o mesmo da F4 (gates lá) | ✅ PASS |
| 4 | **PROVIDER DESABILITADO some honestamente** | `MenuBarContent` filtra por `visibleProviders` (provider fora do conjunto some do texto MESMO com dado); migração `visibleProvidersTouched` pinada em `AppSettingsTests` (banco legado sem flag → novos VISÍVEIS; flag presente → lista mandatória; lixo → default). Prova runtime: e2e §hermeticidade — com as credenciais da máquina neutralizadas, os providers sem dado NÃO aparecem no texto ("C:7.3M X:42% G:193 Z:81% O:49%", sem U/K/Q/V/D) | ✅ PASS |
| 5 | **SUÍTE COMPLETA** | `./run-tests.sh` — **565 testes / 90 suítes, todos verdes, exit 0** (log integral: `run-tests-2026-09-10-f5-final.log`). Novas suítes F5 T7: `RedTeamF5AlertTests`, `RedTeamF5SettingsTamperTests`, `RedTeamF5UITests` (overlap bypass + capture gateway + heartbeat), `RedTeamF5CaptureGatewayTests`, `RedTeamF5HostileProviderTests`, `OpenRouterMultiKeyTests` + regressões atualizadas (updatedText/credits, AppSettings migração, headers Alibaba, "10 providers") | ✅ PASS |
| 6 | **E2E v5** | **81 PASS / 0 FAIL / exit 0** — log integral `e2e-f5-2026-09-10.log`. Novos blocos F5: mock OpenRouter (/credits 62.80 + /key 49%), seed launch com plantio de `alerts:enabled` (substitute do toggle — ruling F5-NOTIF), **alerta disparado de verdade** via gateway de captura (EXATOS 2 disparos zai t50+t75, render EN real, identifiers de dedupe), dedupe persistido no relaunch com mock morto (ainda 2 linhas; erro não inventa alerta), heartbeat v5 (credits + alertsStatus), hermeticidade dos 6 novos (texto == C X G Z O) | ✅ PASS |

**Placar: 6/6 PASS.**

## 2. Entregas T6 (polish + credits) — onde estão as provas

- **Credits do Codex (veredito sem invenção):** `wham/usage` traz `credits.balance` (utilizável quando não nulo — já decodificado desde a F2); o inventário "Limit Reset Credits" da referência vem do endpoint DEDICADO `/wham/rate-limit-reset-credits` → documentado e PULADO. Linha "Credits: $X" no painel + campo `credits` no heartbeat só com saldo real. Doc: `docs/specs/f5-providers.md` § Codex; decisão: `docs/decisoes-f5.md` Decisão 6. E2E: openrouter 62.80 presente, codex/zai (balance null) com chave AUSENTE.
- **Ordem das ações / "Updated" / pin topModel7d:** carry-forwards do review T1 fechados (diff do commit `feat(ui)`); render de evidência atualizado.

## 3. Bugs e observações

Nenhum P0/P1 de produto aberto. Achados do gate (fixados nesta fase):
- **Hermeticidade do e2e (P1 do gate):** a máquina de execução tinha credenciais reais de Cursor e Grok — os runs 1–3 mostraram `U:19% K:11%` no texto e o app fez REQUEST REAL com credencial real durante o e2e. Fix: overrides de credencial apontando para arquivo inexistente no lab + env-only neutralizadas + check "texto == C X G Z O". (Detalhe no Red Team, caso 8.)
- **Seed launch (higiene do próprio script):** o CLI `history` só abre banco EXISTENTE — o banco do e2e passa a ser criado por um seed launch do próprio app (§2.5), que também planta `alerts:enabled`.
- P3s documentados sem fix: saldo negativo DeepSeek passa sem clamp (hostil; Decisão 10 do `decisoes-f5.md`); aviso de launch-at-login stale até reabrir a janela; slider persiste a cada passo.

## 4. Higienização

Toda a bateria roda com `TOKENBAR_SUPPORT_DIR`/`TOKENBAR_*_DIR` no `/tmp` (descartados ao fim) e credenciais 100% sintéticas (`fake-*`). As credenciais REAIS da máquina estão explicitamente NEUTRALIZADAS no e2e (arquivos inexistentes + env vazias — caso 8 do Red Team). Zero request real, zero escrita no App Support real, zero credencial em log/evidência.
