# QA F2 — Codex + Gemini + Z.ai (Task 8, re-execução de 2026-09-07)

- **Data:** 2026-09-07
- **Branch:** `t8-qa` @ `0ea655e` (wip do agente interrompido). **Conteúdo F2 verificado em `42d42e9` (`0ea655e~1`) — ver BUG-1.**
- **Ambiente:** macOS 26.5.1 (Build 25F80), arm64, toolchain Command Line Tools (sem Xcode)
- **Protocolo:** skill QA DomHubs — prova de conclusão requisito por requisito (evidência autoritativa ou status "não verificado")
- **Veredito do gate:** 🟢 **APROVADO no conteúdo F2 (`42d42e9`) · 🔴 BUG P0 BLOQUEANTE no HEAD do branch (`0ea655e`)** — o wip commit do agente interrompido **não compila** (erro de 1 linha, `AppState.swift:23`), o que impede suíte/build/launch **no HEAD**. Todo o conteúdo da F2 está em `42d42e9`, onde a re-execução completa desta QA passou: suíte **200/200 verdes**, build release OK, checklist manual **6/6** com evidência AX (System Events). Nenhum item ficou "não verificado". O fix de 1 linha é decisão do reconciliador (QA não mexe em código — §Bugs).

---

## 1. Resumo por requisito

