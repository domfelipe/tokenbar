# TokenBar — F5 · Decisões Técnicas

Data: 2026-09-10
Projeto: tokenbar (F5 — paridade CodexBar: painel 1:1, alertas, Settings, 6 providers extras)
Complemento de `docs/decisoes-f1.md` a `decisoes-f4.md` (mesmo formato: contexto → decisão → consequência). Rulings registradas no ledger SDD durante as Tasks 1–5 e resolvidas nas Tasks 6–7 (polish, credits, gates).

---

## Decisão 1: F5-SCOPE — paridade com a referência, 6 providers extras; ~50 viram contribuição

**Contexto:** o pedido do usuário — "idêntico ao CodexBar" e "vamos terminar" — contra a referência MIT (`steipete/CodexBar`) que mantém ~50 providers.

**Decisão:** F5 entrega (1) painel portado 1:1 do design da referência, (2) alertas + Settings ⌘, (spec §8), (3) SEIS providers extras portados da referência com endpoints citados (`docs/specs/f5-providers.md`): Cursor, OpenRouter, Qwen/Alibaba, Antigravity, DeepSeek, Grok — 10 no total. Os ~50 demais ficam como exercício de contribuição (o protocolo §5 é o guia). "Copilot se instalado" (§12 original) desliza para contribuição. Trend (§12-F5) já fora entregue na F4 (PacingEngine).

**Consequência:** escopo fechado sem promessa aberta de paridade total; cada provider novo segue o contrato de fixture-replay + degradação isolada (provider quebrado não afeta os demais).

## Decisão 2: F5-DESIGN — painel portado 1:1 da referência MIT (supersede F4-LOGOS-autoral)

**Contexto:** a F4 entregou logos autorais simplificados (Decisão 2 do `decisoes-f4.md`); o usuário reiterou: "quero o frontend, o design idêntico".

**Decisão:** o painel é um PORT do design system da referência (views, cores, métricas, SVGs dos logos `ProviderIcon-*.svg`) com atribuição em `NOTICE` (MIT preserva copyright; o repo segue MIT com NOTICE separado). Fallback de sigla D5 permanece para provider sem ícone na referência (cursor=U etc. — Decisão 3). Gate visual: `panelrender` (ImageRenderer sobre as views REAIS com dados de lab) composto lado a lado com o screenshot da referência; evidência em `docs/qa/evidence/`.

**Consequência:** supersede explícita da F4-LOGOS-autoral; o disclaimer de trademark permanece no README (uso nominal para identificação). Divergências conscientes registradas: strings EN (constraint global), badge de fonte no lugar do badge de plano (não temos dado de plano — nada inventado), seções sem dado são omitidas (a referência as desenha sempre).

## Decisão 3: F5-SIGLAS — tabela D5 estendida (grok≠G, deepseek≠D colisão evitada)

**Contexto:** a ordem alfabética dos novos ids colide com siglas já usadas (G é Gemini; A conflita com a ordem alfabética dos demais).

**Decisão:** tabela estendida em `MenuBarContent.siglas`: `cursor=U, openrouter=O, alibaba=Q, antigravity=V, deepseek=D, grok=K`. Providers fora da tabela continuam caindo na inicial do rawValue.

**Consequência:** menu bar sem ambiguidade (G continua sendo Gemini); a ordem de exibição permanece C, X, G, Z primeiro e demais ids em ordem alfabética atrás.

## Decisão 4: F5-NOTIF — permissão de notificação pedida SÓ no toggle da Settings

**Contexto:** pedir permissão no launch (a) assusta na 1ª execução e (b) torna o app não-testável (o runner não tem app bancarizado nem bundle id para UNUserNotificationCenter).

**Decisão:** `requestAuthorization()` é chamado EXPLICITAMENTE só quando o usuário liga o toggle de alertas na janela de Settings — nunca no launch, nunca no init do coordinator. O gateway é abstrato (`NotificationSending`): o app usa `UserNotificationGateway` real criado LAZY; testes injetam fake; o E2E usa o `E2EAlertCaptureGateway` (`TOKENBAR_E2E_ALERTS_CAPTURE`), que grava cada `AlertEvent` como linha JSON com o MESMO render EN e identificador de dedupe do gateway real. Sem permissão → estado honesto no rodapé do painel ("Notifications blocked — allow in System Settings").

