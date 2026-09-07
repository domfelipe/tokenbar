# F2 — Relatório Red Team (Task 8, protocolo Simulador DomHubs)

**Data:** 2026-09-03 (bateria original) · **Revisado e completado:** 2026-09-07 (stream T8 retomado; worktree `t8-redteam`, branch `t8-redteam`)

**Escopo:** bateria adversarial de 7 casos sobre os 3 parsers locais (Claude/Codex/Gemini), os 2 decoders de API (Codex/Z.ai), o transporte de credenciais, o scheduler com backoff, os stores de cursor/ledger e o orçamento de recursos multi-provider, conforme brief da T8 e spec `docs/specs/f2-data-sources.md` (§5 tolerância, §7 orçamento, §9 segurança).

**Nota de continuidade:** este stream foi interrompido e retomado. O trabalho anterior (commits `34cd627`–`42d42e9` + WIP `0ea655e`) foi AUDITADO requisito por requisito: o que sobreviveu à auditoria está listado como PASS mantido; o que não sobreviveu foi corrigido com repro determinística. O commit `42d42e9` (sem review) recebeu veredicto próprio — ver Caso 7.

---

## Resumo

| # | Caso | Resultado | Severidade | Fix | Teste de regressão |
|---|------|-----------|------------|-----|--------------------|
| 1 | Fuzz dos 3 parsers + decoders de API | **FIXED ×3** | **P1 ×2 + P3** | `fa0ea40` (mantido), `0170edc`, `17001fa` | `nearInt64MaxComponentSum…`, `finiteHugeDoublesDoNotTrapIntConversions`, `linesAfterOversizedLineAreStillCounted` + 2 |
| 2 | Credenciais: grep total, read-only, log stream | PASS | — | — | — |
| 3 | 500-storm → backoff crescente, sem retry storm | PASS (refeito com contador) | — | — | `errorBackoffDoublesWithThirtyMinuteCeiling…` |
| 4 | Mock cai no meio do ciclo → recupera quando volta | PASS | — | — | (e2e degradação + selfcheck `network`) |
| 5 | Offsets corrompidos nos 3 cursor files | **PASS + achado** | **P2** | `2dca544` (mantido) | `lostCursorsInvalidateSnapshotNoDoubleCount` |
| 6 | Corpus gigante multi-provider dentro do orçamento | PASS (refeito completo) | — | — | — |
| 7 | Restart mid-day + validação do `42d42e9` | **FIXED** (42d42e9 parcial) | **P1** | `fbe82cb` | `staleTotalsWithSurvivingCursorsAreNotRestored` ×3 providers |

**Achados novos da auditoria (fora dos 7 casos):**

| Achado | Severidade | Fix |
|---|---|---|
| WIP `0ea655e` não compilava (`URL(filePath:isDirectory:)` não existe) | build quebrado | `03e845c` |
| `42d42e9` não fechava o buraco que descrevia (stores acumulam cursores; stamp batia e o total morto voltava) — repro nos 3 providers | **P1** | `fbe82cb` |
| Linha >262 KB (janela de streaming) no fim do arquivo → TODAS as linhas seguintes perdidas para sempre (subconta silenciosa; cursor consumia os bytes) | **P1** | `17001fa` |
| `Int(Double)` com payload hostil (`number: 1e300`, `limit_window_seconds: ±1e300`) TRAPAVA (SIGTRAP) no Z.ai/Codex | **P1** | `0170edc` |
| `FlexibleJSON.double` aceitava não-finito (`1e999`/`NaN`) → `nextResetTime` vazava `inf` como Date | P3 | `0170edc` |

**Suíte final: 210 testes verdes** (184 base + 26 de F2, incl. 10 regressões novas desta auditoria). E2E v2: 15 PASS (log `e2e-2026-09-03.log`, 1 FAIL pré-fix documentado abaixo).

---

## Caso 1 — Fuzz dos 3 parsers + decoders: FIXED (P1 crash) + 2 achados novos

**Ataque (agora pino permanente):** suíte `ParserFuzzTests` — bytes 0x00–0xFF isolados e embutidos em JSON válido, JSON de 50k níveis, linha de ~5 MB nos prefilters dos 3 parsers, `1e999`/`Int64.max`/`min`/negativos/string/bool/null/`9e999` em cada campo numérico, envelopes com tipos errados, JSON truncado, chaves duplicadas, unicode hostil (RTL/combining/emoji/NUL), timestamps inválidos — nos 3 parsers de linha + 2 decoders de API, com linhas de controle legítimas antes/depois da bateria (parser corrompido deixa de contar). Rodada runtime: selfcheck real contra corpora hostis por provider (200k níveis, 5 MB, bytes crus) — 3 rodadas, exit 0, JSON válido, totais determinísticos.

