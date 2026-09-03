# F1 — Relatório Red Team (Task 16, protocolo Simulador DomHubs)

**Data:** 2026-09-02 · **Alvo:** branch `f1-skeleton-claude-local` · **Baselina antes da bateria:** 44 testes verdes (`./run-tests.sh`), E2E 6 PASS.

**Escopo:** bateria adversarial de 7 casos sobre o monitor local de tokens do Claude Code (parser, ingester, ledger, watcher, persistência de cursores), conforme brief da Task 16 e spec `docs/specs/2026-09-02-design.md` (§5 tolerância, §7 orçamento de perf, §9 segurança).

---

## Resumo

| # | Caso | Resultado | Severidade | Fix | Teste de regressão |
|---|------|-----------|------------|-----|--------------------|
| 1 | Fuzz do parser (1.011 linhas hostis) | **FIXED** | **P1** | `2c2c7e8` | `1f04321` |
| 2 | Corpus gigante (10×100k linhas, 226 MB) | **FIXED** | **P2** | `e58ba4f` | `4c28065` |
| 3 | Truncamento concorrente (1.200+ iterações) | PASS (melhorado) | P3 (documento) | `e58ba4f` | `4c28065` |
| 4 | Arquivos hostis (symlink, chmod 000, FIFO) | PASS | — | — | — |
| 5 | Offset corrompido (`0xFFFF…FFFF` e `-1`) | PASS | — | — | (coberto por `testCorruptedFileStartsEmpty`) |
| 6 | Segurança (greps, heartbeat, `log stream`) | PASS | — | — | — |
| 7 | Diretório some no meio (`rm -rf` + recriação) | PASS | — | — | — |

**Suíte final: 53 testes verdes** (44 base + 9 regressões novas). E2E: 6 PASS, 0 falhas.

---

## Caso 1 — Fuzz do parser: FIXED (P1, crash)

**Ataque:** corpus de 1.011 linhas com bytes 0x00–0xFF, JSON de 200k níveis, unicode hostil (RTL, combining stack, emoji), linha de 5 MB e 6 MB, `1e999`, chaves duplicadas, `Int64.max` em usage — rodado via `.build/release/tokenbar selfcheck <corpus>`.

**Achado:** o app **crashava com SIGTRAP (exit 133)** por overflow de `Int64` em dois pontos:

1. Guard do parser (`ClaudeLineParser.swift:36`): `input + output + cacheRead + cacheWrite > 0` estoura com `input_tokens: 9223372036854775807` + qualquer outro campo positivo (crash report `tokenbar-2026-09-02-194520.ips`, stack confirmando `Swift runtime failure: arithmetic overflow`).
2. `TokenSums.+`/`total` no ledger: duas linhas com `Int64.max` acumulam `max + max` → trap.

Bisect: corpus com IMAX → EXIT=133; sem as linhas IMAX → 3× EXIT=0, stderr vazio (JSON profundo, unicode, linhas de 5–6 MB e bytes aleatórios não derrubam; `eventsApplied` e totais consistentes).

**Fix:** saneamento por campo — usage com qualquer campo > 10^15 é lixo, não uso (linha rejeitada); `TokenSums` com aritmética saturante (`addingReportingOverflow` → clamp em `.max`/`.min`), blindando a acumulação no ledger contra qualquer caminho futuro.

**Testes (vermelhos antes do fix — a suíte morria com signal 5):** `usageFieldsNearInt64MaxAreRejectedNotCrash`, `usageFieldsAtSanityCapBoundaryStillCounted`, `testTokenSumsSaturatesInsteadOfTrapping`. Pós-fix: corpus fuzz completo EXIT=0; linhas IMAX rejeitadas; totais do corpus sem IMAX preservados (15030).

---

## Caso 2 — Corpus gigante: FIXED (P2, orçamento de recursos)

**Ataque:** `genfixtures --sessions 10 --lines 100000` (226 MB, 1M eventos, 10 arquivos), selfcheck 10×, e app real (`TOKENBAR_CLAUDE_DIR`) com cold ingest + 10 ciclos de append.

