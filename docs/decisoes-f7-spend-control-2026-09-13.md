# F7 — Spend control: orçamento, projeção e alertas (2026-09-13)

Fase seguinte ao Usage & Spend: o app deixou de só medir gasto e passou a
comparar com um teto e a avisar antes de estourar. Reusa `PricingTable`
(NULL ≠ 0), `daily_agg`, `AppSettingsStore`, `AlertEngine` (F5), painel e
Analytics — sem provider novo e sem API nova.

## Contratos (decididos e cobertos por teste)

1. **Mês-CALENDÁRIO do banco, não "últimos 30 dias"**: dia 1 até HOJE, no
   calendar injetado (o mesmo do rollover do ledger), com o dia corrente
   contando como completo. `monthSpend` tem limite SUPERIOR em hoje — dia
   futuro é anomalia de relógio e não infla orçamento (difere do `dailySeries`,
   que só tem limite inferior por motivos de gráfico desde a F3).
2. **NULL ≠ 0 em TODO caminho**: mês sem nenhum evento com preço conhecido
   não gera custo, não gera projeção, não gera alerta e a UI mostra "—" —
   nunca "$0.00". Custo ZERO de verdade (evento precificado que custou 0) é
   custo: entra como 0, projeta 0 e aparece como 0%.
3. **Projeção** = `mês-corrido / dias corridos × dias do mês`, com o tamanho
   REAL do mês (`range(of: .day, in: .month)`: fev = 28/29) e saturação em
   US$ 1 bilhão (padrão Red Team). Dia 1 projeta o próprio dia.
4. **Teto efetivo** = o do provider quando existe, senão o global; sem
   nenhum dos dois não há linha nem alerta.
5. **Sanitização**: não-finito, ≤ 0 ou acima de US$ 100 mi → AUSENTE (nunca
   crash, nunca chute). Vazio = sem orçamento, que NÃO é "orçamento 0" (a
   chave é removida do banco).
6. **Alerta de orçamento tem dois tipos**: `.budget` (o gasto JÁ feito cruzou
   o threshold do teto — "X% of the monthly budget used") e
   `.budgetProjection` (a projeção de fechamento cruzou — "on pace for X% of
   the monthly budget", o aviso ANTES de estourar). Dedupe 1× por (provider,
   tipo, threshold) POR MÊS; re-arma quando a fração cai abaixo ou quando o
   mês vira; o estado vive em `alerts:state` (campo aditivo `budgets`, JSON de
   versão anterior continua decodificando).
7. **Evento de orçamento não pertence a uma conta**: usa
   `AccountID.allAccountsKey` ("*") e `WindowKind.monthly` (caso novo do
   enum) em vez de fingir ser `daily`.

## Superfícies

| Onde | O que aparece |
|---|---|
| Settings › Budget (aba nova) | teto global + um por provider; commit no Enter/saída de foco; entrada inválida reverte (não apaga o gravado) |
| Painel (dashboard do provider) | `Budget: $85.90 of $250.00 · 34% · projected $198.24` — só com teto; "—" sem preço |
| Analytics | seção "Budget" com a linha global e as por provider (fração + projeção) |
| Notificação | "X% of the monthly budget used" / "on pace for X% of the monthly budget" |

## Verificação

- **617 testes / 97 suítes verdes** (`./run-tests.sh`), com testes de núcleo
  puro (mês real, bissexto, zero à esquerda, saturação, sanitização), de
  motor (dois tipos, dedupe, re-arm por queda e por virada de mês, restart,
  master switch, teto do provider vencendo o global) e de wiring (entrega pelo
  gateway com preço real da tabela embutida; silêncio sem teto/sem custo).
- **Fim a fim no app real (13/09)**: `250` digitado na aba Budget → a tabela
  `settings` gravou `budget:monthlyUSD=250` → o painel do Codex passou a
  mostrar `Budget: $85.90 of $250.00 · 34% · projected $198.24`, com a
  projeção conferindo na mão (85,90 ÷ 13 dias × 30 = 198,23).
