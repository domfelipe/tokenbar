# TokenBar — F4 · Decisões Técnicas

Data: 2026-09-08
Projeto: tokenbar (F4 — painel rico + pacing + multi-conta)
Complemento de `docs/decisoes-f1.md`, `decisoes-f2.md` e `decisoes-f3.md` (mesmo formato: contexto → decisão → consequência). Rulings registradas no ledger SDD durante as Tasks 1–4 e consolidadas aqui na T4.

---

## Decisão 1: F4-SCOPE — painel rico prioritário; alertas deslizam para F5

**Contexto:** o plano F4 original carregava alertas notificáveis (spec §8: thresholds + UNUserNotificationCenter); o usuário referenciou o painel do CodexBar (screenshot 2026-09-08) como prioridade.

**Decisão:** F4 entrega o painel rico (abas por provider com logo, barras de janela com countdown de reset, pacing, custos hoje/30d, chart 30d) + multi-conta (registry, "+ Add account", toggle/remove). Alertas notificáveis deslizam para F5 (junto com Cursor/OpenRouter/Copilot); status page e "Armazenamento" ficam FORA de escopo (sem fonte de dados — nada inventado).

**Consequência:** o pacing (trend §12-F5) foi antecipado como engine puro em Core; a infraestrutura que a F3 deixou (`daily_agg` com custo, `HistoryQueries`) alimenta tudo sem rede nova.

## Decisão 2: F4-LOGOS — SVGs autorais simplificados + disclaimer de trademark no README (mitigação obrigatória)

**Contexto:** o usuário pediu logos nas abas ("quero os logos"). Marcas reais são trademark dos donos; recriar logos oficiais em vetor é takedown de marca.

**Decisão:** abas com marcas VETORIAIS AUTORAIS — interpretações originais simplificadas (estilo CodexBar), bundle como SVG em `Resources/` copiado `.copy` (sem asset catalog/actool — CLT-safe) e carregado via `NSImage(contentsOf:)` (macOS 14 lê SVG). Provider sem SVG → fallback: sigla D5 sobre cor de marca própria (`brandColor`) — nunca inventa imagem. **Mitigação documentada (obrigação dura da T4):** disclaimer no README — "Provider logos are simplified original marks; trademarks belong to their owners — used for identification only, not affiliated".

**Consequência:** identidade visual honesta com risco legal mitigado (simplificação autoral + uso nominal para identificação); decode de SVG é 1×/sessão (cache no `ProviderLogo`), dentro do orçamento do painel.

## Decisão 3: F4-MULTIACCOUNT — registry + UI + conta ativa na F4; troca efetiva de credencial é F5

**Contexto:** multi-conta real exige credenciais multi-provider (Cursor/OpenRouter chegam na F5); a spec §6 já reservava a tabela `accounts`.

**Decisão:** F4 entrega o MECANISMO: tabela `accounts` como fonte da descoberta MERGE (auto-descoberta + registro, dedupe por key), formulário "+ Add account" (label + credential path + data directory opcional; leitura sempre read-only), toggle ativo/inativo e remoção. O ciclo itera a conta canônica (`local`, layout F2 preservado) + as registradas ativas. Provider sem capability `.multiAccount` (gemini) → controles ocultos. Sem DB (degradação F2) → "+ Add account" oculto (honesto: não há onde registrar).

**Consequência:** contas de Claude/Codex/Z.ai já cicliza­m de verdade na F4 (ingest por dir própria / credencial própria); a troca efetiva de credencial ativa por provider é wiring de F5, sem mudança de schema.

## Decisão 4: agregado do provider = tokens SOMADOS + janela do PIOR CASO

**Contexto:** com N contas o painel/menu precisam de UM valor por provider; mostrar média esconderia a conta mais pressionada.

**Decisão:** `aggregateAccountsDisplay`: `todayTokens` = soma entre contas; janelas/percent/resetsAt/pacing/auth/fonte = da conta com a MAIOR fração de janela crítica (pior caso visível, mesmo critério D5 do menu bar; empate vence a primeira — canônica). `fetchedAt` = o mais recente. Histórico provider-wide (7d/30d/série/custo) vem do `daily_agg`, que já soma contas por construção.

**Consequência:** com uma conta o resultado é bit-a-bit o caminho F2/F3 anterior; o menu bar nunca piora com multi-conta. O input de PACING é POR CONTA (`pacingInput` com `account =`), então o forecast reflete a conta crítica, não uma média.

