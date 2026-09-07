# F2 — Fontes de dados: Codex, Z.ai, Gemini (referência de implementação)

- **Data:** 2026-09-02 · **Task:** 1 (spike de descoberta) · **Consomem:** Tasks 3–5 do plano `docs/plans/2026-09-02-f2-codex-gemini-zai.md`
- **Fontes:** CodexBar (MIT, github.com/steipete/CodexBar, branch `main` em 2026-09-02) + inspeção de schemas locais nesta máquina (2026-09-02).
- **Segurança:** todo exemplo abaixo é **sintético**. Tokens aparecem como `fake-token`; números são inventados. Nunca copiar valor real (nem truncado) para fixture, log ou teste — o repo é público.

Resumo por provider:

| Provider | Modo F2 | API de usage | Ingest local | Credencial |
|---|---|---|---|---|
| Codex (OpenAI/ChatGPT) | API + local | `GET https://chatgpt.com/backend-api/wham/usage` | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | `~/.codex/auth.json` → `.tokens.access_token` |
| Z.ai (coding plan) | API | `GET https://api.z.ai/api/monitor/usage/quota/limit` | — (nenhum) | `~/.zcode/v2/credentials.json` → `oauth:zai:access_token` (ver §2.2) |
| Gemini CLI | Local only | — (fora do escopo; ver §3.6) | `~/.gemini/tmp/<projeto>/chats/session-*.jsonl` | sem uso em F2 |

---

## 1. Codex (OpenAI / ChatGPT)

### 1.1 Usage API

- **URL:** `GET https://chatgpt.com/backend-api/wham/usage`
  - Override: `chatgpt_base_url` em `~/.codex/config.toml` (CodexBar também aceita env). Regra do CodexBar: se a base contém `/backend-api` → path `/wham/usage`; senão → `/api/codex/usage`. TokenBar F2: usar a URL canônica e aceitar o override só se trivial.
- **Método:** GET, sem body. Cache desabilitado (CodexBar usa `.reloadIgnoringLocalCacheData`).
- **Headers:**
  - `Authorization: Bearer <access_token>` — obrigatório
  - `ChatGPT-Account-Id: <account_id>` — opcional; enviar quando houver (multi-conta/Team)
  - `Accept: application/json`
  - `User-Agent: TokenBar/<versão>` (CodexBar envia `CodexBar`; enviar sempre um UA — backend rejeita requests anômalos)
- **Timeout:** CodexBar usa 30 s; o contrato TokenBar (spec §5, regra 3) é **10 s, 1 tentativa**.
- **Status:** 2xx ok · 401/403 → `authState: .invalid` (token expirado; `codex login` resolve, nunca renovamos por ele) · outros → erro transiente (backoff do scheduler).

Endpoints auxiliares existentes no CodexBar (fora do escopo F2, registrados p/ referência): `GET /wham/rate-limit-reset-credits` (header extra `OpenAI-Beta: codex-1`) e `GET /accounts/<id>/spend-controls/current-user/monthly-usage`.

### 1.2 Auth local

`~/.codex/auth.json` — estrutura verificada (chaves, sem valores):

```json
{
  "OPENAI_API_KEY": null,
  "auth_mode": "chatgpt",
  "last_refresh": "2026-09-02T10:00:00.000Z",
  "tokens": {
    "access_token": "fake-token",
    "account_id": "fake-account-id",
    "id_token": "fake-jwt",
    "refresh_token": "fake-token"
  }
}
```

- **Access token:** `.tokens.access_token`
- **Account id:** `.tokens.account_id`; fallback (Contas antigas): claim `chatgpt_account_id` do payload JWT de `.tokens.id_token` / `.tokens.access_token`
- `auth_mode: "apikey"` (com `OPENAI_API_KEY` preenchida) → sem OAuth → **sem usage API**, só ingest local
- Ler read-only; quem renova é o `codex` (`last_refresh` é informativo)

### 1.3 Shape de resposta (sintético, anotado)

