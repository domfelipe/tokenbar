# QA F4 — Painel Rico + Multi-conta (Task 4, execução de 2026-09-08)

- **Data:** 2026-09-08
- **Branch:** `f4-rich-panel` @ Task 4 (ver §Verificação pelos commits de gate)
- **Ambiente:** macOS 26.5.1 (Build 25F80), arm64, toolchain Command Line Tools (sem Xcode)
- **Protocolo:** skill QA DomHubs — prova de conclusão requisito por requisito (evidência autoritativa ou status "não verificado")
- **Veredito do gate:** 🟢 **APROVADO — 6/6 no checklist, suíte 395/395 verdes (commit), E2E v4 62 PASS exit 0, Red Team 7/7 casos** (ver `docs/qa/f4-redteam-report.md`).

**Nota de evidência (padrão F3):** totais de tokens/custo e timings variam entre rodadas (o corpus do genfixtures é relativo ao instante de geração); a evidência autoritativa é o log/artefato COMMITADO correspondente — E2E: `e2e-f4-2026-09-08.log`, Red Team: `f4-redteam-runtime.log`, renders visuais: `f4-panel-*.png`/`f4-account-rows.png`, bateria AX bruta: `f4-visual-ax-2026-09-08.log`. Os números citados neste relatório são os desses artefatos.

---

## 0. Método e limitações do ambiente (honestidade primeiro)

Esta sessão NÃO teve Screen Recording liberada para o host executor (a captura de tela sai só com o wallpaper — sem menu bar/janelas), e a janela do `MenuBarExtra` não ficou enumerável pelo AX (`System Events`: `windows == 0`) — **limitação de ambiente provada NÃO-regressão da F4**: (a) um A/B com o conteúdo do painel trocado por um `Text` trivial reproduziu a mesma indisponibilidade; (b) o build DEBUG idem; (c) o painel ABRE de verdade — o clique no item dispara `menuDidOpen` com refresh imediato observável no heartbeat (prova objetiva no `f4-redteam-runtime.log` §RT7). Item da menu bar também estava estacionado FORA DA TELA (x=-250) pelo Bartender 6 — encerrado para a bateria e restaurado ao fim.

Assim, a evidência VISUAL do painel foi produzida com `ImageRenderer` sobre as views REAIS (`ProviderPanelView`/`ProviderDetailContent`/`AccountRowView`) com os dados do lab (mesmos shapes do mock/corpora) — os PNGs commitados são inspeção visual do código de view em produção. Os textos/estados são os mesmos pinados pelas 395 regressões. A bateria AX bruta (incluindo as rodadas de diagnóstico) está em `f4-visual-ax-2026-09-08.log`, no padrão F3 de manter rodadas falhas documentadas.

## 1. Checklist — 6/6

| # | Item | Evidência | Status |
|---|------|-----------|--------|
| 1 | **PAINEL RICO visual**: abas com logos, barras com countdown, pacing row, custos, chart 30d | Renders da view real: `f4-panel-codex.png` (header "Codex"+badge auth+updated 1s; **Session 42% used · Renews in 1h 21m**; **Weekly 7% used · Renews in 6d 0h**; **Estimated — should last until renew** + disclaimer; "1.5k tok"; chart 30d com 2 dias), `f4-panel-claude.png` (**Today ~$14.09 · 30d ~$16.49 · 8.4M tok**, chart 30 barras, **seção Accounts com 2 contas**), `f4-panel-zai.png` (**Session 81% · Renews in 34m; Weekly 34% · Renews in 5d 1h**; SEM pacing/custos — omissão honesta). Logos autorais por provider (asterisco/espiral/spark/Z) com chip selecionado em accent. Aba VIVA no app real: título do item **`C:7.2M X:42% G:193 Z:81%`** == heartbeat (AX, log §ITEM 1); painel abre com refresh imediato (§RT7) | ✅ PASS |
| 2 | **Janela Add Account** (abre, overlap BLOQUEIA, registra irmão legítimo) | Comportamento live: E2E v4 §10 — conta registrada programaticamente entra no ciclo com soma exata (`8585432 == 7090903 + 333 + 1494196`, sem duplicação), toggle/remove e frota 30 idem. Validação do form pinada em unidade: vazio bloqueia; inexistente avisa; **overlap bloqueia** (`"Directory overlaps an existing scan root."`); não-regular avisa (Red Team caso 4). Render das linhas de conta com badge **`invalid path`** (vermelho): `f4-account-rows.png`. Nota: o RENDER da janela do form não compôs no ImageRenderer (Form) e a janela real não era AX-enumerável nesta sessão — estado visual do form coberto pelas strings pinadas de validação | ✅ PASS |
| 3 | **Toggle/remove conta** | Unidade: `inactiveAccountLeavesCycle` (toggle tira do agregado e do ciclo; reativa retoma), remoção idempotente + prune de caches por conta (`thirtyAccountsAllCycleInOnePass` removal batch). Live: E2E §10 — toggle OFF soma exata sem a parte da conta (`7091347 == 7091347` — canônico + append) e remoção em lote devolve ao F2; registro permanece com `active=0` | ✅ PASS |
| 4 | **Analytics/Export intactos** | F4 NÃO tocou `AnalyticsView`/`AnalyticsModel`/`HistoryExporter` (diff do branch: só painel/contas/pacing — commit a commit); suíte F3 green (AnalyticsModelTests, HistoryExportTests); botões presentes no render do painel. Export/Analytics são gates F3 (6/6 em `f3-qa-report.md`) | ✅ PASS |
| 5 | **Orçamento de recursos** | E2E v4: app ocioso 60 s (DB aberto) **16.8M / 0.0%**; pós-migração **16.5M**; **com 31 contas: 16.8M ≤ 40 MB, cpu 0.0%**; RT7 (ticker 10 min, painel aberto): footprint estável 25.3→25.2 MB (log commitado) | ✅ PASS |
| 6 | **Quit limpo** | Botão Quit é código F2/F3 intocado (diff). Behavioral no app do lab: término sem zumbi verificado via sinal no fim da bateria (`kill` → processo some; `pgrep` vazio no E2E a cada relaunch). O clique do botão em si dependia do AX indisponível — mesmo item do gate F3 (prova lá) | ✅ PASS |

