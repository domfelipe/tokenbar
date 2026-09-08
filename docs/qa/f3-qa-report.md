# QA F3 — SQLite + Histórico + Custo + Analytics (Task 5, execução de 2026-09-08)

- **Data:** 2026-09-08
- **Branch:** `f3-sqlite-history-analytics` @ `a133df6` + commits de teste/docs desta task (ver §Verificação)
- **Ambiente:** macOS 26.5.1 (Build 25F80), arm64, toolchain Command Line Tools (sem Xcode)
- **Protocolo:** skill QA DomHubs — prova de conclusão requisito por requisito (evidência autoritativa ou status "não verificado")
- **Veredito do gate:** 🟢 **APROVADO — 6/6 no checklist manual, suíte 304/304 verdes, E2E v3 39 PASS exit 0, Red Team 7/7 casos** (ver `docs/qa/f3-redteam-report.md`). Nenhum item ficou "não verificado".

---

## 1. Resumo por requisito (critério de pronto, spec §12-F3)

| # | Requisito | Evidência | Status |
|---|-----------|-----------|--------|
| 1 | Suíte completa (`./run-tests.sh`) | **304 testes / 37 suítes, todos verdes, exit 0** — log integral em `docs/qa/evidence/run-tests-2026-09-08-f3-final.log`. Composição: 296 (baseline T4) + 1 pin do fix T4 (`selfcheckModeWithOwnSupportDirectoryIncludesHistory7d`) + 7 regressões Red Team (4 `RedTeamF3Tests` + 3 `CoordinatorRedTeamTests`... ver [f3-redteam-report](f3-redteam-report.md) §Regressões) | ✅ PASS |
| 2 | Build do app (`./scripts/make-app.sh release`) | Usado pelo E2E (seção 4): `build/TokenBar.app` release com codesign ad-hoc; o E2E lança ESTE bundle nos 3 launches (fase 1, migração, re-run) | ✅ PASS |
| 3 | Gráficos 24h/7d/30d corretos vs. ingest | E2E §7.5 (6 checks): série 3d == série 7d == `history7d` do heartbeat (8.186.848); série 1d == `todayTokens` (claude 4.288.222, gemini 193); custo computado > 0; CSV parseado de volta == JSON. Painel via AX: **`C Claude: 37.8k hoje ~$0.10 · 7d: 63.1k ~$0.16 (local)`**. Analytics renderizada: janela "TokenBar Analytics" com barras Tokens/Cost per day nos 3 períodos — screenshot da janela em `docs/qa/evidence/f3-analytics-window-2026-09-08.png` | ✅ PASS |
| 4 | Custo ~USD exibido | Painel AX: `~$0.10`/`~$0.16` (claude), `~$0.0003` (gemini); heartbeat v3: `todayCostUsd: 0.10211085`, `history7d.costUsd: 0.1571421`; export: `cost_usd` por evento coerente CSV↔JSON (soma de tokens igual nos dois formatos) | ✅ PASS |
| 5 | Migração de cursores sem perda | E2E §9 (cenário b): cursors.json legado F2 na support dir (extraídos do banco da fase 1, byte-fiel ao formato F2) → renomeados `.migrated`, totais do heartbeat EXATOS pós-migração (claude 4.288.222 == 4.288.222, gemini 193 == 193 — não zero, não dobrado), sem backfill no banco (history 7d `[]`), evento novo persiste exatamente 1× (300 tokens, 1 evento), re-run do 3º launch idempotente | ✅ PASS |
| 6 | Orçamento de performance mantido | E2E §8 (app ocioso 60s, DB aberto): phys_footprint **17.6 MB** ≤ 40 MB, cpu **0.0%** ≤ 0.5%. E2E §9 (app re-aberto pós-migração): 16.8 MB / 0.0%. Red Team caso 7 (ingest de 100k eventos): pico **29.6 MB** ≤ 40 MB, DB **17.6 MB** < 20 MB, query history durante ingest **2.92 s** (fora da MainActor), estacionário 17.2 MB / 0.0% | ✅ PASS |
| 7 | E2E v3 completo | **39 checks PASS, 0 falhas, exit 0** — log integral em `docs/qa/evidence/e2e-f3-2026-09-08.log` | ✅ PASS |
| 8 | Docs | `docs/decisoes-f3.md` (9 decisões + minors), README (seção History/cost/export), emenda §6 da spec (pricing sobrescrita não implementada) — commit `docs:` | ✅ PASS |