```json
{
  "account_id": "fake-account-id",
  "plan_type": "plus",
  "rate_limit": {
    "primary_window":   { "used_percent": 42, "reset_at": 1800000000, "limit_window_seconds": 18000 },
    "secondary_window": { "used_percent": 7,  "reset_at": 1800086400, "limit_window_seconds": 604800 },
    "individual_limit": null
  },
  "credits": { "has_credits": false, "unlimited": false, "balance": null },
  "additional_rate_limits": [
    {
      "limit_name": "gpt-5.3-codex-spark",
      "metered_feature": null,
      "rate_limit": {
        "primary_window": { "used_percent": 3, "reset_at": 1800000000, "limit_window_seconds": 18000 },
        "secondary_window": null
      }
    }
  ],
  "individual_limit": null,
  "spend_control": {
    "individual_limit": { "limit": 100.0, "used": 12.5, "remaining_percent": 87.5, "resets_at": 1800086400 }
  }
}
```

Tolerância de shape que o decoder precisa ter (CodexBar decora tudo como opcional):

- Alias snake/camel: `account_id|accountId`, `individual_limit|individualLimit`, `spend_control|spendControl`
- `SpendControlLimitSnapshot.resetsAt` aceita `resets_at|resetsAt|reset_at`; números podem chegar como int, double ou **string**
- `additional_rate_limits` é aditivo: entrada malformada não pode derrubar primary/secondary (decode por elemento, lossy)
- `reset_at` de janela = **epoch em segundos**

### 1.4 Mapeamento → `UsageSnapshot`/`UsageWindow` (spec §5.2)

| Campo da resposta | Destino |
|---|---|
| `rate_limit.primary_window` | `UsageWindow(kind: .session, usedFraction: used_percent/100, resetsAt: Date(timeIntervalSince1970: reset_at), label: "5h")` |
| `rate_limit.secondary_window` | `UsageWindow(kind: .weekly, …, label: "Semanal")` — usar `limit_window_seconds` (18000 = 5h, 604800 = 7d) para kind/label dinâmicos em vez de fixar |
| `additional_rate_limits[].rate_limit.*` | Janelas extras, `label: limit_name` (opcional na F2; mesmo decoder de janela) |
| `credits.balance` | `CreditsInfo` (USD) |
| `plan_type` | identidade exibida no menu/painel |
| `account_id` + `plan_type` | `AccountID(provider: .codex, key: account_id)` |

`usedFraction` sempre `Double?` — janela ausente/malformada → `nil`, snapshot segue vivo.

### 1.5 Ingest local — `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`

Cada linha é `{ "timestamp": ISO8601, "type": string, "payload": {...} }`. Tipos observados (jul/2026 e set/2026 — schema estável no período): `session_meta`, `response_item`, `event_msg`, `turn_context`, `world_state` (e `compacted` em arquivos mais antigos).

- **Linha 1** = `session_meta` (payload: `id`, `timestamp`, `cli_version`, `cwd`, `originator`, `context_window`, …). Pular.
- **Contagem de tokens** = linhas `type: "event_msg"` com `payload.type: "token_count"`:

```json
{
  "timestamp": "2026-09-02T19:56:34.486Z",
  "type": "event_msg",
  "payload": {
    "type": "token_count",
    "info": {
      "last_token_usage":  {
        "input_tokens": 10, "cached_input_tokens": 4, "cache_write_input_tokens": 2,
        "output_tokens": 112, "reasoning_output_tokens": 64, "total_tokens": 128 },
      "total_token_usage": { "input_tokens": 900, "cached_input_tokens": 120, "cache_write_input_tokens": 30,
        "output_tokens": 222, "reasoning_output_tokens": 130, "total_tokens": 1372 },
      "model_context_window": 272000
    },
    "rate_limits": {
      "plan_type": "plus",
      "primary":   { "used_percent": 42, "resets_at": 1800000000, "window_minutes": 300 },
      "secondary": { "used_percent": 7,  "resets_at": 1800086400, "window_minutes": 10080 }
    }
  }
}
```

Regras de contagem:

- **Somar `payload.info.last_token_usage`** (delta por evento). `total_token_usage` é **cumulativo** — somar os dois duplica tudo. Verificado: dois eventos consecutivos com last 110→112 e total 110→222.
- `reasoning_output_tokens` é subconjunto de `output_tokens` — não somar separadamente.
- Mapeamento → `UsageEvent`: `input=input_tokens`, `cacheRead=cached_input_tokens`, `cacheWrite=cache_write_input_tokens`, `output=output_tokens`, `ts=timestamp` (ISO8601 com fração + Z; reusar `fastISO8601` do padrão F1), `model` do **último** `turn_context` visto (`.payload.model`; muda no meio do arquivo), `project` = diretório do arquivo (padrão F1: `URL.deletingLastPathComponent().lastPathComponent` do projeto).
- `rate_limits` dentro do `token_count` tem shape **diferente** do `wham/usage` (`resets_at`/`window_minutes` vs `reset_at`/`limit_window_seconds`) — não reutilizar o mesmo decoder. Chaves extras observadas nesse objeto: `credits`, `individual_limit`, `limit_id`, `limit_name`, `rate_limit_reached_type`, `spend_control_reached` — decoder tolerante (ignorar desconhecidas); a fixture da Task 4 deve incluir linha com essas chaves.
- Performance: arquivos reais têm 1000+ linhas, maioria sem uso. Prefilter barato (linha contém `"token_count"`) antes de decodificar, mesmo padrão do `ClaudeLineParser` (que filtra `assistant`+`usage`).
- Incremental: herdar o padrão F1 (`TranscriptIngester` + `FileOffsetStore`, apêndice por byte offset).

### 1.6 Degradação

- `auth.json` ausente / sem `tokens` / `auth_mode: "apikey"` → snapshot `.localOnly` (ingest rollout), janelas `nil`.
- 401/403 na API → `authState: .invalid`, ingest local continua.

### 1.7 Riscos

- Endpoint **privado, sem contrato**; path já difere por base URL (`wham/usage` vs `api/codex/usage`). Mudança → 404 → degradar para local, nunca dado errado.
- Schema do rollout evolui por versão do CLI (`world_state` não existia em jul/2026). Parser tolerante: linha desconhecida → skip; campo novo → ignorar.
- Multi-conta Team: `account_id` do JWT pode divergir de `tokens.account_id`; preferir o campo do arquivo.

---

## 2. Z.ai (coding plan)

### 2.1 Endpoints (fonte: CodexBar `Resources/Plugins/zai.js` + `Providers/Zai/ZaiAPIRegion.swift`)

- **Quota do plano:** `GET https://api.z.ai/api/monitor/usage/quota/limit` (região global)
  ou `GET https://open.bigmodel.cn/api/monitor/usage/quota/limit` (região BigModel CN)
  - O plugin aceita override de endpoint por settings/env (`Z_AI_QUOTA_ENDPOINT`, e análogos `Z_AI_MODEL_USAGE_ENDPOINT`/`Z_AI_BALANCE_ENDPOINT`); TokenBar F2 usa as URLs canônicas, sem override.
  - Escopo team: `?type=2` + headers `Bigmodel-Organization: <org>` / `Bigmodel-Project: <project>`. **F2: personal only.**
- **Uso por modelo (opcional, gráficos):** `GET {base}/api/monitor/usage/model-usage?startTime=<YYYY-MM-DD HH:mm:ss>&endTime=<...>` → série por hora/dia.
- **Saldo (CN, pay-as-you-go, best-effort):** `GET https://www.bigmodel.cn/api/biz/account/query-customer-account-report` — só região CN; falha não pode derrubar a quota.
- **Headers:** `Authorization: Bearer <token>` (o plugin declara `auth: {type: "bearer"}`); `Accept: application/json` implícito no `getJSON`.

### 2.2 Auth local (TokenBar)

`~/.zcode/v2/credentials.json` — JSON **plano** (chaves verificadas):

```
oauth:zai:access_token   (string)  ← token do coding plan
oauth:zai:user_info      (string)
oauth:active_provider    (string)
zcodejwttoken            (string)
web-remote-control:external-relay:pass_hash (string)
```