## Decisão 5: cursor/hwm POR CONTA — namespaces disjuntos são o que impede colisão

**Contexto:** duas contas apontando para o mesmo arquivo (ou para raízes sobrepostas) com cursor compartilhado dobrariam o dia ou comeriam eventos uma da outra.

**Decisão:** cada conta tem store próprio: DB → `cursors:<provider>` (canônica, chave legada F2) vs `cursors:<provider>:<accountKey>` (registrada); JSON → `<provider>-cursors.json` vs `<provider>-<accountKey>-cursors.json`. Idem ledger snapshot e `hwm:<provider>[:<account>]:<path>`. Conta removida do registry perde instância/stores/seeds no ciclo (`pruneAccountCaches`); recriar é seguro (re-ingest reconstrói; hwm no DB impede re-persistência).

**Consequência:** N colisões por construção entre contas de dirs distintas; o caso patológico de DIRS SOBREPOSTAS é tratado pelo guard da Decisão 7 (não por namespace — duplicação persistente em `daily_agg` não é limpa pela remoção da conta).

## Decisão 6: migração v2 — ALTER TABLE aditivo; bancos F3 migram intactos

**Contexto:** a `accounts` do schema §6 v1 não tinha as colunas de resolução da conta.

**Decisão:** migration v2 = dois `ALTER TABLE accounts ADD COLUMN` (`credential_path`, `directory_path` TEXT NOT NULL DEFAULT ''). Nenhuma migration publicada é editada; reabrir banco é no-op (`grdb_migrations`).

**Consequência:** upgrade F3→F4 sem tocar no histórico; o registry enxerga as colunas novas e bancos novos já nascem com elas.

## Decisão 7: guard de overlap — UI bloqueia; `AccountsModel.add` revalida (defesa em profundidade); registry puro fica sem guard (residual documentado)

**Contexto:** Red Team F4 caso 5: registrar dir sobreposta à raiz canônica BYPASSANDO o formulário (chamada programática ou INSERT direto) dobraria o agregado E o histórico provider-wide de forma persistente.

**Decisão:** o formulário bloqueia overlap (`AddAccountForm.validate` — igualdade/contenção com symlinks resolvidos, vale também para dirs ainda não criadas); a camada de app (`AccountsModel.add`) REVALIDA e lança `AccountsModelError.directoryOverlaps` — qualquer chamador futuro do app herda o guard. O `AccountRegistry.add` (Core) permanece sem guard POR CONSTRUÇÃO: o registry não conhece as raízes canônicas (resolvidas no wiring do coordinator/AppState); chamá-lo direto ou escrever na tabela é fora do contrato do app — comportamento registrado: registro aceito, contagem dobrada, sem crash (P3 residual; nenhum caminho de usuário alcança).

**Consequência:** o caminho programático do E2E (INSERT via sqlite3, §10) prova exatamente esse residual — é o comportamento esperado e documentado, não um bug de produto.

## Decisão 8: só ARQUIVO REGULAR é lido como credencial (Red Team caso 4, P2 → fix)

**Contexto:** `Data(contentsOf:)` em um FIFO SEM escritor bloqueia `open()` para sempre — conta registrada com path de FIFO penduraria o fetch da conta e o ciclo do provider (`inFlight` preso). Device (/dev/null), diretório e symlink quebrado também não são credencial legível.

**Decisão:** `FileKind.isRegularFile` (Core, segue symlinks — link para `auth.json` real continua válido) guardando TODAS as leituras de credencial (`CodexAuthReader.read`, `ZaiCredentialReader.readConfig/readOAuthToken`): não-regular → `nil` → degradação normal (`.missing`/badge), zero bloqueio. O badge de path inválido (`hasInvalidPath`) e o warning do formulário usam a mesma classificação (o form avisa "not a regular file" na hora do cadastro).

**Consequência:** misconfiguration hostil degrada visível e finito; nenhuma leitura de credencial pode bloquear um ciclo. Regressão: `RedTeamF4ProviderTests` (FIFO/dir/device/dangling → nil imediato) + `RedTeamF4UITests` (form/model) + `fileKindClassification`.

## Decisão 9: pacing honesto — engine puro com regras de corte e saturação documentadas

**Contexto:** forecast inventado é pior que nenhum forecast (canon: "não sei" > chute).

