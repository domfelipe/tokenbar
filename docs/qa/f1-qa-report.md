# QA F1 — Skeleton Claude Local (Task 15)

- **Data:** 2026-09-02
- **Branch:** `f1-skeleton-claude-local` @ `c3874d5`
- **Ambiente:** macOS 26.5.1 (Build 25F80), arm64, toolchain Command Line Tools (sem Xcode)
- **Protocolo:** skill QA DomHubs — prova de conclusão requisito por requisito (evidência autoritativa ou status "não verificado")
- **Veredito do gate:** 🔴 **BLOQUEADO** — suítes 100% verdes (44/44 testes, E2E 6/6 PASS) e itens 4–5 PASS, mas **4 de 6 itens do checklist manual não puderam ser verificados** neste ambiente por bloqueio de permissões do macOS (detalhado em [Bloqueio de instrumentação](#bloqueio-de-instrumentação-e-caminho-de-destravamento)). Pelo critério do gate ("nenhum item não verificado"), a F1 **não recebe aprovação de QA nesta execução**. Nenhum item foi marcado PASS sem evidência; nenhuma evidência foi simulada.

---

## 1. Resumo por requisito

| # | Requisito | Evidência | Status |
|---|-----------|-----------|--------|
| — | Suíte de testes completa (`./run-tests.sh`) | Saída integral em [§2.1](#21-suíte-de-testes---run-testssh) e `docs/qa/evidence/run-tests-2026-09-02.log` — **44 tests in 9 suites passed** | ✅ PASS |
| — | E2E (`./scripts/e2e.sh`) | Saída integral em [§2.2](#22-e2e---scriptse2esh) e `docs/qa/evidence/e2e-2026-09-02.log` — **6 PASS, 0 falha, exit 0** | ✅ PASS |
| 1 | Item visível na menu bar (`open build/TokenBar.app` → `C:<n>`/`TB`) | App aberto (pid confirmado via `pgrep`), renderizou `TB` (heartbeat §item 4); porém **nenhuma captura de tela nem leitura AX da menu bar foi possível** (bloqueio §4). CGWindowList não mostra janela própria do app antes/depois do launch (nota técnica §4.2) | ⛔ NÃO VERIFICADO |
| 2 | Clique no item → menu com "Refresh now" e "Quit TokenBar" (⌘Q) | Interação de clique indisponível em todas as vias (bloqueio §4). Conteúdo do menu não observado em tela | ⛔ NÃO VERIFICADO |
| 3 | "Refresh now" responde sem erro (app vivo) | Clique impossível (bloqueio §4). Proxy indireto: live update do E2E observou Δ=+333 no mesmo binário (mesma pipeline de re-render), mas a ação manual de menu não foi exercitada | ⛔ NÃO VERIFICADO (proxy parcial no §3.3) |
| 4 | Texto da menu bar == `selfcheck $HOME/.claude/projects` na mesma hora | Comparado **no mesmo minuto** sobre dados reais: heartbeat do app real `{"menuBarText":"TB","todayTokens":{},"updatedAt":"2026-09-02T22:28:01Z"}` == selfcheck `{"eventsApplied":386,"menuBarText":"TB","todayTokens":{}}` (T0 e T+2s idênticos). *Instrumento:* `menuBarText` do heartbeat é a mesma string publicada por `SnapshotStore` que o status item renderiza (fonte única, `Sources/TokenBarUI/SnapshotStore.swift`); **pixels da menu bar não verificados** (bloqueio §4). Nota: sem eventos hoje em `~/.claude/projects`, `TB` é o valor correto esperado | ⚠️ PASS (instrumento indireto) |
| 5 | Robustez: dir inexistente sobe sem crash; corpus `--poison` consistente com selfcheck | **5a:** `TOKENBAR_CLAUDE_DIR=/tmp/diretorio-que-nao-existe` → processo vivo após 5s, heartbeat `{"menuBarText":"TB","todayTokens":{}}`. **5b:** corpus poison (`genfixtures --sessions 1 --lines 30 --seed 3 --poison`) → app `{"menuBarText":"C:359.6k","todayTokens":{"claude":359631}}` == selfcheck `{"eventsApplied":30,"menuBarText":"C:359.6k","todayTokens":{"claude":359631}}` | ✅ PASS |
| 6 | Quit via menu sem processo zumbi (`pgrep` vazio) | Caminho "via menu" **não exercitado** (bloqueio §4). Verificado apenas encerramento por SIGTERM: `pgrep -fl tokenbar` vazio após cada encerramento (5 execuções, zero zumbis) | ⛔ NÃO VERIFICADO (parcial SIGTERM) |

**Placar do checklist manual:** 2 PASS (1 com instrumento indireto) · 4 NÃO VERIFICADO · critério do gate **não atendido nesta execução**.

---

## 2. Suíte completa (saída integral)

### 2.1 Suíte de testes — `./run-tests.sh`

Comando: `./run-tests.sh` (build + `swift test` com os flags de framework do CLT). Log integral em `docs/qa/evidence/run-tests-2026-09-02.log`. Execução de testes integral:

```text
◇ Test run started.
↳ Testing Library Version: 1902
↳ Target Platform: arm64e-apple-macos14.0
◇ Suite TokenLedgerTests started.
◇ Suite DomainTests started.
◇ Suite ClaudeLineParserTests started.
◇ Suite ClaudeProviderTests started.
◇ Suite SmokeTests started.
◇ Suite MenuBarContentTests started.
◇ Suite DebounceTests started.
◇ Suite FileOffsetStoreTests started.
◇ Suite TranscriptIngesterTests started.
✔ Test testProviderIDCodableRoundtrip() passed after 0.002 seconds.
✔ Test testTokenSumsArithmetic() passed after 0.002 seconds.
✔ Test testUsageEventCodableRoundtrip() passed after 0.002 seconds.
✔ Test testTokenSumsCodableRoundtrip() passed after 0.002 seconds.
✔ Test testAccountIDHashAndEquality() passed after 0.002 seconds.
✔ Test truncatedJSONIsSkippedNotFatal() passed after 0.003 seconds.
✔ Test allZeroUsageIsSkipped() passed after 0.003 seconds.
✔ Test testRolloverClearsTotalsAndFlagsRescan() passed after 0.007 seconds.
✔ Test testTruncationSelfCorrects() passed after 0.007 seconds.
✔ Test coreVersionIsSet() passed after 0.007 seconds.
✔ Test testYesterdayEventsDoNotCountForToday() passed after 0.007 seconds.
✔ Test testMultiProviderBreakdown() passed after 0.007 seconds.
✔ Test testAccumulatesAcrossFilesAndCycles() passed after 0.007 seconds.
✔ Test binaryGarbageIsSkippedNotFatal() passed after 0.007 seconds.
✔ Test testEmptyContentShowsPlaceholder() passed after 0.007 seconds.
✔ Test assistantWithoutUsageIsSkipped() passed after 0.007 seconds.
✔ Test resolvePrefersEnvironmentOverride() passed after 0.007 seconds.
✔ Test testAbbrevTokens() passed after 0.007 seconds.
✔ Test userLineIsSkipped() passed after 0.007 seconds.
✔ Test testMultipleProvidersFormat() passed after 0.007 seconds.
✔ Test testSingleProviderFormat() passed after 0.007 seconds.
✔ Test missingDirectoryYieldsZero() passed after 0.007 seconds.
✔ Test resolveFallsBackToHomeClaude() passed after 0.007 seconds.
✔ Test testMissingFileStartsEmpty() passed after 0.007 seconds.
✔ Test testCorruptedFileStartsEmpty() passed after 0.007 seconds.
✔ Test negativeTokensAreClampedToZero() passed after 0.007 seconds.
✔ Test assistantLineWithUsageProducesEvent() passed after 0.007 seconds.
✔ Test invalidTimestampIsSkipped() passed after 0.007 seconds.
✔ Test testSetThenReloadRoundtrip() passed after 0.007 seconds.
✔ Test testIncompleteTrailingLineIsNotConsumed() passed after 0.007 seconds.
✔ Test testFirstIngestReadsWholeFile() passed after 0.006 seconds.
✔ Test testGarbageLinesAreSkippedButConsumed() passed after 0.006 seconds.
✔ Test testSubdirectoriesAreScanned() passed after 0.007 seconds.
✔ Test testRemoveWithNil() passed after 0.007 seconds.
✔ Test testRenderGateSkipsEqualContent() passed after 0.007 seconds.
✔ Suite DomainTests passed after 0.007 seconds.
✔ Suite SmokeTests passed after 0.007 seconds.
✔ Suite FileOffsetStoreTests passed after 0.007 seconds.
✔ Test ingestOnceCountsTokensFromRealFormatFixture() passed after 0.007 seconds.
✔ Test testUnchangedFileIsNotReturned() passed after 0.006 seconds.
✔ Suite TokenLedgerTests passed after 0.007 seconds.
✔ Test ingestTwiceDoesNotDuplicate() passed after 0.007 seconds.
✔ Suite MenuBarContentTests passed after 0.007 seconds.
✔ Suite ClaudeProviderTests passed after 0.007 seconds.
✔ Test testSecondIngestReadsOnlyAppend() passed after 0.007 seconds.
✔ Test testTruncatedFileResetsToZero() passed after 0.007 seconds.
✔ Test testTenThousandEventsUnderOneSecond() passed after 0.014 seconds.
✔ Suite TranscriptIngesterTests passed after 0.015 seconds.
✔ Test hugeLineDoesNotCrash() passed after 0.055 seconds.
✔ Suite ClaudeLineParserTests passed after 0.055 seconds.
✔ Test testWaitReturnsOnlyAfterQuiesceWindow() passed after 0.121 seconds.
✔ Test testTouchResetsWindow() passed after 0.121 seconds.
✔ Suite DebounceTests passed after 0.122 seconds.
✔ Test run with 44 tests in 9 suites passed after 0.122 seconds.
```

**Resultado: 44/44 testes em 9 suítes, todos verdes** (compatível com o esperado do gate). Único warning de build: deprecação `FSEventStreamScheduleWithRunLoop` em `Sources/TokenBarCore/Watcher/TranscriptWatcher.swift:81` (informativo, não bloqueia).

### 2.2 E2E — `./scripts/e2e.sh`

Comando: `./scripts/e2e.sh`. Saída integral (log em `docs/qa/evidence/e2e-2026-09-02.log`):

```text
[e2e] TMP=/tmp/tokenbar-e2e.39I8CC
[e2e] gerando corpus
[0/1] Planning build
Building for production...
[0/2] Write swift-version--1AB21518FC5DEDBE.txt
Build of product 'genfixtures' complete! (0.11s)
{"cacheRead":5852575,"cacheWrite":285353,"events":574,"files":4,"input":1474479,"output":573886}
Building for production...
[0/2] Write swift-version--1AB21518FC5DEDBE.txt
Build of product 'tokenbar' complete! (0.09s)
[e2e] selfcheck: {"eventsApplied":574,"menuBarText":"C:6.4M","todayTokens":{"claude":6356106}}
[0/1] Planning build
Building for production...
[0/3] Write swift-version--1AB21518FC5DEDBE.txt
Build complete! (0.11s)
build/TokenBar.app: replacing existing signature
OK: build/TokenBar.app
[e2e] PASS: heartbeat criado em 30s
[e2e] PASS: menu bar text igual ao selfcheck ('C:6.4M' == 'C:6.4M')
[e2e] PASS: live update após append (Δ=+333 observado)
[e2e] aguardando 60s para medir recursos...
[e2e] PASS: processo vivo (sem crash)
[e2e] PASS: memória própria (phys_footprint) 15.0M ≤ 40MB (rss informativo: 71904KB)
[e2e] PASS: cpu 0.0% ≤ 0.5%
[e2e] concluído: 0 falha(s)
./scripts/e2e.sh: line 82: 23961 Terminated: 15          TOKENBAR_CLAUDE_DIR="$CORPUS" TOKENBAR_E2E_DIR="$STATE" "build/TokenBar.app/Contents/MacOS/tokenbar"
E2E_EXIT=0
```

**Resultado: 6 PASS, 0 falha, exit 0** (a linha `Terminated: 15` é o próprio `trap` do script encerrando o app ao final — comportamento esperado).

---

## 3. Checklist manual — evidências detalhadas

### 3.1 Item 4 — texto == selfcheck em dados reais (mesma hora)

Instância real do bundle (`.build/release/tokenbar`, mesmo binário empacotado) sobre `TOKENBAR_CLAUDE_DIR=$HOME/.claude/projects`, comparada ao selfcheck no mesmo minuto:

```text
selfcheck T0:    {"eventsApplied":386,"menuBarText":"TB","todayTokens":{}}
heartbeat T0:    {"menuBarText":"TB","todayTokens":{},"updatedAt":"2026-09-02T22:28:01Z"}
selfcheck T+2s:  {"eventsApplied":386,"menuBarText":"TB","todayTokens":{}}
```

Strings idênticas (`TB` == `TB`; sem eventos hoje em `~/.claude/projects`, o placeholder é o valor correto — 386 eventos aplicados de dias anteriores, `todayTokens` vazio). **Instrumento:** o heartbeat publica exatamente a `menuBarText` do `SnapshotStore` (fonte única que alimenta o status item — `apply()` só publica quando a string muda). Os **pixels** da menu bar não foram verificados (ver §4); se o instrumento for considerado insuficiente para o requisito, este item degrada para NÃO VERIFICADO.

### 3.2 Item 5 — robustez

**5a. Diretório inexistente** (`TOKENBAR_CLAUDE_DIR=/tmp/diretorio-que-nao-existe`, heartbeat ativo):

```text
processo vivo após 5s (pid 38105)
{"menuBarText":"TB","todayTokens":{},"updatedAt":"2026-09-02T22:20:35Z"}
```

Sobe sem crash, texto placeholder `TB`, sem stack trace.

**5b. Corpus poison** (`genfixtures --out /tmp/tb-qa-poison --sessions 1 --lines 30 --seed 3 --poison` → `{"events":30,"files":1,...}`):

```text
selfcheck do corpus:  {"eventsApplied":30,"menuBarText":"C:359.6k","todayTokens":{"claude":359631}}
app (heartbeat):      {"menuBarText":"C:359.6k","todayTokens":{"claude":359631},"updatedAt":"2026-09-02T22:20:57Z"}
```

Totais idênticos (`C:359.6k` / 359631) — o app ignora as linhas inválidas exatamente como o selfcheck (mesma pipeline, verdade de referência correta, SDD-8/T11).

### 3.3 Itens 1, 2, 3 e 6 — interação com a menu bar

Não executados em tela. Evidência parcial coletada:

- **Processo/app sobem normalmente**: `pgrep -fl tokenbar` mostra o binário do bundle em todas as aberturas (pids 29551, 31631, 38105, 38237 e instância real §3.1); renderização de texto funcionando (heartbeats acima).
- **Sem zumbis em encerramentos** (item 6, parcial): após cada `kill`/fim de instância, `pgrep -fl tokenbar` retornou vazio — mas o caminho "Quit via menu" não foi o gatilho.
- **Proxy do re-render** (item 3, parcial): o E2E observou Δ=+333 no heartbeat após append de linha (live update), provando a pipeline ingest → debounce → re-render no mesmo binário; a ação manual "Refresh now" é um re-ingest sob demanda dessa mesma pipeline, porém o clique em si não foi exercitado.
- **CGWindowList** (instrumento disponível, bounds sem imagem): o app não possui janela própria listada em nenhuma layer, e o conjunto de janelas layer-25 (menu bar) ficou **idêntico** antes/depois de subir e matar o processo (12 janelas, diff vazio). Em macOS 26 a hospedagem de status items pode ser out-of-process (Control Center), então isso **nem confirma nem refuta** a presença visual do item — registrada como anomalia a investigar quando houver instrumento visual.

---

## 4. Bloqueio de instrumentação e caminho de destravamento

### 4.1 Diagnóstico (erros exatos)

Toda via de observação/interação da tela está sob permissão TCC do macOS, e todas estão negadas para esta sessão:

| Via | Erro observado |
|-----|----------------|
| `screencapture` (com e sem sandbox) | `could not create image from display` / `could not create image from rect` (sem Screen Recording) |
| AppleScript → System Events (AX/ clique) | `System Events obteve um erro: Esgotou-se o tempo limite do AppleEvent. (-1712)` (Automação negada) |
| CoreGraphics direto via Swift | `AXIsProcessTrusted() == false` — cliques/teclas sintetizados (`CGEventPost`) silenciosamente descartados (testado: clique no relógio e Esc não produziram janela nova na CGWindowList) |
| Orca Computer Use (`orca computer ...`) | `permissions` reporta `accessibility: granted, screenshots: granted`, porém **toda ação retorna `permission_denied`**: "AX reads stayed blocked for 1500ms after retries. macOS Accessibility may need Orca Computer Use toggled off and on again in System Settings." — incluindo `get-app-state` em Finder e Telegram, `hotkey` |
| pyobjc / cliclick | não instalados |

Mitigações tentadas sem sucesso: reinício completo do app Orca + helper (`pkill` + `orca open`), `orca computer permissions --id accessibility` (abriu System Settings e lançou o helper), espera de 10s + reteste. É a re-autorização periódica de Acessibilidade do macOS (15+): **somente um humano** pode refazer o toggle. `AskUserQuestion` foi aberto ao operador e retornou sem resposta (sessão não assistida).

### 4.2 Nota técnica — CGWindowList

`CGWindowListCopyWindowInfo` funciona sem Screen Recording (bounds, sem pixels) e foi usado como instrumento auxiliar. Achado: nenhuma janela do processo do TokenBar aparece na lista, e o conjunto de janelas layer-25 do sistema não muda ao subir/matar o app. Hipótese principal: hospedagem out-of-process dos status items no macOS 26; hipótese alternativa: status item não renderizado. Sem captura visual é impossível arbitrar entre as duas — **por isso o item 1 está NÃO VERIFICADO, não FAIL**: não há evidência de defeito, há ausência de evidência.

### 4.3 Caminho de destravamento (para re-executar itens 1, 2, 3 e 6)

1. Em **System Settings → Privacy & Security → Accessibility**, desligue e ligue **Orca Computer Use** (a janela de Settings foi aberta pelo orca durante o diagnóstico).
2. Re-executar apenas o checklist visual: abrir o app, screenshot da menu bar (item visível `TB`/`C:<n>`), clique no item (menu com "Refresh now" / "Quit TokenBar" ⌘Q), clique em "Refresh now" + `pgrep`, clique em "Quit TokenBar" + `pgrep` vazio.
3. Anexar os screenshots a `docs/qa/img/` e atualizar este relatório.

---

## 5. Observações (o que este QA não cobre)

- **Não coberto por design da F1:** múltiplos providers (só Claude), renderização de ícone/coloração do item, LaunchAtLogin, distribuição/notarização, contas multi-usuário.
- **Orçamento de recursos** foi medido apenas pelo E2E (idle 60s: footprint 15.0MB, CPU 0.0%); não medido sob carga contínua de transcripts grandes.
- **`selfcheck` sai 0 mesmo com falhas** (SDD-9/T12): os comparativos deste relatório usam apenas o parse do JSON, nunca o exit code.
- O texto do app é en-US por decisão da F1 ("Refresh now", "Quit TokenBar"); não avaliado para pt-BR.
- Warning de deprecação `FSEventStreamScheduleWithRunLoop` (`TranscriptWatcher.swift:81`) — migrar para `FSEventStreamSetDispatchQueue` em tech-debt (não bloqueia F1).
- **Execução de QA não assistida:** os 4 itens pendentes requerem re-execução após o toggle de Acessibilidade (§4.3). Este relatório não deve ser lido como reprovação do produto — as suítes e o E2E estão 100% verdes — e sim como gate **inconclusivo por instrumentação**.

---

*Gerado pelo agente QA do DevSquad DomHubs. Evidências brutas: `docs/qa/evidence/run-tests-2026-09-02.log`, `docs/qa/evidence/e2e-2026-09-02.log`.*