- Evidências: `docs/qa/evidence/panel-budget-2026-09-13.png` (painel) e
  `analytics-budget-2026-09-13.png` (janela, com 14,37/11×30 = 39,19 e
  1,76/11×30 = 4,80 conferidos).

## Lição de UI (aba nova de Settings)

Aba de `Settings` sem `.formStyle(.grouped)` renderiza no estilo *columns* e
joga a coluna de RÓTULOS para fora da janela — medido por AX: rótulos em
`x=959` num cartão que começa em `x=1045`, então a janela aparecia só com os
campos e placeholders ("o Budget está quebrado"). Fix: `.grouped` +
`LabeledContent` por linha (o campo passa a ser NOMEADO para o AX: "All
providers"/"Claude"/… em vez de só o placeholder). Toda aba nova precisa
disso.

## Achado aberto (fora do escopo desta fase)

O Claude do dono tem ~10,4M tokens no mês e **custo NULL**: os modelos que ele
usa localmente (ex.: `muse-spark-1.3`) não estão na `pricing.json`. O app se
comporta como projetado (mostra "—" em vez de inventar $0), mas o gasto do
Claude não entra no orçamento nem nos alertas. Para acompanhar falta (a)
incluir esses modelos na tabela versionada ou (b) definir fallback explícito
por provider — decisão do dono, não implementado aqui.

## Review independente (13/09) — achados e desfechos

| Achado | Severidade | Desfecho |
|---|---|---|
| Id de entrega colidia entre `.budget` e `.budgetProjection` (mesma conta "*", mesma janela, mesmo threshold → mesmo banner: um engolia o outro no mesmo ciclo) | Important | CORRIGIDO: o TIPO entra no sufixo do id, só nos tipos novos (ids de janela/lembrete seguem byte a byte — e2e e Red Team os fixam) + teste de não-colisão |
| Campo de orçamento aceitava valor acima do teto de sanidade: ou mostrava um teto inexistente, ou APAGAVA o teto gravado por typo | Minor | CORRIGIDO: sanitiza no commit e reverte o campo ao valor real |
| `Int((fração × 100).rounded())` sem guarda de finitude/overflow nos dois pontos de UI (assimetria com o caminho de alerta, que guarda `isFinite`) | Minor | CORRIGIDO: `ProviderPanelModel.budgetPercentText(_:of:)` guarda finitude, budget > 0 e teto do ratio antes da conversão; usado no painel e no Analytics |
| Nenhum teste cobria o estampo dos campos de orçamento no CICLO (apagar as linhas mantinha a suíte verde) | Minor | CORRIGIDO: teste de wiring que falha se o stamp sumir e que exige o campo de volta a `nil` sem teto |
| Teto global é "total" no Analytics e "por provider" no painel/alerta | Minor | RÓTULOS corrigidos ("All providers (sum)" + captions dizendo que o global é o teto PADRÃO por provider). Ver decisão aberta abaixo |
| Higiene: variável morta no teste e asserção fraca (`!= nil`) no custo de julho | Minor | CORRIGIDO: valor exato com tolerância |

### Decisão aberta (dono): o teto global é do TOTAL ou de CADA provider?

Hoje o valor global é o teto **padrão de cada provider** (quem tem teto próprio
vence): com três providers a 80% de um global de \$250, o alerta de estouro do
TOTAL não dispara — só a linha informativa "All providers (sum)" mostra 240%. A
alternativa é o global ser o teto do TOTAL (alertando sobre a soma). As duas
leituras são defensáveis; a segunda é provavelmente a intuição de quem digita
"Monthly budget: \$250". Não implementado — decisão do dono.

## Limites conhecidos

- Multi-moeda fora de escopo (USD, como o resto do app).
- Orçamento semanal/diário e histórico de meses fechados fora de escopo.
- O alerta olha gasto REAL e PROJEÇÃO; não há alerta "por data" ("vai
  estourar dia 22") — a data é derivável da projeção, mas não foi pedida.
