# F2 — Relatório Red Team (Task 8, protocolo Simulador DomHubs)

**Data:** 2026-09-03 · **Alvo:** branch `f2-codex-gemini-zai` · **Baseline antes da bateria:** 184 testes verdes (`./run-tests.sh`), E2E v2 15 PASS.

**Escopo:** bateria adversarial de 7 casos sobre os 3 parsers locais (Claude/Codex/Gemini), os 2 decoders de API (Codex/Z.ai), o transporte de credenciais, o scheduler com backoff, os stores de cursor/ledger e o orçamento de recursos multi-provider, conforme brief da T8 e spec `docs/specs/f2-data-sources.md` (§5 tolerância, §7 orçamento, §9 segurança).

---

## Resumo

| # | Caso | Resultado | Severidade | Fix | Teste de regressão |
|---|------|-----------|------------|-----|--------------------|
| 1 | Fuzz dos 3 parsers + decoders de API | **FIXED** | **P1** | `fa0ea40` | `nearInt64MaxComponentSumIsRejectedNotCrash` |
| 2 | Credenciais: grep total, read-only, log stream | PASS | — | — | — |
| 3 | 401/403/500 storm → backoff visível, sem retry storm | PASS (medido) | — | — | (coberto por `errorBackoffDoubles…` do scheduler) |
| 4 | Mock cai no meio do ciclo → recupera quando volta | PASS | — | — | (e2e: degradação + selfcheck `network`) |
| 5 | Offsets corrompidos nos 3 cursor files | **PASS + achado** | **P2** | `2dca544` | `lostCursorsInvalidateSnapshotNoDoubleCount` |
| 6 | Corpus gigante multi-provider dentro do orçamento | PASS | — | — | — |
| 7 | Restart mid-day subconta (pendência da T7) | **FIXED** | **P1 (UX/correção)** | `66558c7` + `2dca544` | 11 testes novos de snapshot/ledger |

**Suíte final: 199 testes verdes** (184 base + 15 regressões). E2E v2: 15 PASS, exit 0.

---

## Caso 1 — Fuzz dos 3 parsers: FIXED (P1, crash)

**Ataque:** 3 corpora hostis (um por formato) com ~40 linhas venenosas cada — `Int64.max` em todos os campos de usage, negativos, `1e999`, strings no lugar de número, nulls, timestamps hostis (`not-a-date`, `9999-99-99`, mês 13), tipos errados no envelope, JSON de 200k níveis, unicode hostil (RTL/combining/emoji), JSON truncado, chaves duplicadas, linhas de 5–6 MB, bytes binários 0x00–0xFF — rodados via selfcheck, 3 rodadas. Em paralelo, os **decoders de API** (Codex `wham/usage`, Z.ai `quota/limit`) sob 3 shapes hostis rotativos via mock (tipos errados, `used_percent: "9e999"`, `reset_at` negativo, limits com elementos não-objeto e tipo desconhecido, payload de 3 MB).

**Achado (pré-fix):** o app **crashava com SIGTRAP (exit 133)** nas 3 rodadas. Bisect: só o corpus Gemini crasha (Claude e Codex passam). Causa-raiz: `GeminiLineParser` compõe `output = output + thoughts + tool` com `+` comum **antes** do saneamento — três campos ~`Int64.max` estouram antes de chegar ao cap de 10^15 herdado da F1. O Codex não soma antes do cap; o Claude já tinha aritmética saturante da F1.

**Fix (`fa0ea40`):** `TokenSums.saturatingSum` público; a composição do output Gemini usa soma saturante — linha hostil vira lixo rejeitado pelo cap, não trap.

**Pós-fix:** 3 rodadas → `EXIT=0`, JSON válido, stderr vazio, totais determinísticos (só as linhas legítimas contam). Decoders de API: nenhum crash; respostas fora do contrato (`success ≠ true`) viram erro tokenizado (`ZaiAPIStatusError` → transiente); percentuais absurdos saturam no clamp 0–100 já especificado.

**Regressão:** `nearInt64MaxComponentSumIsRejectedNotCrash` (vermelho antes do fix: a suíte morria com signal 5).

---

## Caso 2 — Credenciais: PASS