**Achados (antes do fix):**

| Métrica | Orçamento | Antes | Depois |
|---|---|---|---|
| selfcheck (1M linhas) | < 10 s | 41,2–42,0 s | **8,6–9,0 s** |
| maxRSS selfcheck | ≤ 40 MB | ~450 MB | **15 MB** |
| cold ingest do app (1º heartbeat) | — | 108–110 s | **9,1 s** |
| footprint 1º vs 10º ciclo (app) | estável ≤ 40 MB | 283–347 MB (spike) | **15,6 MB estável** |
| live update (ciclos 2–10) | — | ok | 3–4 s por delta |

**Causas-raiz (micro-benchmark por componente, 200k linhas):**
- `ISO8601DateFormatter`: **30,6 µs/linha** (7× o custo do decode JSON, 4,25 µs) — dominava os 41 s.
- Buffers de 256 KB por chunk/segmento liberados e retidos pela zona do malloc (`heap`: 735 × 256 KB ≈ 188 MB de arena) — footprint alto mesmo sem retenção lógica.
- `TranscriptIngester` acumulava TODOS os eventos do ciclo em memória (1M UsageEvents ≈ centenas de MB) antes de aplicar no ledger.

**Fix (`e58ba4f`):**
- `TranscriptIngester`: núcleo streaming com **janela única de 256 KB reutilizada** (`read(2)` + memmove da cauda; zero alocação por chunk), autoreleasepool por segmento, modo *skip* para linhas maiores que a janela (cursor exato, memória limitada), eventos entregues **por lote** via callback e descartados.
- API de array `ingestChangedFiles` preservada (wraps o streaming; usada nos testes).
- `TokenLedger`: actor → classe `Sendable` com `OSAllocatedUnfairLock` (padrão `JSONFileOffsetStore`) — apply síncrono no hot loop, filtro de "hoje" por intervalo (O(1) por evento, equivalente a `startOfDay(event.ts) == hoje`).
- `ClaudeLineParser`: `fastISO8601` próprio (~0,06 µs/linha; fallback para o formatter em formas exóticas — paridade validada em 10k timestamps do corpus real, 0 divergências) e `JSONDecoder` reutilizado.

**Testes:** `testStreamingDeliversLargeFileInBoundedBatches` (arquivo > janela → múltiplos lotes, zero perda), `testStreamingCarriesPartialLineAcrossChunks` (cauda parcial não duplica nem perde), `fastISO8601MatchesFormatterOnAcceptedForms` + `...OnCorpusTimestamps` (paridade). Perf smoke existente (10k eventos < 1 s) segue verde (0,014 s).

---

## Caso 3 — Truncamento concorrente: PASS (P3 documentado + melhoria)

**Ataque:** 100× append+truncate em arquivo monitorado pelo app, seguido de 1.200 iterações de churn aleatório (append 50% / truncate-0 35% / truncate parcial 15%) em 2 arquivos, com checagem de liveness por iteração.

**Resultado:** sem crash, sem hang; totais se autocorrigem com precisão — pós-churn, heartbeat 578.262 == verdade recalculada por selfcheck snapshot (578.262).

**P3 documentado (e corrigido de quebra):** truncamento a zero **sem linhas novas** não emitia resultado — o cursor ficava retido e a soma do arquivo permanecia no total até o próximo append (janela de staleness). O núcleo streaming agora sinaliza `reset` mesmo sem linhas (`testTruncateToZeroEmitsResetEvenWithoutNewLines`, vermelho antes do fix: retornava array vazio) e o flag de reset vai só no primeiro lote (`testStreamingResetFlagOnlyOnFirstBatchOfShrunkFile`).

**Nota de harness:** duas "mortes do app" durante o caso 3 foram atribuídas ao churn e depois **refutadas**: apps lançados em background sem `nohup` morriam por HUP na fronteira entre comandos do harness. Com `nohup`, o app sobreviveu a 1.200+ iterações. Anomalia equivalente do caso 2 (live update "morto" pós-cold ingest) teve a mesma causa — retirada do rol de achados.

