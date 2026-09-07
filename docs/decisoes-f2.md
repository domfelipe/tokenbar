# TokenBar — F2 · Decisões Técnicas

Data: 2026-09-03
Projeto: tokenbar (F2 — Codex + Gemini + Z.ai)
Complemento de `docs/decisoes-f1.md` (mesmo formato: contexto → decisão → consequência). Rulings registradas no ledger SDD durante as Tasks 1–7 e consolidadas aqui na T8.

---

## Decisão 1: F2-SCOPE — re-escopo para Codex + Gemini + Z.ai

**Contexto:** A F1 entregou só Claude, que o usuário não usa ativamente. O plano original puxava novos providers só na F5.

**Decisão:** F2 re-escopada para os providers em uso real: Codex (API + ingest local), Z.ai coding plan (API only) e Gemini CLI (local only). Providers da F5 (Cursor, OpenRouter, Copilot) continuam no roadmap.

**Consequência:** valor imediato para o usuário (menu bar mostra o que ele de fato usa); custo se errado é menor — a arquitetura `UsageProvider` aceita novos providers sem reescrita.

## Decisão 2: F2-GEMINI — tokens REAIS com dedupe por id (estimativa refutada)

**Contexto:** A descoberta inicial (Task 1) concluiu que o Gemini não tinha tokens no arquivo e a primeira ruling criou estimativa (chars/4) com prefixo "≈". O review da Task 1 refutou a premissa: as linhas-raiz `type: "gemini"` trazem `{input, output, cached, thoughts, tool, total}`.

**Decisão:** ingest conta tokens REAIS, sem estimativa nem prefixo "≈" (proibido reintroduzir). Como o CLI REANEXA a mesma linha-raiz ao retomar (duplicata real observada), dedupe por `id` é obrigatório — o dedupe vive no provider (`GeminiDedupe`), semeado pelos `seenIDs` persistidos no cursor.

**Consequência:** número honesto (medição, não estimativa); duplicata não dobra o total. Se um formato futuro mudar o schema, o parser tolerante ignora linhas desconhecidas — degrada, nunca inventa.

## Decisão 3: F2-GEMINI-FIELDS — split de componentes

**Contexto:** `tokens.total` do Gemini = `input + output + thoughts + tool` (verificado), mas o `UsageEvent` precisa do split input/output para analytics.

**Decisão:** `inputTokens = tokens.input`; `outputTokens = output + thoughts + tool` (consistência com Claude/Codex, onde output engloba reasoning); `cacheReadTokens = tokens.cached`; `total` é só checksum — divergência aceita os componentes e segue. `cached` e `tool` eram 0 em todas as amostras; reavaliar se aparecerem > 0.

**Consequência:** split consistente entre providers; a composição do output é SATURANTE (`TokenSums.saturatingSum`) — campos ~Int64.max com `+` comum trapavam antes do saneamento (Red Team T8, P1).

## Decisão 4: F2-CODEX-DELTA — contar só `last_token_usage`

**Contexto:** os rollouts do Codex trazem `last_token_usage` (delta por evento) e `total_token_usage` (cumulativo) dentro do mesmo `token_count`.

**Decisão:** somar SOMENTE `last_token_usage`; `total_token_usage` é ignorado de propósito. `reasoning_output_tokens` é subconjunto de `output_tokens` (não soma).

**Consequência:** contar os dois duplicaria tudo. Pino de regressão: `ingestCountsOnlyLastTokenUsageDeltas` (377, não 377+377+260).

## Decisão 5: F2-CODEX-404 — 404 do wham/usage é transiente, não degradação

**Contexto:** a spec §1.7 pedia degradação para local em 404 (endpoint privado, sem contrato). Degradar num 404 transiente faria a UI piscar para local.

**Decisão:** 404/500/erros de rede → rethrow e o scheduler aplica backoff (o último snapshot bom permanece); só 401/403 degrada para `authState: .invalid` (token expirado — `codex login` resolve). Desvio consciente da spec §1.7, registrado.

**Consequência:** "nunca dado errado" preservado; se o endpoint for removido permanentemente, o provider fica em backoff etário em vez de badge local — visível pelo timestamp `fetchedAt` antigo. Aceitável e monitorável.

## Decisão 6: F2-CURSOR-CONTRACT — semeadura de cursor só de fonte própria

**Contexto:** cursor defasado ou de outro provider causa re-leitura total (duplicação) ou perda silenciosa de eventos.

**Decisão:** chamadores de `ingestLocal` semeiam o ciclo SOMENTE com (a) o `nextCursor` que ESTE provider devolveu no ciclo anterior, ou (b) o estado fresco do store de cursores do próprio provider. Nunca cursor construído fora daí. Documentado no protocolo `UsageProvider`.

**Consequência:** a virada de dia (rollover) pode descartar o cursor semeado e re-escanear do zero — o `nextCursor` devolvido reflete o que o ciclo de fato consumiu.

## Decisão 7: cursor file POR provider (obrigação dura do wiring)

**Contexto:** o rollover zera todos os paths do store injetado; compartilhar um `cursors.json` entre Claude/Codex/Gemini zeraria os cursores dos outros providers.