- `grep -rniE` (padrões JWT `eyJ…`, `sk-…`, `Bearer <20+>`, `api_key/access_token` com valores longos, `ghp_`, `AKIA`) sobre `Sources/` + `scripts/` + `docs/` → **zero match real**; únicos valores presentes são `fake-token`/`fake-api-key` de fixtures.
- **Read-only:** `CodexAuthReader` e `ZaiCredentialReader` não contêm nenhuma escrita (nenhum `Data.write`/`removeItem`); nenhum `print`/`NSLog`/`Logger` em `TokenBarProviders` nem no `UsageHTTPClient`.
- **Log stream** (`log stream --predicate 'process == "tokenbar"'`, 45 s) durante app real com marcador único embutido no nome de transcript E nos valores das credenciais fake: 299 linhas capturadas (todas de frameworks), **0 ocorrências do marcador**, 0 ocorrências de `fake-token`/`fake-api-key`.
- **Mock captura headers:** o mock do E2E loga o `Authorization` de cada request — só `Bearer fake-*` (fixtures fake, nada real p/ vazar).
- **Heartbeat/selfcheck:** chaves por provider ⊆ `{menuBar, percent, todayTokens, authState, fetchedAt, error}` — sem paths, sem conteúdo, sem credencial; o `error` é token curto (`network`/`http`/`decode`), nunca mensagem crua com URL.

---

## Caso 3 — 500 storm: PASS (backoff medido, sem retry storm)

**Ataque:** app real contra mock que responde **500 sempre** (mesma rota sintética), janela de observação de 780 s com log de timestamps por request (`docs/qa/evidence/f2-rt3-500storm-requests.log`).

**Medição:**

| Métrica | Valor |
|---|---|
| Requests totais em 13 min | **4** (2 codex + 2 z.ai) — 1 por provider no burst inicial + 1 retry |
| Gap inicial → 2º request | **673 s** (nominal 600 s = backoff ×2 do ocioso 300 s; +13 s de overshoot do harness sob carga) |
| Max requests em janela de 10 s | 2 (o próprio burst inicial) |

**Conclusão:** sob erro persistente a cadência é ~1 request/11 min e decrescente (300→600→1200…, teto 30 min), nunca retry storm. O dobramento está pinado nos testes do scheduler (`errorBackoffDoublesWithThirtyMinuteCeilingAndSuccessResets`). 401/403 entram no mesmo caminho (`noteResult(ok: false)`; 401/403 com credencial dupla Z.ai tenta a 2ª credencial — no máximo 2 requests por ciclo, sem retry do mesmo request).

---

## Caso 4 — Mock cai no meio do ciclo: PASS

**Ataque (3 fases, app real + AX):**

1. Mock no ar (X:42%, Z:81%) → heartbeat correto.
2. `kill -9` no mock + Refresh via menu (AX) → **app vivo**, display mantém último estado bom (último-estado, nunca dado errado); o diagnóstico da degradação fica no selfcheck v2 (erro tokenizado `network` — mesmo instrumento do E2E).
3. Mock de volta na MESMA porta com valores novos (55%/91%) + Refresh via menu → heartbeat **X:55% Z:91%** — recuperação provada por ciclo real (valores novos, não resíduo).

Complemento do E2E: com o mock morto e SEM interação, o app segue vivo >60 s, heartbeat continua avançando via providers locais (Δ=+222 observado) e **0 requests** na janela (sem storm de reconexão).

---

## Caso 5 — Offsets corrompidos nos 3 cursor files: PASS + achado (P2)

**Ataque:** com o app parado, corrupção direcionada dos 3 arquivos no App Support (entradas de paths de teste): Claude `offset = 18446744073709551615` (UInt64.max), Codex `offset = -1` (inválido p/ UInt64 → decode do arquivo inteiro falha → estado vazio), Gemini **arquivo inteiro como JSON lixo**. Relançamento e observação de 2 ciclos.

**Resultado:** sem crash, sem loop; todos os providers re-ingestam e reproduzem os totais exatos (`C:1.8k X:260 G:193`); cursores regravados sãos (offset == tamanho real dos arquivos); 2º ciclo estável (caminho "inalterado").

**Achado (P2, fix `2dca544`):** cursores perdidos + snapshot do ledger (fix do caso 7) = **dia contado em dobro** — o re-ingest completo re-aplicaria eventos sobre o total restaurado. Fix: o snapshot carrega um **stamp FNV-1a do estado dos cursores** no save; a restauração só vale se o stamp bater — store perdido/corrompido invalida o snapshot e o re-ingest reconstrói honestamente. Regressão: `lostCursorsInvalidateSnapshotNoDoubleCount`.

---

## Caso 6 — Corpus gigante multi-provider: PASS (orçamento)