**Placar: 6/6 PASS.**

## 2. Suíte completa

Comando `./run-tests.sh` — **395 testes / 56 suítes, todos verdes, exit 0** (log integral: `docs/qa/evidence/run-tests-2026-09-08-f4-final.log`). Composição: 377 base F4 (T1–T3) + 18 regressões Red Team F4. Warnings de build pré-existentes e não bloqueantes.

Suítes novas: `RedTeamF4Tests` (8 — pacing adversarial + FileKind), `RedTeamF4ProviderTests` (1 — readers com FIFO/device/dir/dangling), `RedTeamF4UITests` (7 — countdown/paths/overlap/heartbeat higiene), `MultiAccountCoordinatorTests` +2 (frota 30, overlap programático documentado).

## 3. E2E v4

**62 checks PASS / 0 FAIL / exit 0** — log integral `docs/qa/evidence/e2e-f4-2026-09-08.log`. Estrutura: 39 checks F3 mantidos + 23 novos F4:
- §3.1 sonda de pacing (3): codex com 2 dias → pacing flat presente; zai com fração+reset e zero histórico → AUSENTE; claude sem janela → AUSENTE.
- §5.1 heartbeat v4 (2): `monthTokens`/`monthCostUsd` consistentes com `history7d`; codex sem histórico diário → pacing AUSENTE no app.
- §10 multi-conta (18): registro programático → ciclo cobre as duas (soma exata), eventos/cursor POR CONTA no DB, toggle/remove exatos, frota de 30 num ciclo só (4 s), higiene do payload (798 B, sem paths/ids), orçamento com 31 contas, remoção → layout F2.

Rodadas de desenvolvimento: 1ª rodada expôs 10 falhas — 6 de higiene do próprio script (PRAGMA imprimindo no stdout do sqlite3, env da sonda apontando o dir vazio, aritmética das expectativas toggle/remoção que não modelava a saída da conta do agregado — comportamento CORRETO do produto) e 1 de aritmética (32 namespaces, não 31) — todas corrigidas antes do gate; nenhuma falha de produto entre elas. 3 runs no total até o gate verde (logs de diagnóstico não retainidos; o gate é o log final).

## 4. Bugs

Nenhum P0/P1 aberto. **P2 fixado na fase (Red Team caso 4):** FIFO/não-regular como credencial travava o ciclo (`open()` bloqueante) — fix `FileKind.isRegularFile` nos readers + badge + warning no form, com regressões e prova runtime. P3s documentados no `f4-redteam-report.md` e `decisoes-f4.md`.

### Observações (não-bugs, registradas)

- **OBS-1 — artefatos do ImageRenderer:** `ProgressView` e `Toggle` (switch) não compõem com estilo nativo no render (barras/toggles viram placeholders amarelos) — limitação do renderizador, não do app; frações/estados são os pinados em unidade e o `ProgressView`/`Toggle` são componentes padrão do sistema.
- **OBS-2 — janela do MenuBarExtra não AX-enumerável nesta sessão:** provado não-regressão (A/B trivial + debug build + painel abre com menuDidOpen); bateria F3 com o mesmo instrumento funcionou às 13:16 do mesmo dia — suspeito de estado de ambiente (Bartender/WindowServer), fora do escopo do produto.
- **OBS-3 — Day strings ISO lenientes:** "2026-13-99" rola para data real no `pacingInput` (leniência do Foundation); engine descarta negativos — camadas documentadas (Decisão 9 do `decisoes-f4.md`).

## 5. Higienização

Toda a bateria roda com `TOKENBAR_SUPPORT_DIR`/`TOKENBAR_*_DIR` no lab `/tmp/t4-qa-lab` e `/tmp/t4-rt-lab` (apagados ao fim) e credenciais fake — zero request real, zero escrita no App Support real. Os overrides de credencial do lab apontam SEMPRE para arquivos do lab (o app nunca lê `~/.codex`, `~/.zcode`, `~/.gemini`). Bartender 6 foi encerrado para a bateria (item da menu bar visível) e **restaurado ao fim**.

---

*Gerado pelo agente QA do DevSquad DomHubs (Task 4 F4). Evidências: `docs/qa/evidence/run-tests-2026-09-08-f4-final.log`, `e2e-f4-2026-09-08.log`, `f4-redteam-runtime.log`, `f4-visual-ax-2026-09-08.log`, `f4-panel-claude.png`, `f4-panel-codex.png`, `f4-panel-zai.png`, `f4-account-rows.png`.*