**Placar do checklist manual: 6/6 PASS.** Evidência bruta integral: [`docs/qa/evidence/f3-visual-ax-2026-09-08.log`](evidence/f3-visual-ax-2026-09-08.log).

---

## 2. Checklist manual via AX — 6/6

Mesmo instrumento da F2 (System Events; Accessibility concedida). A janela Analytics desta vez pôde ser fotografada: **Screen Recording liberada** — captura POR JANELA via `screencapture -l <CGWindowID>` (a captura de tela inteira foi descartada por conter conteúdo alheio; a da janela só contém o TokenBar). Os botões do painel continuam anônimos no AX (idem OBS-4 da F2) — identificados por posição com prova funcional.

| # | Item | Evidência | Status |
|---|------|-----------|--------|
| 1 | Item na menu bar com providers | AX `menu bar 2`: **`C:37.8k G:193`** == heartbeat `menuBarText` == texto do selfcheck (mesma pipeline). API-driven ausentes (sem credencial → `.missing`, sem request — spec §5) | ✅ PASS |
| 2 | Painel `.window` com custo ~$ e linha 7d | `{AXWindow, AXSystemDialog}`; textos: **`C Claude: 37.8k hoje ~$0.10 · 7d: 63.1k ~$0.16 (local)`** · **`G Gemini: 193 hoje ~$0.0003 · 7d: 193 ~$0.0003 (local)`** — custo e 7d em linha, custo `~` prefixado | ✅ PASS |
| 3 | **Janela Analytics abre a partir do menu e renderiza** (pendência visível das T3/T4) | Clique no botão 2 do painel → janela **`TokenBar Analytics`** (AX: name + geometria 640×532; screenshot `f3-analytics-window-2026-09-08.png` mostra os charts: seletor 24h/7d/30d, "Tokens per day", "Estimated cost per day", "Top models"). Processo vivo com a janela aberta. Fechar descarta (código `windowWillClose` pina o ciclo de vida; orçamento coberto pelos gates de RAM) | ✅ PASS |
| 4 | Export gera arquivo válido em `<support>/exports` | Clique no botão 3 → `history-20260908-161607.csv` (438 B) + `.json` (1.360 B). Validados com parser externo: CSV 6 linhas (header `ts,provider,account,model,tokens,cost_usd`), JSON `version: 1`/`period.days: 30`, soma de tokens idêntica nos dois formatos, custo por evento presente | ✅ PASS |
| 5 | Refresh responde; app vivo | Botão 1 → heartbeat `updatedAt` **2026-09-08T16:43:41Z → 16:43:43Z**, processo vivo — log bruto da rodada bem-sucedida: [`docs/qa/evidence/f3-visual-ax-2026-09-08-refresh-quit.log`](evidence/f3-visual-ax-2026-09-08-refresh-quit.log) | ✅ PASS |
| 6 | Quit pelo painel → sem zumbi | Botão 4 → `pgrep` **vazio** (mesmo log, `ITEM 6 PASS`) | ✅ PASS |

**Achado de continuidade (F2 mantido):** restart mid-day no MESMO support preservou o dia — `menuBarText = "C:37.8k G:193"` idêntico no relançamento (snapshot do ledger + cursores migrados para o DB, Red Team F2 caso 7 continua valendo com o store em SQLite).

### Higienização

Todo o checklist roda com `TOKENBAR_SUPPORT_DIR`/`TOKENBAR_*_DIR` apontando para `/tmp/t5-qa-lab` (apagado ao fim) e credenciais ausentes — zero request de API, zero escrita no App Support real. O screenshot de tela inteira tirado durante a bateria continha conteúdo alheio ao teste e foi **apagado sem commitar**; a evidência visual final é a captura por janela (só o TokenBar).

---

## 3. Suíte completa (saída integral)

Comando: `./run-tests.sh`. Log integral: `docs/qa/evidence/run-tests-2026-09-08-f3-final.log`.

```text
✔ Test run with 304 tests in 37 suites passed after 25.764 seconds.
EXIT=0
```