**Consequência:** zero UNUserNotificationCenter em teste/e2e (ruling verificável por construção); o e2e prova disparo/dedupe reais plantando `alerts:enabled` no banco (substitute do toggle) — ver `scripts/e2e.sh` §2.5/§5/§7.7.

## Decisão 5: alert storm e flip `resetsAt` são CONTRATO, não bug (sem histerese)

**Contexto:** Red Team T7 — fração oscilando 94↔96 com threshold 95 re-dispara a cada cruzamento; flip `resetsAt` nil↔data re-dispara por renovação.

**Decisão:** manter a semântica da spec §8 (dispara 1× por cruzamento até cair abaixo ou renovar) — SEM histerese. O rate é estruturalmente limitado: 1 evento por avaliação por (provider, conta, janela, threshold), e o identificador de notificação substitui o banner da mesma causa em vez de empilhar. Oscilação lenta (ciclos de 60 s) → no máximo 1 notificação por ciclo e por causa. Pinos em `RedTeamF5AlertTests` (22 disparos em 21 cruzamentos, nunca 2 por avaliação; restart não re-dispara).

**Consequência:** comportamento documentado e limitado; histerese (zona morta) seria invenção de política não pedida — se um dia for desejada, é mudança de contrato com teste próprio.

## Decisão 6: credits do Codex — saldo real entra, inventário "Limit Reset Credits" fica fora

**Contexto:** T6 mandava investigar se o `wham/usage` traz "reset credits/credits balance" utilizável para a linha "Limit reset credits" da referência; sem dado → documentar e pular (sem invenção).

**Decisão:** investigação contra fixtures (spec §1.3), `f5-providers.md` e a fonte MIT (`CodexOAuthUsageFetcher`/`UsageStore+CodexResetCredits`): (a) o inventário "Limit Reset Credits" da referência (grants expiráveis, "N available · Expires in…") vem do endpoint DEDICADO `GET /wham/rate-limit-reset-credits` (header `OpenAI-Beta: codex-1`) — NÃO existe no `wham/usage` → fora do escopo, registrado como não-portado; (b) o `wham/usage` traz `credits: {has_credits, unlimited, balance}` — o saldo é utilizável quando não nulo e JÁ era decodificado desde a F2. F5 T6 plumbou o dado até a UI: linha "Credits: $X.XX" (ou "Credits: unlimited") no painel + campo `credits` no heartbeat, SOMENTE com saldo real (balance null nos planos Plus/Pro observados → linha e chave omitidas). A linha NUNCA usa o título "Limit reset credits" — semântica diferente (saldo ≠ inventário de grants).

**Consequência:** honestidade preservada nos dois sentidos; documentação completa em `docs/specs/f5-providers.md` § Codex.

## Decisão 7: `visibleProvidersTouched` — providers novos nascem VISÍVEIS para quem nunca editou a lista

**Contexto:** carry-forward do review T4/T5 — a lista de visibilidade era persistida como conjunto completo da época; um banco F4 (4 providers) escondia os 6 novos para sempre, mesmo sem escolha do usuário.

**Decisão:** migração de 1 flag em `AppSettingsStore`: `menubar:visibleProvidersTouched`. `loadVisibleProviders()` sem a flag → default (TODOS os providers conhecidos HOJE); com a flag → o conjunto persistido manda (ids desconhecidos ignorados; vazio é escolha válida). `saveVisibleProviders` grava a flag — a partir da 1ª edição, novos providers nascem escondidos (o checkbox da Settings é o caminho).

**Consequência:** upgrade F4→F5 transparente (novos providers aparecem); a escolha explícita do usuário sempre vence. Testes: `AppSettingsTests` (legado sem flag → superset dos 6; flag presente → lista mandatória; lixo + flag → default).

## Decisão 8: bypass programático de overlap é defendido NO CICLO (fecha residual do F4)