**Ataque:** ingest frio no app real de **119 MB** (Claude: 6 sessões × 60k linhas = 369k linhas com poison; Codex: 3 rollouts sintéticos × 50k linhas com 10k `token_count` cada; Gemini sintético), com `phys_footprint` amostrado por ~1 s durante o ingest.

| Métrica | Orçamento | Medido |
|---|---|---|
| Cold ingest até 1º heartbeat | — | **9,1 s** |
| Footprint máximo durante ingest (amostrado) | ≤ 40 MB | **17,5 MB** |
| Total do Codex vs verdade do gerador | exato | **186.000.000 == 186.000.000** (só `last_token_usage` — F2-CODEX-DELTA) |
| Extrapolação linear p/ corpus real ~10 GB | — | **~13 min** (coerente com os ~11,5 min medidos na T7 sobre dados reais) |

Memória bounded durante ingest frio confirmada (o streaming entrega lotes e descarta; o pico não escala com o arquivo — mesma conclusão da F1, agora com API + 3 providers no mesmo processo). Amostras: `docs/qa/evidence/f2-rt6-footprint.log`.

---

## Caso 7 — Restart mid-day subconta: FIXED (P1 de correção, pendência da T7)

**Reprodução (pré-fix, app real):** corpus com eventos de hoje → app ingere (`C:5.0k`, 4998) → kill → relança (mesmos cursores, nenhum evento novo) → heartbeat `C:0` — os totais de hoje só voltariam no rollover de meia-noite. Causa: cursores persistem, ledger é volátil.

**Fix (`66558c7`):** cada provider com ingest persiste um **snapshot do ledger do dia** (`<provider>-ledger.json`, por ARQUIVO com componentes de `TokenSums`), gravado **depois** dos cursores (ordem que evita dupla contagem em crash entre escritas), e o restaura **1× por processo** se o dia bater. Granularidade por arquivo preserva a auto-correção F1 contra truncamento. O selfcheck fica read-only (snapshot desativado).

**Achados colaterais corrigidos no mesmo pacote:**
- `TokenLedger.currentDay` nascia do relógio real no init — 1º ciclo com `now` divergente do launch disparava `needsFullRescan` espúrio (re-scan completo; dobraria com o snapshot). Agora `currentDay` nasce `nil` e o 1º ciclo só registra o dia (`testFirstCycleRecordsDayWithoutSpuriousRescan`).
- O stamp de cursores do caso 5 (`2dca544`) fecha o ciclo de integridade snapshot↔cursores.

**Prova pós-fix (app real):** 1º run `C:5.0k` (4998) → kill → relança → `C:5.0k` (4998) imediatamente. Regressões: 6 testes de semântica do ledger + restart nos 3 providers + truncamento-pós-restore + snapshot corrompido + cursores perdidos.

---

## Preocupações residuais (documentadas, sem ação na F2)

1. **Restauração é "last-good honesta":** crash ENTRE a gravação dos cursores e a do snapshot (mesma janela de milissegundos por ciclo) deixa o snapshot um ciclo atrás — subconta até o próximo evento do dia (nunca superconta; a ordem escolhida garante isso). Sem correção barata além desta.
2. **Stamp de cursor não cobre `seenIDs`:** se os cursores sobrevivem mas um `seenIDs` do Gemini se perde mantendo o offset, duplicatas reanexadas no tail já consumido não são re-dedupicadas. Janela mínima e auto-corrigida no rollover; monitorar.
3. **Overshoot do sleep do scheduler sob carga** (~2% no gap de 673 s vs 660 s teórico): Task.sleep não é hard real-time; irrelevante para o orçamento.
4. **Instâncias de teste compartilham o App Support** com a instalação real do usuário (o app não respeita `HOME` override no `NSHomeDirectory`) — os harnesses da T8 fizeram scrub das entradas `/tmp` dos stores reais ao fim de cada caso. Para F3: considerar env `TOKENBAR_SUPPORT_DIR` para isolamento limpo de testes.

## Artefatos

- Commits: `34cd627` (heartbeat v2 degradado), `ae65a92` (e2e v2), `66558c7` (snapshot do ledger), `fa0ea40` (saturação Gemini P1), `2dca544` (stamp de cursores), este relatório.
- Evidências: `docs/qa/evidence/f2-rt3-500storm-requests.log`, `docs/qa/evidence/f2-rt6-footprint.log`, `docs/qa/evidence/f2-visual-ax-f2.md`.
- Corpora: `/tmp/tb-rt1` (fuzz), `/tmp/tb-rt6` (gigante) — regeneráveis; removidos ao fim da T8.
