# F5 — Providers extras (paridade CodexBar): endpoints e fontes

Tasks 4–5 do plano `docs/plans/2026-09-09-f5-codexbar-parity.md`. Todos os
endpoints foram PORTADOS da referência MIT (CodexBar, `steipete/CodexBar`,
commit auditado em `git log` do clone de estudo; repositório:
https://github.com/steipete/CodexBar). O PATH DA FONTE de cada provider está
citado no doc comment do módulo Swift correspondente e na tabela abaixo.

**Regra de ouro aplicada**: endpoint não portável com confiança → modo local/
omitido com motivo documentado (nunca endpoint chutado, nunca payload
inventado). Fixtures de teste 100% sintéticas (`fake-*`).

## Visão geral

| Provider | `ProviderID` | Sigla D5 | Modo | Credencial | Multi-conta |
|---|---|---|---|---|---|
| Cursor | `.cursor` | `U` | api | sessão do app Cursor (`state.vscdb`) ou arquivo registrado | sim (arquivos) |
| OpenRouter | `.openrouter` | `O` | api | API key (env ou arquivo da conta registrada) | sim (1 key = 1 conta) |
| Qwen/Alibaba | `.alibaba` | `Q` | api | API key do Coding Plan (env ou arquivo) | sim (arquivos) |
| Antigravity | `.antigravity` | `V` | api | `oauth_creds.json` (`.codexbar`/arquivo registrado) | sim (arquivos) |
| DeepSeek | `.deepseek` | `D` | api | API key (env ou arquivo) | sim (arquivos) |
| Grok | `.grok` | `K` | api | `~/.grok/auth.json` ou arquivo registrado | sim (arquivos) |

Nenhum dos 6 tem ingest local mapeada na referência (`.localIngest` ausente);
todos degradam local-first: credencial ausente → `discoverAccounts() == []`
(some da barra); auth inválida (401/403) → snapshot vazio `authState:
.invalid`; erro de rede/HTTP → rethrow (backoff do AdaptiveScheduler, spec §5
regra 3).

Siglas (ruling F5-SIGLAS): G já é Gemini e A já está reservado pela ordem
alfabética — tabela estendida documentada em `docs/decisoes-f5.md` (T7).

## Cursor

- **Fonte MIT**: `Sources/CodexBarCore/Providers/Cursor/CursorStatusProbe.swift`
  (endpoint + parse de `CursorUsageSummary`) e `CursorAppAuth.swift`
  (credencial no SQLite do app).
- **Credencial**: `cursorAuth/accessToken` de
  `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
  (`ItemTable`, leitura SQLite READONLY; mesma máquina da referência). Conta
  registrada: arquivo com o cookie header cru
  (`WorkosCursorSessionToken=<userID>%3A%3A<JWT>`) OU o access token JWT cru —
  o cookie é construído do claim `sub` (último segmento após `|`, alfabeto
  restrito `[A-Za-z0-9._-]`). Sessão com `exp` vencido +60 s → sem credencial
  (`isUsable` da referência).
  *Nota*: o brief mencionava `~/.cursor`; a referência NÃO lê `~/.cursor` — o
  token útil vive no banco do app (caminho acima). Nada em `~/.cursor` foi
  inventado.
- **Endpoint**: `GET https://cursor.com/api/usage-summary` com header `Cookie`
  (não é Bearer). Override: env `TOKENBAR_CURSOR_API`.
- **Payload** (campos consumidos): `billingCycleEnd` (ISO8601),
  `membershipType`, `individualUsage.plan.{totalPercentUsed, autoPercentUsed,
  apiPercentUsed, used, limit}` (valores monetários em CENTAVOS),
  `individualUsage.onDemand.{used,limit}`, `individualUsage.overall.*`,
  `teamUsage.pooled.*`.
- **Mapeamento**: percent do plano pela MESMA cadeia de precedência da
  referência (`totalPercentUsed` → média auto+api → lane única → razão
  plan → razão overall → razão pooled); janela `Plano` (`.weekly`,
  `resetsAt = billingCycleEnd`) + janela `On-demand` quando há limit > 0.
- **Não portado** (motivo): `POST /api/dashboard/get-sand-usage-status` e
  `GET /api/usage?user=ID` (planos legados por request) — endpoints extras da
  UI da referência; não alimentam a janela principal e o legado exige
  `/api/auth/me` primeiro. Sem perda de percent principal.

## OpenRouter

- **Fonte MIT**: `Sources/CodexBarCore/Providers/OpenRouter/{OpenRouterProviderDescriptor,OpenRouterSettingsReader}.swift`
  + plugin `Sources/CodexBarCore/Resources/Plugins/openrouter.js` (endpoints e
  lógica de quota `keyUsedForQuota`).
- **Credencial**: API key — env `OPENROUTER_API_KEY` (auto, como a
  referência) ou arquivo cru da conta registrada (entrada manual da UI
  multi-conta F4). `.multiAccount` real: 1 key = 1 conta.
- **Endpoints** (base `https://openrouter.ai/api/v1`; override env
  `TOKENBAR_OPENROUTER_API` → `OPENROUTER_API_URL`):
  - `GET /credits` → `{ data: { total_credits, total_usage } }`; saldo =
    max(0, total_credits − total_usage) → `credits`.
  - `GET /key` → `{ data: { limit, limit_remaining, usage, usage_daily,
    usage_weekly, usage_monthly, limit_reset } }`; uso preferindo
    `limit_remaining` (uso = limit − clamp(remaining, 0, limit)), senão o
    `usage_*` da janela declarada em `limit_reset`, senão `usage` cumulativo;
    fração = uso/limit quando limit > 0. **Degradação soft**: falha do `/key`
    NÃO derruba o snapshot (janela omitida) — igual à referência.
- **Não portado** (motivo): `GET /activity` (30 dias de spend) — exige
  MANAGEMENT API key separada + agregação/dedupe de até 20k linhas; escopo do
  T6 se houver demanda.

## Qwen / Alibaba (Coding Plan)

- **Fonte MIT**: `Sources/CodexBarCore/Providers/Alibaba/{AlibabaCodingPlanUsageFetcher,AlibabaCodingPlanAPIRegion,AlibabaCodingPlanUsageSnapshot,AlibabaCodingPlanSettingsReader}.swift`.
- **Credencial**: API key do Coding Plan — env `ALIBABA_CODING_PLAN_API_KEY` →
  `ALIBABA_QWEN_API_KEY` → `DASHSCOPE_API_KEY` (ordem da referência) ou
  arquivo da conta registrada. `~/.qwen` NÃO é lido pela referência (nada
  inventado); quem tem o CLI do Qwen pode registrar o arquivo com a key.
- **Endpoint (modo API key)**: `POST
  {gateway}/data/api.json?action=zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2&product=broadscope-bailian&api=queryCodingPlanInstanceInfoV2&currentRegionId=<região>`
  — gateway `https://modelstudio.console.alibabacloud.com` (intl,
  `currentRegionId=ap-southeast-1`) ou `https://bailian.console.aliyun.com`
  (cn, `cn-beijing`); corpo JSON
  `{"queryCodingPlanInstanceInfoRequest":{"commodityCode":"sfm_codingplan_public_intl"|"sfm_codingplan_public_cn"}}`;
  headers `Authorization: Bearer` + `x-api-key` + `X-DashScope-API-Key`
  (mesma key nos três, como a referência) + `Origin` (gateway da região) e
  `Referer` (dashboard da região — `dashboardURL` da referência; carry-forward
  T7: omitidos no port inicial, portados agora). Fallback de região: intl → cn
  (1 retry por ciclo, como `shouldRetryOnAlternateRegion` da referência).
  Override: env `TOKENBAR_ALIBABA_REGION=cn`.
- **Payload** (busca recursiva por `codingPlanQuotaInfo`/
  `coding_plan_quota_info`, com aliases snake; instância ativa em
  `codingPlanInstanceInfos` quando houver mais de uma): `per5Hour*Quota`
  (aliases `perFiveHour*`), `perWeek*Quota`, `perBillMonth*Quota` (aliases
  `perMonth*`), `*QuotaNextRefreshTime` (epoch s/ms ou data OneConsole) e
  `planName`.
- **Mapeamento**: 5h → `.session "5h"`; semana → `.weekly "Semanal"`; mês →
  `.weekly "Mensal"`; fração = used/total (total ≤ 0 → sem janela).
- **Não portado** (motivo): modo cookie/SEC token do console Aliyun
  (`resolveConsoleSECToken`, `queryCodingPlanConsoleRequestBody`,
  `x-xsrf-token`) — acoplado à sessão web do console (extração de cookies de
  browser + token CSRF); TokenBar é read-only e não implementa importação de
  cookies de browser.

## Antigravity

- **Fonte MIT**: `Sources/CodexBarCore/Providers/Antigravity/{AntigravityRemoteUsageFetcher,AntigravityOAuthCredentialsStore}.swift`.
- **Credencial**: `oauth_creds.json` (shape da referência: `access_token`/
  `accessToken`, `project_id` opcional, `expiry_date`) em
  `~/.codexbar/antigravity/oauth_creds.json` (auto, mesmo caminho da
  referência) ou arquivo registrado. Override: env `TOKENBAR_ANTIGRAVITY_CREDS`.
  Token vencido → `.invalid` sem request (não há refresh: exigiria
  `client_id`/`client_secret` do OAuth do app — a referência os extrai do
  binário do IDE ou pede env dedicada).
  *Nota*: o brief mencionava `~/.gemini/antigravity-*`; a referência NÃO lê
  esse caminho — nada inventado.
- **Endpoint**: `POST
  https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels` com
  Bearer, corpo `{}` ou `{"project": <project_id>}` (read-only; a referência
  usa os mesmos headers `Content-Type: application/json`, `User-Agent:
  antigravity`).
- **Payload**: `{ models: { <modelId>: { displayName?, label?, quotaInfo: {
  remainingFraction, resetTime } } } }` → uma janela por modelo com
  `remainingFraction` presente: fração = 1 − remainingFraction, label =
  `displayName` → `label` → `modelId`, `resetsAt` = ISO8601 `resetTime`,
  `.daily` (referência agrega por modelo; o menu mostra a pior via
  `criticalWindow`).
- **Não portado** (motivo): `onboardUser` (MUTANTE — TokenBar é read-only),
  `loadCodeAssist` (só needed para descobrir project id, que o arquivo de
  credenciais já traz) e o fluxo OAuth completo (login browser com client do
  IDE).

## DeepSeek

- **Fonte MIT**: `Sources/CodexBarCore/Providers/DeepSeek/{DeepSeekUsageFetcher,DeepSeekProviderDescriptor}.swift`.
- **Credencial**: API key da plataforma — arquivo da conta registrada (entrada
  manual) ou env `DEEPSEEK_API_KEY`.
- **Endpoint**: `GET https://api.deepseek.com/user/balance` com Bearer (API
  pública documentada da DeepSeek; override env `TOKENBAR_DEEPSEEK_API`).
- **Payload**: `{ is_available, balance_infos: [{ currency, total_balance,
  granted_balance, topped_up_balance }] }` → `credits = CreditsInfo(remaining:
  total_balance)`; sem janela de uso (a API de saldo não devolve quota).
- **Honestidade no menu bar**: sem percent e sem tokens, o provider NÃO
  aparece no texto do menu (`hasData` falso) até a UI de credits existir (T6
  investiga "credits" para Codex; DeepSeek entra no mesmo slot). O snapshot
  carrega o saldo real — nada inventado.
- **Não portado** (motivo): `platform.deepseek.com/api/v0/usage/{amount,cost}`
  e `users/get_user_summary` — exigem PLATFORM TOKEN separado da API key e a
  referência os trata como opcionais com state próprio de join/retry.

## Grok

- **Fonte MIT**: `Sources/CodexBarCore/Providers/Grok/{GrokCreditsProxyFetcher,GrokAuth}.swift`.
- **Credencial**: `~/.grok/auth.json` (mesmo arquivo do Grok CLI; mapa por
  scope URL — preferência OIDC prefixado `https://auth.x.ai::`, fallback
  `https://accounts.x.ai/sign-in`; entrada usada: `key`, `expires_at`) — env
  `GROK_HOME`/`TOKENBAR_GROK_AUTH` para override. Conta registrada: arquivo
  com o mesmo shape OU token cru.
- **Endpoint**: `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
  com `Authorization: Bearer <key>` + `x-xai-token-auth: xai-grok-cli` (proxy
  do CLI é o caminho suportado — a referência documenta que o gRPC-web de
  grok.com passou a exigir keypair do browser). Token vencido → `.invalid`
  sem request.
- **Payload**: `{ config: { creditUsagePercent?, currentPeriod: { end },
  billingPeriodEnd?, onDemandCap: { val }?, onDemandUsed: { val }?,
  subscriptionTier }, subscriptionTier }` → percent = `creditUsagePercent`
  ou `onDemandUsed/onDemandCap×100`; `resetsAt` = `currentPeriod.end` →
  `billingPeriodEnd` (ISO8601); janela `.weekly` label `Plano`.
- **Não portado** (motivo): gRPC-web
  `grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig` (parse protobuf heurístico
  de campos fixed32 — acoplado ao wire format do grok.com, marcado na
  referência como quebrado sem WKE keypair do browser) e o scanner de sessões
  locais do CLI (não há transcript com contagem mapeada).

## Codex — credits (veredito da investigação, F5 Task 6)

Pergunta do plano: o `wham/usage` traz "reset credits / credits balance"
utilizável para a linha "Limit reset credits" do painel (padrão da
referência)? Investigação contra as fixtures existentes (spec §1.3/F2), este
doc e a fonte MIT (`CodexOAuthUsageFetcher`/`UsageStore+CodexResetCredits`/
`MenuCardView+CodexResetCredits`):

1. **`wham/usage` NÃO traz o inventário "Limit Reset Credits".** A seção da
   referência (título "Limit Reset Credits", texto "N available" + "Expires
   in…", e a notificação de expiração) é alimentada por
   `CodexRateLimitResetCreditsSnapshot`, vindo do endpoint DEDICADO
   `GET /wham/rate-limit-reset-credits` (header extra `OpenAI-Beta: codex-1`,
   payload `{credits: [{id, status, expires_at, …}]}`) — registrado como fora
   de escopo desde a F2 (`docs/specs/f2-data-sources.md`). O `wham/usage`
   apenas tem o objeto `credits: {has_credits, unlimited, balance}`.
2. **`credits.balance` é utilizável quando não nulo** — e nosso decoder F2 já
   o mapeia para `UsageSnapshot.credits` (F5 T6: agora chega ao painel). Em
   payloads observados de contas Plus/Pro o `balance` é `null`
   (`has_credits: false`) — a linha então NÃO aparece (omitir ≠ inventar).

**Decisão (sem invenção):** painel ganha a linha "Credits: $X.XX" (ou
"Credits: unlimited") SOMENTE com saldo real do snapshot — nunca sob o título
"Limit reset credits", cuja semântica na referência é o inventário de grants
expiráveis de OUTRO endpoint. O endpoint de reset credits fica registrado
como exercício futuro (mesmo critério dos demais "não portados").

## Contratos comuns (todas as 6)

- Uma tentativa por endpoint por ciclo — sem retry interno (backoff é do
  AdaptiveScheduler; spec §5 regra 3).
- 401/403 → `UsageHTTPError.unauthorized` → snapshot degradado vazio com
  `authState: .invalid` (badge na barra; nunca mensagem com credencial).
- Erro de rede, HTTP != 2xx/401/403 ou payload violando o contrato → rethrow
  (último snapshot bom permanece; nunca dado errado).
- Credenciais nunca logadas (spec §9) — readers sem print/log.
- Guard Red Team F4 em todo leitor de arquivo: só REGULAR file é lido (FIFO
  travaria o ciclo).
- Fixtures sintéticas `fake-*`; URL base overridável por env para e2e
  (`TOKENBAR_<PROVIDER>_API` quando aplicável).