**Contexto:** o guard de overlap vive na UI (form/AccountsModel) e o Red Team F4 caso 5 documentou a dobragem de um registro programático com dir sobre a raiz canônica como residual aceito.

**Decisão:** o ciclo do `ProviderCoordinator` agora defende: conta registrada cujo `directoryPath` é igual, descendente OU ancestral da raiz canônica de scan do provider NÃO ingere local (o canônico já cobre aqueles arquivos — sem dobragem). A linha da conta permanece no painel (união registry ⊕ ciclo) para remoção. Contas irmãs FORA da raiz canônica continuam ciclando normalmente. `ProviderCoordinator.overlapsCanonical` compara paths padronizados com fronteira de componente (`/a/b` não cobre `/a/bc`).

**Consequência:** supersede PARCIAL da Decisão 7 do `decisoes-f4.md` — o caso "dir == raiz canônica" deixa de dobrar; a dobragem entre contas IRMÃS com a MESMA dir (também documentada no F4) permanece aceita para registro programático (o form bloqueia; o ciclo não adivinha intenção entre contas legítimas de dirs distintas). Testes: `RedTeamF5UITests` (matriz de overlap + ciclo com INSERT de conta sobreposta → 1× contado, estável no 2º ciclo).

## Decisão 9: menores de review resolvidos na T6/T7 (cosmético e higiene)

- **Ordem das linhas de ação** (review T1): `+ Add account…` primeiro, depois `Usage dashboard`, depois `Export` — ordem do screenshot da referência, conferida no render de evidência.
- **`topModel7d` pin explícito no gate** (review T1): o lab do `panelrender` passa a linha pelo init do `ProviderDisplay` (estado declarado, não mutação pós-init).
- **Capitalização "Updated"** (review T1): conferida contra `UsageFormatter.updatedString` do upstream MIT — TODOS os ramos usam "Updated" com U maiúsculo (`Updated just now` / `Updated 42m ago` / `Updated 3h ago` / `Updated Sep 8`); ajustado e pinado em teste. "not updated yet" permanece extensão nossa (o upstream não tem esse caso).
- **Headers Origin/Referer do Alibaba** (review T4/T5): portados do `AlibabaCodingPlanUsageFetcher` — `Origin` = gateway da região, `Referer` = `dashboardURL` da região (URLs bit-a-bit da referência); contrato pinado em teste.
- **2 keys OpenRouter simultâneas** (review T4/T5): `OpenRouterMultiKeyTests` — 2 contas registradas, instância por key, descoberta merge, saldos/janelas ISOLADOS e Bearer de cada request atribuído à própria key.
- **Doc comment stale "4 providers"** (review T4/T5): `ProviderCoordinatorTests` atualizado para os 10 providers do wiring.
- **Typos** (review T4/T5): `docs/specs/f5-providers.md` ("cruo"→"cru", "end extras"→"endpoints extras") e `ProviderPanelModel` ("etá"→"eta").
- **Thresholds fora de ordem em banco tamperado** (review T3): Red Team explícito — `[95,50]` persistido → sanitizado para `[50,95]` no init E no `readConfig`; JSON lixo em `alerts:*`/`scheduler:*` → defaults campo a campo (`RedTeamF5SettingsTamperTests`).

## Decisão 10: menores aceitos (documentados, sem fix nesta fase)

- **Aviso de launch-at-login "stale"**: se o usuário aprovar/negar direto no System Settings, o aviso na janela só se atualiza ao reabri-la (`refreshLoginStatus` no appear) — leitura do estado real do serviço, sem polling.
- **Slider grava SQLite a cada passo**: cada mudança de slider persiste imediatamente (idempotente, tabela `settings`, escrita de poucos bytes). Debounce seria polimento de I/O sem sintoma observado.
- **Saldo negativo do DeepSeek** (hostil): `total_balance` negativo da API passa sem clamp (OpenRouter faz `max(0, …)`; DeepSeek não). O valor exibido é o que a API disse — o caso é hostile-fuzz documentado; clamp seria política sem base na referência.