**Achados:**

1. **P1 (pré-`fa0ea40`, mantido):** composição do output Gemini com `+` comum trapava com campos ~`Int64.max` (SIGTRAP, exit 133). Fix original revisado e correto (`TokenSums.saturatingSum` antes do saneamento).
2. **P1 NOVO (`0170edc`):** `Int(Double)` TRAPA fora do range de Int — verificado isoladamente ("Fatal error: Double value cannot be converted to Int…"). Vetores: Z.ai `number: 1e300` com `percentage` válida (janela criada → label calculado → trap) e Codex `limit_window_seconds: ±1e300` (ambos os branches). A bateria anterior não cobriu valores FINITOS gigantes — `1e999` sozinho não revela (é não-finito e já era rejeitado).
3. **P1 NOVO (`17001fa`):** linha maior que a janela de streaming (262 KB) + fim de arquivo = **todas as linhas seguintes do arquivo perdidas para sempre** — o `drainOnce` final saía do modo skip sem parsear a cauda e o cursor já havia consumido os bytes. Repro real: corpus Claude com linha de 5 MB → total 0; Codex 587→437. Segundo defeito da mesma família: skip no EOF sem `\n` à frente não consumia o restante (cursor preso atrás, trecho relido a cada ciclo).
4. **P3 (`0170edc`):** `FlexibleJSON.double` aceitava não-finito; `nextResetTime: 1e999` vazava `Date(inf)` no snapshot (não crasha; lixo de diagnóstico). Corrigido junto (1 linha, mesmo helper).

**Fix:** `fa0ea40` (saturação Gemini, mantido); `0170edc` (FlexibleJSON finito + saturação antes de toda conversão `Int(Double)`); `17001fa` (drena a janela até esvaziar pós-leitura; linha incompleta em modo normal continua fora do cursor — semântica F1 preservada).

**Regressões:** `nearInt64MaxComponentSumIsRejectedNotCrash` (pré-existente), `finiteHugeDoublesDoNotTrapIntConversions`, `linesAfterOversizedLineAreStillCounted`, `multipleLinesAfterOversizedLineSurvive`, `oversizedAtEOFWithoutTrailingNewlineKeepsCursorExact` — as três últimas vermelhas antes do fix.

**Pós-fix (runtime):** 3 rodadas selfcheck → exit 0, JSON válido, **Codex 587 exato** (cauda sobrevive), Gemini 133 (linha com `"` embutida em byte cru rejeitada — correto), Claude 6.177.399 determinístico.

---

## Caso 2 — Credenciais: PASS

- `grep -rniE` sobre `Sources/`+`Tests/`+`scripts/`+`docs/`: JWT (`eyJ…`), `sk-…`, `Bearer <20+>`, `ghp_`/`github_pat_`/`AKIA`/`xox[bpm]-`, e `access_token/apiKey/refresh_token` com literal longo → **zero match real**. Únicos literais: `fake-*` de fixtures (inventário no log de evidência).
- **Read-only:** `CodexAuthReader`/`ZaiCredentialReader`/`UsageHTTPClient` — nenhuma escrita (`Data.write`/`removeItem`/`createFile`), nenhum `print`/`NSLog`/`Logger`; única entrada é `Data(contentsOf:)`.
- **Heartbeat/selfcheck:** chaves por provider ⊆ `{menuBar, percent, todayTokens, authState, fetchedAt, error}`; `error` é token curto (`network`/`http`/`decode`/`unauthorized`) — sem paths, sem conteúdo, sem credencial.
- E2E: mock loga o `Authorization` de cada request — só `Bearer fake-*` circula.

---

## Caso 3 — 500 storm: PASS (refeito com contador)

**Ataque:** app real contra mock `python3` respondendo **500 sempre** nas 2 rotas, com log por request (o log parcial de 4 linhas do stream interrompido foi refeito com contador e gaps — `docs/qa/evidence/f2-rt3-500storm-requests.log`).

**Medição (janela de 31,6 min):**

| Request do provider | Gap desde o anterior |
|---|---|
| #1 (burst inicial, C+Z) | — |
| #2 | **+642 s** (nominal 600 = idle 300 ×2) |
| #3 | **+1253 s** (nominal 1200 = 600 ×2) |