- Token: chave de topo `oauth:zai:access_token`, header `Authorization: Bearer <valor>`.
- **Detecção de região** (descoberta local): `~/.zcode/v2/config.json` → `.provider["builtin:zai-coding-plan"].options.baseURL` = `https://api.z.ai/api/anthropic` (host `api.z.ai` → global); `builtin:bigmodel-coding-plan` → `https://open.bigmodel.cn/api/anthropic` (→ CN).
- **Fonte alternativa de auth:** `.provider["builtin:zai-coding-plan"].options.apiKey` (mesmo arquivo).
- **Caverna a validar na Task 5:** o endpoint de quota é historicamente consumido com **API key**; o aceite do OAuth `access_token` não está verificado. Ordem sugerida na implementação: tentar `options.apiKey` (mesmo tipo de credencial que o CLI usa no plano) e, se 401/403, tentar `oauth:zai:access_token`; fixar o que funcionar na chamada real de validação. Nenhum dos dois valores pode vazar em log/fixture.

### 2.3 Shape de resposta (sintético, anotado)

`GET .../quota/limit` → validação: `success === true && code === 200`:

```json
{
  "success": true,
  "code": 200,
  "msg": "",
  "data": {
    "planName": "GLM Coding Plan",
    "limits": [
      { "type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 12,
        "usage": 100000, "currentValue": 12000, "remaining": 88000,
        "nextResetTime": 1800086400000,
        "usageDetails": [ { "modelCode": "glm-4.7", "usage": 8000 } ] },
      { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 81,
        "usage": 120000, "currentValue": 97200, "remaining": 22800,
        "nextResetTime": 1800003600000, "usageDetails": [] },
      { "type": "TIME_LIMIT", "unit": 5, "number": 1, "percentage": 0,
        "usage": null, "currentValue": null, "remaining": null,
        "nextResetTime": 1800060000000,
        "usageDetails": [ { "modelCode": "glm-4.7-mcp", "usage": 3 } ] }
  ]
}
```

Semântica dos campos (lógica do `zai.js`):

- `type`: `TOKENS_LIMIT` | `TIME_LIMIT` | `CREDIT_LIMIT` (outros → descartar a entrada)
- `unit` → minutos: `1`=dia (×1440), `3`=hora (×60), `5`=minuto (×1), `6`=semana (×10080). Exceção: `TIME_LIMIT` com `unit=5, number=1` é o marcador **mensal MCP** (30 dias), não "1 minuto".
- `percentage` já vem 0–100; quando `usage>0`, o plugin recalcula de `usage`/`remaining`/`currentValue` e clampa 0–100.
- `nextResetTime` = epoch em **milissegundos** (Codex usa segundos — não confundir).
- Plano: primeiro campo string presente entre `planName`, `plan`, `plan_type`, `packageName`, `level`.

### 2.4 Mapeamento → `UsageSnapshot`

| Resposta | Destino |
|---|---|
| `TOKENS_LIMIT`/`CREDIT_LIMIT` de janela **mais curta** (ordenar por minutos) | `UsageWindow(kind: .session, usedFraction: percentage/100, resetsAt: Date(ms: nextResetTime), label: "5h"/conforme janela)` |
| `TOKENS_LIMIT`/`CREDIT_LIMIT` de janela **mais longa** | `UsageWindow(kind: .weekly, …)` |
| `TIME_LIMIT` | Janela extra, `label: "MCP"` (kind: `.daily` como aproximação ou estender `WindowKind` — decisão da Task 5) |
| `planName` | identidade/conta exibida |
| `usageDetails` | detalhe por modelo (painel; opcional F2) |

`AccountID(provider: .zai, key: "local")` enquanto houver uma só credencial.

### 2.5 Ingest local

Nenhum (spec §5.1: Z.ai não tem ingest local). Não há arquivo de sessão do ZCode com contagem de tokens mapeada nesta descoberta.

### 2.6 Degradação

- Sem `credentials.json`/sem `oauth:zai:access_token` → `authState: .missing`, snapshot vazio, UI sem linha Z.ai.
- Erro HTTP/transiente → mantém último snapshot com `fetchedAt` antigo; UI mostra "última atualização há Xh" (spec §5.1).