| # | Requisito | Evidência | Status |
|---|-----------|-----------|--------|
| 1 | Suíte completa (`./run-tests.sh`, 184 esperado no brief) | **No HEAD (`0ea655e`): FALHA de compilação** — saída integral em [§2.1](#21-cabe-do-head---0ea655e) e `docs/qa/evidence/run-tests-2026-09-07-head-0ea655e-compile-error.log` (BUG-1). **No conteúdo (`42d42e9`): 200/200 testes em 23 suítes, todos verdes, exit 0** — log integral em [§2.2](#22-conteúdo-f2---42d42e9) e `docs/qa/evidence/run-tests-2026-09-07-head1-42d42e9-200pass.log`. Composição: 184 (baseline T7) + 15 regressões QA/Red Team + 1 (`staleSnapshotPathsAreNotRestored`, do `42d42e9`) — o "184" do brief é o número anterior às regressões | ✅ PASS (no conteúdo) / 🔴 FALHA (no HEAD — BUG-1) |
| 2 | Build do app (`./scripts/make-app.sh release`) | Em `42d42e9`: `Build complete! (59.41s)` → `OK: build/TokenBar.app`, codesign ad-hoc verificado (`Identifier=app.tokenbar.TokenBar`, arm64). No HEAD: impossível (mesmo BUG-1) | ✅ PASS (no conteúdo) / 🔴 BLOQUEADO (no HEAD — BUG-1) |
| 3a | Item na menu bar com providers, launch isolado | AX (System Events, processo identificado por unix id): `name of menu bar items of menu bar 2` → **`C:360.8k G:193`**. Heartbeat v2 mostra os 4 providers: `claude`/`gemini` `authState:"ok"` com tokens; **`codex`/`zai` `authState:"missing"`, `menuBar:null`** (sem credencial não há request — spec §5) e por isso **não aparecem na string do item** — degradação/ausência correta, sem crash | ✅ PASS |
| 3b | Clique no item → painel `.window` com linhas por provider + Refresh/Quit | `{role, subrole} of window 1` → `{AXWindow, AXSystemDialog}`. Linhas exatas: **`C Claude: 360.8k hoje (local)`** · **`G Gemini: 193 hoje (local)`** + 2 botões (anônimos no AX; identificados por posição e provados funcionalmente nos itens 3c/3e) | ✅ PASS |
| 3c | Refresh responde; app vivo | Clique no botão 1 → `updatedAt` do heartbeat avançou **20:12:49Z → 20:13:11Z**, processo vivo (`etime 01:08`), `menuBarText` estável | ✅ PASS |
| 3d | selfcheck v2 (binário do bundle, mesmos envs) == texto da menu bar | No mesmo minuto, 3 fontes idênticas: AX `"C:360.8k G:193"` == heartbeat `"C:360.8k G:193"` == selfcheck `"C:360.8k G:193"`; payload `providers.*` do selfcheck == heartbeat campo a campo (todayTokens claude=360760, gemini=193; codex/zai `missing`). Artefato: `docs/qa/evidence/f2-selfcheck-2026-09-07.json` | ✅ PASS |
| 3e | Quit pelo painel → sem zumbi (`pgrep`) | Clique no botão 2 (Quit TokenBar) — `AXPress` funcionou nesta execução, sem fallback: processo encerrado, `pgrep` **vazio** | ✅ PASS |
| 5 | Robustez: dir inexistente sem crash; corpus `--poison` consistente com selfcheck | **5a:** `TOKENBAR_CLAUDE_DIR=/tmp/t8-qa-f2/dir-que-nao-existe-qa` → vivo após 5s, heartbeat `G:193` (claude ausente, sem crash), TERM limpo. **5b:** corpus poison (30 eventos, seed 3) → selfcheck == app campo a campo (`C:276.2k G:193`, claude 276242, X/Z `missing`) — linhas inválidas ignoradas pela mesma pipeline. Artefato: `docs/qa/evidence/f2-poison-heartbeat-2026-09-07.json` | ✅ PASS |

**Placar do checklist manual: 6/6 PASS** (itens 3a–3e do brief + item 5 da convenção F1/F2). Evidência bruta integral: [`docs/qa/evidence/f2-visual-ax-2026-09-07.md`](evidence/f2-visual-ax-2026-09-07.md).

---

## 2. Suíte completa (saída integral)

### 2.1 Cabeça do HEAD — `0ea655e`

Comando: `./run-tests.sh` no worktree `t8-qa` @ `0ea655e`. **Exit 1, 0 testes executados** — `swift build` falha ao compilar o alvo `tokenbar`:

```text
/Users/…/wt/t8-qa/Sources/tokenbar/AppState.swift:23:26: error: incorrect argument label in call
(have 'filePath:isDirectory:', expected 'fileURLWithPath:isDirectory:')
21 |         // Support real e o snapshot do dia as ressuscita entre runs.
22 |         let supportDir = env["TOKENBAR_SUPPORT_DIR"].map {
23 |             let url = URL(filePath: $0, isDirectory: true)
   |                          `- error: incorrect argument label in call (have 'filePath:isDirectory:', expected 'fileURLWithPath:isDirectory:')
24 |             try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
25 |             return url
EXIT=1
```

Erro único no pacote inteiro; introduzido pelo wip commit `0ea655e` (feature de QA `TOKENBAR_SUPPORT_DIR`). Detalhe em [BUG-1](#bugs). Log integral: `docs/qa/evidence/run-tests-2026-09-07-head-0ea655e-compile-error.log`.

### 2.2 Conteúdo F2 — `42d42e9`

Para não entregar um QA vazio por causa do BUG-1, a suíte, o build e o checklist foram re-executados em worktree detached temporário (`/tmp/t8-qa-verify`, `git worktree add --detach … 0ea655e~1`), **rotulado em toda evidência**. `42d42e9` contém 100% do conteúdo F2 (fixes do Red Team `fa0ea40`, `2dca544`, `42d42e9` inclusos); a única diferença para o HEAD é a linha quebrada do wip.

Comando: `./run-tests.sh`. Resultado (log integral em `docs/qa/evidence/run-tests-2026-09-07-head1-42d42e9-200pass.log`):

```text
✔ Test run with 200 tests in 23 suites passed after 0.957 seconds.
EXIT=0
```

**200/200 verdes** (199 do log commitado de 2026-09-03 + 1 teste novo `staleSnapshotPathsAreNotRestored`, regressão do fix `42d42e9`). Warnings de build pré-existentes e não bloqueantes (deprecação `FSEventStreamScheduleWithRunLoop`, `withUnsafeMutableBytes` unused, `nonisolated(unsafe)` desnecessário) — idênticos aos das execuções anteriores, sem regressão.

### 2.3 Build do app

`./scripts/make-app.sh release` em `42d42e9`:

```text
[14/15] Linking tokenbar
Build complete! (59.41s)
build/TokenBar.app: replacing existing signature
OK: build/TokenBar.app
```

`codesign -dv build/TokenBar.app` → `Identifier=app.tokenbar.TokenBar`, `Mach-O thin (arm64)`, `flags=0x2(adhoc)`. O checklist da seção 3 rodou contra ESTE bundle.

---

## 3. Checklist manual — evidências

Transcrição integral dos comandos e saídas AX: [`docs/qa/evidence/f2-visual-ax-2026-09-07.md`](evidence/f2-visual-ax-2026-09-07.md). Resumo:

- **Isolamento do launch** (exigência do brief): processo lançado direto do binário do bundle com `TOKENBAR_CLAUDE_DIR` → corpus `genfixtures` pequeno (1 sessão, 30 linhas, seed 5 → 360.760 tokens), `TOKENBAR_GEMINI_DIR` → sessão sintética (193 tokens), `TOKENBAR_CODEX_DIR` vazio e as 3 envs de credencial (`TOKENBAR_CODEX_AUTH`, `TOKENBAR_ZAI_CONFIG`, `TOKENBAR_ZAI_AUTH`) apontando para arquivos **inexistentes** — nenhum request de API sai da máquina (spec §5: sem credencial não há request). `TOKENBAR_E2E_DIR` próprio para o heartbeat. Nenhum `launchctl setenv` (variável global afetaria apps de outros agentes).
- **O que apareceu dos API-driven sem credencial (anotação pedida pelo brief):** no heartbeat v2, `codex` e `zai` com `authState: "missing"`, `menuBar: null`, `percent: null`, `todayTokens: 0`; na string do item e nas linhas do painel, **ausentes** (design D5: provider sem dado não ganha fragmento/linha). Sem crash, sem erro cru.
- **Consistência tripla (item 3d):** selfcheck v2 executado pelo **binário do bundle** com os mesmos envs == nome AX do item == heartbeat, campo a campo.
- **Quit (item 3e):** o `AXPress` no botão 2 funcionou — nesta execução não houve a condição de corrida de harness observada em 2026-09-03; o quit foi pelo caminho do painel, sem necessidade de fallback ⌘Q.
- **Robustez (item 5):** 5a (dir inexistente) e 5b (poison vs selfcheck) executados com launches dedicados e TERM limpo; detalhes e o incidente de harness do 5b em [`evidence/f2-visual-ax-2026-09-07.md`](evidence/f2-visual-ax-2026-09-07.md).
- **Instrumento AX liberado:** diferente da F1 (que ficou bloqueada por TCC), a Accessibility está concedida e o checklist visual foi 100% exercitado via System Events. Screen Recording não foi necessária.

### Higienização (obrigação desta QA)

O commit de conteúdo (`42d42e9`) ainda **não tem** `TOKENBAR_SUPPORT_DIR` (é justamente o que o wip quebrado adicionava — Red Team residual #4), então a instância de teste escreveu cursores/ledger no App Support real. Procedimento executado e verificado: snapshot pré-run dos 6 stores → após o quit, restauração byte-a-byte dos 4 arquivos escritos (mtimes provaram que só esta instância escreveu no intervalo) → `grep -rl t8-qa-f2` no diretório = vazio. Entradas `/tmp/tb-*` pré-existentes de harnesses de 2026-09-03 permanecem lá (não são desta execução — ver OBS-3).

---

## Bugs

### BUG-1 — HEAD `0ea655e` não compila (P0, bloqueante) — REPORTADO, NÃO CORRIGIDO

- **Onde:** `Sources/tokenbar/AppState.swift:23` (introduzido pelo wip commit `0ea655e`, feature `TOKENBAR_SUPPORT_DIR`).
- **O que:** `URL(filePath:isDirectory:)` não existe — o label correto é `fileURLWithPath:`. Erro único de compilação no pacote; derruba `swift build`, `./run-tests.sh` (0 testes, exit 1) e `make-app.sh`.
- **Impacto:** branch não mergeável no estado atual; nenhum artefato pode ser gerado do HEAD.
- **Fix sugerido (1 linha, decisão do reconciliador):** `let url = URL(fileURLWithPath: $0, isDirectory: true)`.
- **Conduta:** QA não mexe em código (escopo da T8); evidência integral em `docs/qa/evidence/run-tests-2026-09-07-head-0ea655e-compile-error.log`. A verificação do conteúdo foi conduzida em `42d42e9` exatamente para isolar o bug: com a linha revertida/corrigida, tudo mais já está provado verde nesta QA.

### Observações (não-bugs, registrados)

- **OBS-1 — contagem de testes:** o brief pedia "184 esperado"; o real no conteúdo é **200** (184 baseline T7 + 15 regressões QA/Red Team + 1 `staleSnapshotPathsAreNotRestored` do `42d42e9`). Sem perda de cobertura — o número do brief estava defasado.
- **OBS-2 — relatório anterior (wip):** o `f2-qa-report.md` commitado no wip (`0ea655e`) reivindicava 6/6 contra `fa0ea40` em 2026-09-03, produzido pelo agente interrompido. Esta execução **substitui** aquele relatório por evidência fresca e reproduzível; as alegações antigas não foram assumidas como verdade.
- **OBS-3 — poluição do App Support real:** stores reais ainda carregam entradas `/tmp/tb-live.*` e `/tmp/tb-qa` de harnesses anteriores (2026-09-03). Inofensivo em produção (paths inexistentes), mas reforça o valor do `TOKENBAR_SUPPORT_DIR` — após corrigir o BUG-1, recomenda-se manter a feature do wip (com o e2e passando a usá-la, como o script já preparou).
- **OBS-4 — botões anônimos no AX:** `name`/`title` = `missing value`; identificação por posição (botão 1 = Refresh, botão 2 = Quit) com prova funcional (3c e 3e). Melhoria de acessibilidade futura (`.accessibilityLabel`) — não bloqueia.
- **OBS-5 — pendências herdadas (sem mudança nesta QA):** validação real isolada das credenciais dual da Z.ai (decisão F2 nº 8) segue pendente com mitigação por fallback; E2E v2 não foi re-executado nesta passada (última execução commitada de 2026-09-03: 15 PASS, pré-wip); `selfcheck` sai 0 mesmo com falhas (SDD-9) — comparativos usam só o parse do JSON.
- **OBS-6 — incidente de harness (do QA, não do produto):** a 1ª tentativa do item 5b passou os overrides `TOKENBAR_*` via variável agregada (`env $ENVS` em zsh, sem word-splitting) — nenhum override valeu e o selfcheck usou os dados/credenciais REAIS da máquina (requests reais, percentuais reais exibidos; nenhum secret impresso). Sem valor como evidência; repetido com envs literais e isolamento total (5b corrigido). Efeitos colaterais tratados: sem processo órfão, scrub repetido do App Support. Detalhe em [`evidence/f2-visual-ax-2026-09-07.md`](evidence/f2-visual-ax-2026-09-07.md).
- **OBS-7 — processo de outro agente:** existe um app TokenBar órfão do worktree `t8-redteam` (pid 97406 no momento da execução) rodando na máquina e escrevendo nos stores reais. Fora do escopo desta QA — não foi tocado; fica o alerta para o reconciliador/limpeza do stream correspondente.

---

*Gerado pelo agente QA do DevSquad DomHubs (T8). Evidências brutas: `docs/qa/evidence/run-tests-2026-09-07-head-0ea655e-compile-error.log`, `docs/qa/evidence/run-tests-2026-09-07-head1-42d42e9-200pass.log`, `docs/qa/evidence/f2-visual-ax-2026-09-07.md`, `docs/qa/evidence/f2-selfcheck-2026-09-07.json`, `docs/qa/evidence/f2-poison-heartbeat-2026-09-07.json`.*