Backoff **crescente** visível (~1 request/provider a cada ~11–21 min), 0 retries do mesmo request, máximo de 2 requests em qualquer janela de 10 s (o próprio burst) — **sem retry storm**. O dobramento com teto de 30 min fica pinado no scheduler (`errorBackoffDoublesWithThirtyMinuteCeilingAndSuccessResets`). 401/403 entram no mesmo caminho (`noteResult(ok: false)`); Z.ai com credencial dupla tenta a 2ª (no máximo 2 requests por ciclo, sem retry do mesmo request).

---

## Caso 4 — Mock morre no meio do ciclo: PASS

**Ataque (app real, porta fixa, valores sintéticos):**

1. Mock no ar → heartbeat `C:2.2k X:42% Z:81%`.
2. `kill -9` no mock + append de +222 no transcript Claude → **app vivo**, heartbeat avança via ciclo local (`C:2.4k`), **0 requests** na janela pós-morte (sem storm de reconexão), display mantém último estado bom.
3. Mock de volta na **mesma porta** com valores NOVOS (55/91) → Z.ai recuperou no 1º ciclo (`Z:91%` — valor novo, não resíduo) e o Codex no próximo fire do cadenciamento normal (`X:55%` observado no poll de ~5 min).

O E2E cobre o mesmo cenário com degradação visível: erro tokenizado `network` no selfcheck v2 (mock morto), app vivo >60 s, heartbeat avançando via providers locais.

---

## Caso 5 — Offsets corrompidos nos 3 cursor files: PASS + achado (P2, fix mantido)

**Ataque (app real, stores isolados):** com o app parado — Claude `offset = 18446744073709551615` (UInt64.max), Codex `offset = -1` (inválido p/ UInt64 → decode do arquivo inteiro falha → estado vazio), Gemini **arquivo inteiro como JSON lixo**. Relançamento + 2 ciclos.

**Resultado:** sem crash, sem loop; re-ingest completa reproduziu os totais exatos (`C=5045 X=800 G=238`); cursores regravados sãos — **offset == tamanho real dos 3 arquivos** (363/277/235 bytes), Gemini com `seenIDs` íntegro; 2º ciclo estável com os mesmos totais.

**Achado (P2, fix `2dca544`, revisado e mantido):** cursores perdidos + snapshot do ledger = dia contado em dobro — o stamp FNV-1a do estado dos cursores no save invalida o snapshot quando o store muda, e o re-ingest reconstrói honestamente.

---

## Caso 6 — Corpus gigante multi-provider: PASS (orçamento, redo completo)

**Ataque:** ingest frio no app real de **~107 MB / ~463k eventos** (Claude: genfixtures 6×60k linhas com poison = 342.729 eventos; Codex: 3 rollouts sintéticos ×10k `token_count`; Gemini: 3 sessões ×30k linhas-raiz), `phys_footprint` (vmmap) amostrado a cada ~0,7 s durante o ingest — log completo em `docs/qa/evidence/f2-rt6-footprint.log` (substitui o log parcial de 2 amostras do stream interrompido).

| Métrica | Orçamento | Medido |
|---|---|---|
| Footprint máximo durante o ingest frio | ≤ 40 MB | **27,8 MB** (16,6 no launch → 27,8 com 3 ingests no mesmo processo; não escala com o arquivo) |
| Cold ingest até o 1º heartbeat | — | **~10–11 s** (~10 MB/s) |
| Codex vs verdade do gerador | exato | **152.058.268 == 152.058.268** (só `last_token_usage`, F2-CODEX-DELTA) |
| Gemini vs verdade do gerador | exato | **241.670.003 == 241.670.003** |
| Extrapolação linear p/ ~10 GB | — | **~17 min** (coerente com os ~11,5 min medidos na T7 sobre dados reais — o real é mais rápido por byte: linhas maiores, menos overhead de parse) |

Streaming bounded confirmado com API + 3 providers no mesmo processo: o pico de memória não cresce com o corpus (janela de 262 KB + eventos aplicados por lote e descartados) — o orçamento de 40 MB vale para 10 GB também.

---

## Caso 7 — Restart mid-day + VEREDICTO sobre o `42d42e9`: FIXED

**Restart mid-day (app real, pós-auditoria):** corpus com verdade exata → run 1 `C=4998 X=800 G=238` → kill → relança → **`C=4998 X=800 G=238` imediatamente** (snapshot restaurado, cursores intactos) → evento novo +47 → `C=5045` (soma em cima, sem dobrar). O mecanismo do `66558c7`/`2dca544` (snapshot por arquivo, stamp de cursores, restore 1×/processo) está correto e pinado por 11 testes.

### Veredicto sobre `42d42e9` ("restauração de snapshot restrita aos paths do store de cursores"): **PARCIAL — o código é seguro, mas não faz o que a mensagem diz**