### 2.7 Riscos

- Endpoint **não documentado publicamente**; mudança de path/shape quebra a leitura → degradar.
- **Auth dual não verificada** (API key vs OAuth token) — risco nº 1 da Task 5; resolver com chamada real antes de congelar o provider.
- `unit`/`type` são códigos numéricos/strings que podem ganhar valores novos; parser tolerante descarta entrada desconhecida sem derrubar o resto.
- Região errada (global vs CN) → 404/401; detectar pelo `baseURL` do `config.json` do ZCode.

---

## 3. Gemini CLI (local only)

### 3.1 Modo

F2 = **local only** (decisão de design, spec §5.1: "sem API pública estável de quota → normalmente modo local").

### 3.2 Credencial (referência — sem uso em F2)

`~/.gemini/oauth_creds.json`: `{access_token, id_token, refresh_token, expiry_date (epoch ms), scope, token_type}`. `~/.gemini/settings.json` → `.security.auth.selectedType`. Usar read-only.

### 3.3 Sessões locais — `~/.gemini/tmp/<projeto>/chats/session-<ISO-local>.jsonl`

- `<projeto>` é o hash/nome do diretório (ex.: `dom-orca`); `logs/` e `logs.json` podem estar vazios.
- **Linha 1 (meta):**

```json
{ "kind": "main", "sessionId": "fake-session-id", "projectHash": "dom-orca",
  "startTime": "2026-07-26T18:38:00.000Z", "lastUpdated": "2026-07-26T19:00:00.000Z" }
```

Depois da meta, o arquivo **mistura dois formatos de linha** (verificado 2026-09-02 nas 4 sessões locais: `$set` = 1/2/6/5 linhas vs linhas-raiz = 0/1/5/4 — os dois formatos coexistem no mesmo arquivo):

- **Formato A — linha-raiz de mensagem** (apêndice, uma por mensagem; a única com tokens):

```json
{
  "type": "gemini",
  "id": "fake-uuid-with-dashes",
  "timestamp": "2026-07-26T18:39:59.370Z",
  "content": "resposta fake do modelo",
  "model": "gemini-2.5-flash",
  "thoughts": [ { "text": "raciocínio fake" } ],
  "toolCalls": [ { "name": "fake-tool" } ],
  "tokens": {
    "input": 100, "output": 54, "cached": 0,
    "thoughts": 39, "tool": 0, "total": 193
  }
}
```

  - `type` observado: `gemini` (com `model` + `tokens`) | `user` (`content` array, sem tokens) | `info` (nota do CLI, `content` string, sem tokens)
  - `content`: **string** nas linhas `gemini`/`info`, **array** nas `user` — irrelevante p/ ingest de tokens
  - `tokens`: `{input, output, cached, thoughts, tool, total}`; **`total = input + output + thoughts + tool`** (verificado nas 3 linhas com tokens; `cached=0` em todas — ver §3.4)
  - `toolCalls` é opcional (ausente quando não há chamada de ferramenta)
- **Formato B — delta `$set`** (espelha mensagens sem tokens; ignorar p/ contagem):

```json
{ "$set": {
    "lastUpdated": "2026-07-26T18:40:00.000Z",
    "messages": [
      { "id": "fakehexid", "timestamp": "2026-07-26T18:39:59.000Z",
        "type": "user", "content": [ { "text": "mensagem fake" } ] }
    ] } }
```

  - ids de `$set.messages` usam formato **diferente** das linhas-raiz (hex sem traços vs UUID), não colidem
- **Duplicação real observada:** a mesma mensagem (mesmo `id`, mesmos tokens, mesmo `timestamp`) pode aparecer em **duas linhas-raiz idênticas** (o CLI reanexa a mensagem ao retomar). **Dedupe por `id` é obrigatório** — cursor por byte offset sozinho conta dobrado.

### 3.4 Contagem de tokens (tokens REAIS — sem estimativa)

O ingest Gemini gera `UsageEvent` **apenas das linhas-raiz `type: "gemini"`** (as únicas com `tokens`), com dedupe por `id` (§3.3). Mapeamento recomendado:

| Campo do evento | Fonte | Justificativa |
|---|---|---|
| `inputTokens` | `tokens.input` | prompt |
| `outputTokens` | `tokens.output + tokens.thoughts + tokens.tool` | tudo que o modelo gerou; no Claude/Codex o `output_tokens` já engloba thinking/reasoning — consistência entre providers exige somar `thoughts` (aditivo a `output`: verificado `total = input+output+thoughts+tool`) e `tool` (0 nas amostras, mesmo raciocínio) |
| `cacheReadTokens` | `tokens.cached` | análogo a `cache_read` do Claude. **Caverna:** `cached=0` em todas as amostras; a hipótese "`cached` ⊆ `input`" (semântica da API Gemini) não pôde ser verificada — se um dia vier `cached>0` com `total` descontando `cached`, revisar |
| `model` | `model` da linha (ex. real observado: família `gemini-2.5-flash`) | presente nas linhas `gemini` |
| `ts` | `timestamp` da linha (ISO8601 com fração + Z) | |

- **Checksum:** `total == input + output + thoughts + tool`; divergência → aceitar os componentes (parser tolerante) e seguir, sem travar o ingest.
- **Não usar `total` sozinho**: ele mistura input e output; o `UsageEvent` precisa do split p/ analytics — os componentes dão o split e o `total` vira verificação.
- **Exibição: tokens reais, sem prefixo `≈`** — não há estimativa no caminho. Proibido reintroduzir estimativa (chars/4 etc.).
- Janelas de limite: sempre `nil` (`usedFraction: nil` → UI "local", spec §5 regra 2).

### 3.5 Mapeamento

`project` = nome do dir `~/.gemini/tmp/<projeto>` (mesma regra de projeto do F1); `ts`/`model`/tokens conforme §3.4; `account = "local"`; `provider = .gemini`. Incremental: apêndice por byte offset com `FileOffsetStore` + **set de `id`s já contados por arquivo** (linhas duplicadas são reanexos; se o arquivo encolher abaixo do cursor, re-ingest completa — padrão F1 `resetToZero`).

### 3.6 API de quota interna (FORA do escopo F2 — referência futura)

O CodexBar usa `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` (`Authorization: Bearer <access_token>`, `Content-Type: application/json`, body `{"project": "<id>"}` ou `{}`) → `{ "buckets": [ { "remainingFraction": 0.42, "resetTime": "2026-09-02T20:00:00Z", "modelId": "gemini-2.5-pro", "tokenType": "INPUT" } ] }`, com dependência de `v1internal:loadCodeAssist` para descobrir o project id. Por que não F2: API interna sem contrato, tier consumer com descontinuações (403 `SUBSCRIPTION_REQUIRED`), e o refresh do access token exige **reescrever** `oauth_creds.json` — viola a regra 1 do provider (read-only em credenciais). Se um dia entrar: usar somente token não expirado (`expiry_date` > agora), sem refresh, isolado em módulo próprio.

### 3.7 Riscos

- **Dedupe:** linhas-raiz duplicadas (mesmo `id`) são reais e observadas; sem dedupe, contagem dobra. Teste obrigatório: arquivo que cresce com reanexo de mensagem já ingerida.
- Mistura de formatos (`$set` + raiz) no mesmo arquivo, com proporção variável por versão do CLI — parser deve aceitar qualquer mistura e ignorar linhas sem `tokens`.
- `cached ⊆ input` não verificado (amostras com `cached=0`); semântica de `tool` idem (`tool=0`). Reavaliar se aparecerem valores > 0.
- Mudança de versão do CLI pode migrar os chats de lugar ou mudar o schema (`~/.gemini/history/<projeto>/` hoje só tem `.project_root` vazio — monitorar).

---

## 4. Matriz de riscos consolidada