**Decisão:** um arquivo por provider no App Support: `claude-cursors.json`, `codex-cursors.json`, `gemini-cursors.json` (fábrica default do `ProviderCoordinatorConfig`), mais um `<provider>-ledger.json` de snapshot do dia (decisão 10).

**Consequência:** rollover de um provider não contamina os outros; introspecção simples (um arquivo por provider, paths iguais aos dos cursores).

## Decisão 8: auth dual Z.ai — apiKey primeiro, OAuth no fallback; validação real pendente

**Contexto:** o endpoint de quota da Z.ai é historicamente consumido com API key; o aceite do OAuth `access_token` do coding plan não estava verificado (risco nº 1 da Task 5).

**Decisão:** ordem de credenciais: `options.apiKey` de `config.json` (mesmo tipo que o CLI consome) → fallback `oauth:zai:access_token` de `credentials.json`. 401/403 numa credencial tenta a próxima (no máximo 2 requests por ciclo — não é retry do mesmo request). Região detectada pelo host do `options.baseURL` (`api.z.ai` → global; `open.bigmodel.cn` → CN).

**Consequência:** durante a T8 o app buscou o endpoint real e recebeu dados válidos — o par embutido funciona. QUAL das duas credenciais foi aceita não é distinguível sem log (e nunca vamos logar credencial), então a validação isolada de cada uma segue pendente, mitigada pelo fallback. Detecção de região errada → 404/401 → degradação visível.

## Decisão 9: heartbeat v2 — diagnóstico completo, erro tokenizado

**Contexto:** o heartbeat da F1 tinha só totais agregados; a F2 precisa observar estado POR provider (auth, freshness) sem vazar paths/credenciais (spec §9).

**Decisão:** formato v2: `{"menuBarText", "providers": {id: {menuBar, percent, todayTokens, authState, fetchedAt, error?}}, "updatedAt"}` — lista TODOS os providers registrados, inclusive os degradados sem dado nenhum (provider cujo 1º ciclo lança entra vazio + erro tokenizado; fix `34cd627`). Mensagem de erro nunca crua (URL/shape) — token curto (`network`/`http`/`decode`/`unauthorized`).

**Consequência:** o selfcheck de degradação do E2E lê o estado real de cada provider; o preço é um payload maior — irrelevante (arquivo local de diagnóstico).

## Decisão 10: restart mid-day — snapshot do ledger do dia (Red Team caso 7)

**Contexto:** pendência da T7: cursores persistem, o ledger era volátil — restart no meio do dia zerava o total até o rollover de meia-noite. Fix candidato da T7 era re-scan do zero no 1º ciclo (custo: ~10 GB de leitura no Codex, ~11,5 min, todo launch).

**Decisão:** snapshot POR ARQUIVO do dia (`<provider>-ledger.json` com componentes `TokenSums` por path), gravado DEPOIS dos cursores a cada ciclo (crash entre escritas → subconta last-good, nunca superconta) e restaurado 1× por processo se o dia bater. Integridade: o snapshot carrega um stamp FNV-1a do estado dos cursores — store perdido/corrompido invalida o snapshot (re-ingest reconstrói, sem dobrar — Red Team caso 5). Selfcheck read-only (snapshot desativado).

**Consequência:** restart volta com os totais do dia imediatamente (provado no app: 4998 → 0 vira 4998 → 4998); a auto-correção F1 contra truncamento é preservada (granularidade por arquivo); custo: uma escrita JSON pequena por ciclo por provider. Achado colateral: `TokenLedger.currentDay` nascia do relógio real — 1º ciclo com `now` divergente disparava re-scan espúrio; agora o 1º ciclo só registra o dia.

## Decisão 11: saneamento de usage em todos os parsers (Red Team T8, P1)

**Contexto:** o cap F1 (>10^15 = lixo) existia nos 3 parsers, mas o Gemini somava `output + thoughts + tool` com `+` comum ANTES do cap — `Int64.max` nos campos trapava (SIGTRAP, exit 133).

**Decisão:** toda composição aritmética de campos de usage usa soma saturante (`TokenSums.saturatingSum`) ANTES do saneamento; `TokenSums` já era saturante na acumulação.

**Consequência:** qualquer campo hostil vira linha rejeitada, nunca crash. Regressão obriga em cada parser novo.

## Decisão 12: E2E v2 com mock server embutido

**Contexto:** a F2 tem providers API-driven; o E2E da F1 só cobria ingest local. Usar APIs reais num teste automatizado é instável e toca credencial real.

**Decisão:** `scripts/e2e.sh` sobe um mock `python3 http.server` com handler JSON embutido nas rotas canônicas (`/backend-api/wham/usage`, `/api/monitor/usage/quota/limit`), apontado via `TOKENBAR_CODEX_API`/`TOKENBAR_ZAI_API`, com credenciais 100% fake, log de requests (inclui o header Authorization — prova de que só fake circula), modo 500 por arquivo de controle para o Red Team e cenário de degradação (mock morto → app vivo, selfcheck diagnostica `network`).

**Consequência:** E2E determinístico e sem rede externa; o orçamento de recursos da F1 (footprint ≤40 MB, CPU ≤0,5%) segue como gate. overrides `TOKENBAR_*_DIR` garantem que o teste nunca toca os diretórios reais do usuário.