**Decisão:** `PacingEngine.forecast` devolve `nil` quando: <2 pontos diários COM dados, janela sem `resetsAt`, janela sem fração conhecida, todos os pontos no mesmo dia, ou taxa ≤ 0 (flat/queda não projeta esgotamento — projetado = uso atual). Janela `.session` não projeta sobre agregados diários (granularidade incompatível) → forecast "flat" com `projectedFraction = usedFraction`. Totais negativos são corrupção e DESCARTADOS; não-finitos saturem (`projectedFraction ≤ 1e6`, `deficitPct` proporcional finito). Gaps de dias NÃO são zero-fill (inventaria "não usei") — o eixo x usa a data real de cada ponto. A linha só existe na UI com o disclaimer "estimate — not a guarantee"; o heartbeat v3 traz `pacing` como campo ADITIVO (presente ⇔ forecast existe; `exhaustedIn`/`deficitPct` null explícito).

**Consequência:** a ausência do campo é informativa (0 pontos → omitido — provado no E2E com Z.ai: fração 81% + reset, ZERO histórico → omitido; e com Codex sintético 2 dias: presente e flat). Registrado do ledger T1: a janela de regressão é 14 PONTOS com dados (não 14 dias-calendário); dia parcial entra com peso inteiro (viés otimista de manhã); o parse de day string ainda aceita "-2026-..." (porta fechável; o input hostil do DB é descartado adiante pelo engine); "assinatura exata" do report T1 era overstatement (tuple vs dict). Registrado do Red Team T4 (caso 1): `pacingInput` é cru por contrato — day strings não-ISO ("garbage", "-2026-...") são descartadas na query, mas ISO leniente ("2026-13-99") ROLA para data real (leniência do Calendar do Foundation) e agregado NEGATIVO atravessa a query; a defesa é do engine (negativos descartados, tudo satura finito) — camadas documentadas e pinadas em `RedTeamF4Tests`.

## Minors e pendências registradas (triagem F4)

- **Ticker do countdown re-ancora a cada render do pai** (T2): `Timer.publish` é recriado quando o pai re-renderiza — a fase do countdown re-âncora; `@State` estabilizaria. Sem efeito de corretude (sempre mostra delta correto) e a prova de 10 min do QA (footprint estável) cobre o orçamento.
- **`todayCostUSD` síncrono na main** (herdado do F3, registrado como obrigação da T2): a query do custo do dia roda na MainActor no caminho do analytics; o ciclo do painel usa `Task.detached` (fora da main). Candidato a mover na F5.
- **E2E flake de timing pós-suíte pesada** (1× na T3; 2× na T4 no re-run do 3º launch, runs 4/5): esperas por conteúdo de live-update eram justas sob load — estendidas para 25s e as esperas de RELAUNCH para 120s com diagnóstico periódico no log. Run 6 de gate publicou o 3º launch em <9s (diagnóstico no log): o stall de 60–90s dos runs anteriores é intermitente e ambiental (agendamento sob load), não do produto — mesmo padrão da Decisão 7 do `decisoes-f3.md` (re-run é o tratamento; o assert permanece).
- **Heartbeat não expõe breakdown por conta** (design): o payload v3 continua por provider (aditivo F4: `monthTokens`/`monthCostUsd`/`pacing`). Diagnóstico por conta fica para quando houver necessidade real — a higiene (nenhum path/id de conta no payload) é provada no E2E §10 e em unidade.
- **`AddAccountView` `try?` + `onClose` incondicional** (T3): se o add lançar (ex.: overlap por corrida), a janela fecha sem criar e sem mensagem dedicada — o form valida antes, o residual é a corrida; registrado.
- **`normalized()` não expande `~` manualmente** (T3): `resolvingSymlinksInPath` variante String indisponível no toolchain; `~` literal não colide — form usa paths de NSOpenPanel/absolutos.

## Evidências da T4 (gates finais)

- Suíte: **395 testes / 56 suítes verdes** (`./run-tests.sh`) — 377 base F4 (T1–T3) + 18 regressões Red Team F4 (detalhamento no `f4-redteam-report.md`).
- E2E v4: **62 checks PASS, exit 0** (39 herdados F3 + 23 novos F4; log integral em `docs/qa/evidence/e2e-f4-2026-09-08.log`).
- Red Team runtime: log integral em `docs/qa/evidence/f4-redteam-runtime.log`; QA manual (AX + screenshots + ticker 10 min) em `docs/qa/f4-qa-report.md`.