| Fonte | O que quebra se mudar | Impacto | Mitigação |
|---|---|---|---|
| `chatgpt.com/backend-api/wham/usage` | Path/headers/shape | Sem % (Codex) | Degrada p/ local; fixture-replay isola o decoder |
| `~/.codex/auth.json` | Renomear chave/rotação de schema | Sem API p/ Codex | `.tokens.access_token` + `account_id` com fallback JWT; reader isolado (`CodexAuthReader`) |
| `~/.codex/sessions/**/*.jsonl` | Novos tipos de linha / campo movido | Subcontagem local | Parser tolerante (skip de tipo desconhecido); `last_token_usage` ≠ `total` (delta vs cumulativo) |
| `api.z.ai/api/monitor/usage/quota/limit` | Path, auth, `unit`/`type` codes | Sem % (Z.ai) | Validação de auth na Task 5; entradas desconhecidas descartadas sem quebrar |
| `~/.zcode/v2/credentials.json` | Chave renomeada / token rotacionado pelo CLI | Sem API p/ Z.ai | `.missing` → UI sem linha; retry no próximo ciclo |
| `~/.gemini/tmp/**/chats/*.jsonl` | CLI muda formato/diretório | Sem atividade Gemini | Parser tolerante; descoberta por glob `chats/session-*.jsonl` |
| Todos | Tokens vazarem em log/fixture/doc | Segurança | Regra dura: sintético sempre; revisão de QA verifica |

## 5. Regras para fixtures das Tasks 3–5

1. Fixtures 100% sintéticas: tokens `fake-token`, ids `fake-*`, timestamps/números inventados.
2. Testes de rede via `URLProtocol` stub com o JSON sintético destas seções; ingest via arquivos temporários gerados do schema documentado.
3. Casos de degradação obrigatórios por provider: credencial ausente, 401, 404/500, JSON malformado, linha desconhecida no JSONL.

## 6. Fontes consultadas (2026-09-02)

- CodexBar `main`: `Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift`, `.../CodexOAuth/CodexOAuthCredentials.swift`, `.../Zai/ZaiAPIRegion.swift`, `.../Zai/ZaiSettingsReader.swift`, `Sources/CodexBarCore/Resources/Plugins/zai.js`, `Sources/CodexBarCore/Providers/Gemini/GeminiStatusProbe.swift`
- Máquina local (jq em chaves/estrutura, sem valores): `~/.codex/auth.json`, `~/.codex/sessions/2026/{07,09}/…rollout-*.jsonl`, `~/.zcode/v2/credentials.json`, `~/.zcode/v2/config.json`, `~/.gemini/{tmp,history,state.json,projects.json,oauth_creds.json,settings.json}`

---

## 7. Emenda T8 (2026-09-03) — o que a implementação confirmou ou decidiu diferente

Registrado ao fechamento da F2 (Task 8); detalhes em `docs/decisoes-f2.md`.

1. **§2.2 auth Z.ai (validação):** implementada a ordem apiKey (`config.json`) → OAuth (`credentials.json`), no máximo 2 requests por ciclo. Na T8 o app consultou o endpoint real e recebeu dados válidos; QUAL credencial foi aceita não é distinguível sem logar credencial (proibido) — a validação isolada por tipo segue pendente, mitigada pelo fallback.
2. **§2.3/§2.4 `TIME_LIMIT` e tipos desconhecidos:** a spec admitia descartar entradas desconhecidas; a implementação exibe percentuais reais sob rótulo honesto — `TIME` com `unit=5, number=1` → label "MCP"; tipo desconhecido → `.daily` com label cru (ex.: `UNKNOWN u99`). Nunca descartar dado que a API mandou.
3. **§1.5/§3.5 cursores:** confirmado o padrão incremental F1, com obrigação dura de UM arquivo de cursores por provider (`claude/codex/gemini-cursors.json`) — compartilhar cruzaria providers no rollover.
4. **§1.7 404:** ruling F2-CODEX-404 — 404 tratado como transiente (backoff), NÃO degradação para local; desvio consciente do texto original desta spec.
5. **§3.4 checksum:** implementado como especificado (componentes vencem; `total` só verificação), com a composição do output saturante (Red Team T8, P1).
6. **Snapshot do dia (novo):** além dos cursores, cada provider com ingest persiste `<provider>-ledger.json` (estado do dia por arquivo, carimbado com o estado dos cursores) para sobreviver ao restart mid-day — ver decisões F2 nº 10.