- **O que o commit faz:** adiciona `filtered(toExistingIn:)` (snapshot ⊆ cursores) + guard de vazio. Sob as invariantes atuais, esse critério só dispara com arquivo de snapshot plantado/órfão (defesa em profundidade legítima; pin `staleSnapshotPathsAreNotRestored` segue verde).
- **O que NÃO faz:** o commit atribui a si o conserto do dobramento do e2e (C:4.0M→C:7.7M, G:193→G:386). Repro determinística provou o contrário: **o store de cursores ACUMULA paths e nunca poda** — o cursor do path velho sobrevive, o stamp do snapshot carimbado com ele BATE, o filtro mantém a entrada (o cursor existe!) e o total morto volta. Vermelho nos 3 providers: 4.003.330 / 4.003.777 / 4.000.238 em vez de 3330/377/238. Quem de fato isolou o e2e foi o `TOKENBAR_SUPPORT_DIR` (WIP `0ea655e`).
- **Correção (`fbe82cb`):** `filtered(toExistingIn:underScanRoot:)` — só restaura o que (a) tem cursor vivo E (b) está sob a raiz de scan ATUAL do provider. Comparação resolve symlinks dos dois lados: o enumerator grava paths RESOLVIDOS (`/var`→`/private/var`) e `projectsDirectory.path` não-resolvido — sem isso o filtro derrubava o restore legítimo (quebrou `restartMidDayRestoresTodayTotals` durante o desenvolvimento; pinado).
- **Regressões:** `staleTotalsWithSurvivingCursorsAreNotRestored` nos 3 providers (vermelhas pré-fix, verdes pós-fix); o restart legítimo continua coberto por `restartMidDayRestoresTodayTotals` ×3.

---

## Preocupações residuais (documentadas, sem ação na F2)

1. **Restauração é "last-good honesta":** crash ENTRE a gravação dos cursores e a do snapshot deixa o snapshot um ciclo atrás — subconta até o próximo evento do dia (nunca superconta; a ordem grava cursores → snapshot).
2. **Stamp de cursor não cobre `seenIDs`:** se o cursor sobrevive mas um `seenIDs` do Gemini se perde mantendo o offset, duplicatas reanexadas no tail já consumido não são re-dedupicadas. Janela mínima, auto-corrigida no rollover; monitorar.
3. **Stores de cursor/snapshot acumulam paths mortos** (nunca podam). Com o filtro por raiz de scan isso é só higienico (crescimento ~dezenas de bytes por path órfão), não corretivo. Para F3: podar entradas fora da raiz no rollover.
4. **Path-spelling:** a comparação de raiz resolve symlinks; se a MESMA raiz for acessível por spellings não-equivalentes por symlink (raro), o restore degrada para last-good e se autocorrige no próximo evento (mesma classe do item 1).
5. **Overshoot do sleep do scheduler sob carga** (~7% no gap de 642 s vs 600 s nominal): `Task.sleep` não é hard real-time; irrelevante para o orçamento.
6. **Selfcheck sem overrides de API usa endpoints reais** se houver credencial na máquina (comportamento documentado do selfcheck — é um diagnóstico; mas harnesses devem SEMPRE sobrescrever `TOKENBAR_CODEX_API`/`TOKENBAR_ZAI_API`, como o e2e faz). Observado durante esta bateria e corrigido nos harnesses.
7. **`TOKENBAR_SUPPORT_DIR` existe para testes/e2e** (WIP `0ea655e` + fix de compilação `03e845c`); o app sem a var continua no App Support real — correto para produção.

## Artefatos

- **Commits deste stream (branch `t8-redteam`):** `03e845c` (build do WIP), `fbe82cb` (raiz de scan — veredicto 42d42e9), `0170edc` (traps Int(Double) + suíte de fuzz), `17001fa` (cauda pós-oversized) + docs/evidência (este commit).
- **Mantidos após auditoria:** `fa0ea40` (saturação Gemini), `66558c7`/`2dca544` (snapshot do dia + stamp), `34cd627`/`ae65a92` (heartbeat v2 + e2e), `0ea655e` (TOKENBAR_SUPPORT_DIR, selfcheck v2, README/docs).
- **Evidências:** `docs/qa/evidence/f2-rt3-500storm-requests.log` (refeito com contador), `docs/qa/evidence/f2-rt6-footprint.log` (redo completo), `docs/qa/evidence/e2e-2026-09-03.log` (inclui o FAIL C:15.7M que motivou a auditoria do snapshot), `docs/qa/evidence/run-tests-2026-09-03.log` + log final deste stream.
- **Corpora:** `/tmp/t8-lab`, `/tmp/t8-storm` — regeneráveis; remover ao fim da T8.