---

## Caso 4 — Arquivos hostis: PASS

Symlink para `.jsonl` válido fora do diretório, symlink para `/etc/hosts`, symlink pendente, `perm000.jsonl` (chmod 000) e FIFO `fifo.jsonl` injetados no diretório monitorado com o app rodando.

- Sem crash, sem hang; heartbeat renovado em ≤ 12 s (gate ≤ 15 s); ingest seguinte operante (delta +22 em 4 s).
- `isRegularFile` **não segue symlink** → conteúdo externo NÃO foi ingerido (777 tokens fora não contaram); FIFO e pendentes ignorados; chmod 000 falha no open e é pulada sem quebrar o ciclo.

---

## Caso 5 — Offset corrompido: PASS

`cursors.json` editado com o app parado: `offset: 18446744073709551615` (UInt64.max) para um arquivo e `offset: -1` para outro.

- Comportamento **documentado e reprodutível** (`JSONFileOffsetStore`): JSON com `-1` falha o decode de `UInt64` → estado vazio → re-ingest completa; offset absurdo cai no caminho de reset (size < previous) → re-ingest do zero.
- Heartbeat em 2 s com totais corretos (550 = soma completa dos dois arquivos), cursors regravados sãos (121/119), sem crash e sem loop (ciclo seguinte entra no caminho "inalterado").

---

## Caso 6 — Segurança: PASS

- `grep -rniE "credentials|auth\.json|keychain|oauth" Sources/` → **zero match** (F1 não toca credenciais).
- Superfície de saída: só `print` do selfcheck/genfixtures com JSON de somas — sem Logger/NSLog em nenhum módulo.
- `/usr/bin/log stream --predicate 'process == "tokenbar"'` durante ingest com marcador único (`MARCADOR-RT-XYZ-9f3a`) no transcript: 172 linhas capturadas, todas de frameworks do sistema — **0 ocorrências do marcador**; stderr do app vazio.
- Heartbeat contém apenas `menuBarText`, `todayTokens` (somas) e `updatedAt` — sem paths, sem conteúdo de transcript.

---

## Caso 7 — Diretório some no meio: PASS

- `rm -rf` do corpus com o app monitorando: sem crash, sem hang; evento de deleção dispara ingest, diretório ausente retorna vazio e o heartbeat continua sendo reescrito (updatedAt avança, totais retidos).
- Recriação do diretório com conteúdo novo: **ingest retomado em ~4–22 s** (FSEvents dispara na raiz recriada; o fallback poll de 15 min não foi necessário).

---

## Preocupações residuais (observação, sem ação na F1)

1. **Tempo do caso 2 ficou no limite (8,6–9,0 s vs < 10 s).** O dominador restante é o `JSONDecoder` (~4,3 µs/linha). Para F2+, parse direto do segmento (sem `String` intermediária) ou `JSONSerialization` direcionado podem reduzir 2–3×, se o orçamento apertar.
2. **FSEvents na raiz recriada funcionou no teste, mas não há flag `WatchRoot`** — recomenda-se rever no scheduler adaptativo da F2.
3. **Selfcheck usa a API de array** (retém eventos do ciclo em memória) — ok para corpora de teste; o app usa o streaming. Manter assim.
4. Transcripts reais do Claude têm linhas de assistant muito maiores que as do genfixtures (~240 B); o orçamento de tempo por linha real pode ser maior — reavaliar com corpus real anonimizado na F2.

## Artefatos

- Commits: `1f04321` (teste caso 1), `2c2c7e8` (fix caso 1), `e58ba4f` (fix casos 2/3), `4c28065` (testes casos 2/3), este relatório.
- Corpus fuzz: `/tmp/rt-fuzz/` (regenerável por `genfuzz.py`); corpus gigante: `/tmp/rt-giant`.
- Evidências de crash: `~/Library/Logs/DiagnosticReports/tokenbar-2026-09-02-1945*.ips` (overflow, pré-fix).