Suítes novas nesta task (7 testes): `RedTeamF3Tests` (4 — DB corrompido/truncado, re-migração stale, export hostil 10k RFC 4180, SQL injection), `CoordinatorRedTeamTests` (2 — degradação F2 com DB corrompido e support readonly) e o pin `selfcheckModeWithOwnSupportDirectoryIncludesHistory7d` (1 — fix T4; breakdown completo no relatório Red Team). Warnings de build pré-existentes e não bloqueantes (idênticos às execuções anteriores).

## 4. E2E v3 (saída integral)

Log integral: `docs/qa/evidence/e2e-f3-2026-09-08.log` — **39 PASS / 0 FAIL / exit 0**. Estrutura:

- Cenários F2 mantidos: mock no ar (2), selfcheck v2 com mock e sob 500 (4), app real + heartbeat v2 (4), live update (1), degradação mock morto (2), contador de retry storm por atribuição de token (3), selfcheck pós-morte (1), orçamento 60s (3).
- **Novos F3:** selfcheck v3 `history7d` (1) — cenário (c), pin do fix T4; histórico consistente (6) — cenário (a); migração + re-run + orçamento pós-migração (10) — cenário (b) + Red Team caso 3.

Durante o desenvolvimento do E2E v3, a 1ª rodada expôs 5 FAILs de higiene do próprio script (heartbeat parcial por publish-per-provider e comparação de janelas cega) — corrigidos antes do gate; nenhuma falha de produto (log da rodada de diagnóstico não retainido; o gate é o log final).

## 5. Bugs

Nenhum P0/P1 aberto. O fix herdado da T4 (selfcheck não criava support dir → `history7d` sempre omitido) foi entregue no commit `a133df6` com pin de regressão e validação E2E (cenário c). A alegação falsa da Decisão 6 do report T4 foi corrigida no próprio `task-4-report.md`.

### Observações (não-bugs, registradas)

- **OBS-1 — botões anônimos no AX:** idem F2 OBS-4; identificação por posição (1=Refresh, 2=Analytics, 3=Export, 4=Quit) com prova funcional em cada.
- **OBS-2 — itens 5/6 exigiram 2ª rodada (painel fechado pós-Analytics):** na 1ª rodada o painel (MenuBarExtra) fechou quando a janela Analytics ganhou foco; os cliques de Refresh/Quit seguintes falharam com "Índice inválido" e o `pgrep` ficou vivo — esse log é o [`f3-visual-ax-2026-09-08.log`](evidence/f3-visual-ax-2026-09-08.log) (mantido como registro, incluindo os itens 1–4 PASS da mesma rodada). Os itens 5/6 foram RE-EXECUTADOS sobre o mesmo suporte em janela recém-aberta — log bruto autoritativo: [`f3-visual-ax-2026-09-08-refresh-quit.log`](evidence/f3-visual-ax-2026-09-08-refresh-quit.log), com os valores citados na tabela acima. **Nota geral de evidência:** totais de tokens/custo variam entre rodadas (o corpus do genfixtures é relativo ao instante de geração); quando este relatório cita números, a evidência autoritativa é o log commitado correspondente — E2E: `e2e-f3-2026-09-08.log`, Red Team: `f3-redteam-runtime.log`, painel: os dois logs AX citados acima.
- **OBS-3 — `history7d ≥ todayTokens` no selfcheck:** o corpus do genfixtures tem eventos de até 24h no passado (podem cair no dia de ontem local); a janela 7d inclui, o "hoje" não. Os checks do E2E comparam por janela (decisão 9 do `decisoes-f3.md`).
- **OBS-4 — custo do corpus no painel QA depende da tabela de preços:** `claude-sonnet-4-6` e `gemini-2.5-flash` estão precificados; se um modelo novo do corpus não estiver, o campo de custo desaparece (NULL ≠ 0 — correto por decisão 5 do `decisoes-f3.md`).

---

*Gerado pelo agente QA do DevSquad DomHubs (Task 5 F3). Evidências: `docs/qa/evidence/run-tests-2026-09-08-f3-final.log`, `e2e-f3-2026-09-08.log`, `f3-visual-ax-2026-09-08.log`, `f3-analytics-window-2026-09-08.png` + `docs/qa/evidence/f3-redteam-runtime.log`.*
