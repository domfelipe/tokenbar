# F8 — Dados de custo completos (2026-09-13)

Motivo (achado no dado real do dono): o MAIOR volume dele está sem custo —
`codex/gpt-6-astra` (635M tokens), `codex/unknown` (390M),
`claude/muse-spark-1.3` (8,1M) e `claude/glm53flash` (2,3M). A UI mostra "—"
(NULL ≠ 0, como projetado), mas orçamento e alertas ficam cegos para a maior
parte do gasto.

## Três causas distintas (não confundir)

1. **O modelo passou a ter preço DEPOIS** (astra, muse-spark): a tabela é
   versionada e o custo é calculado NA INGESTÃO — o que ficou NULL não é
   recalculado (decisão "não retroativo"). Exige um passe EXPLÍCITO.
2. **Evento sem nome de modelo** (`unknown`, 390M): o provider não informa o
   modelo e nenhum preço por modelo alcança esse grupo. Decisão do dono
   (preço-fallback por provider) ou investigação do parse do codex.
3. **Promo deliberadamente fora da tabela** (`glm53flash`): a nota 5 da própria
   tabela exclui promo com vencimento imediato — nada a fazer.

## Tasks

| # | Entrega | Estado |
|---|---|---|
| T1 | `AppDatabase.repriceMissingCosts(pricing:)` — preenche `usage_events.cost_usd` NULL com a tabela ATUAL, ajusta os grupos de `daily_agg` afetados na MESMA transação, idempotente, nunca inventa (evento sem modelo continua NULL) | a fazer |
| T2 | Superfície: subcomando `tokenbar reprice` (mesmo padrão de `history`/`selfcheck`) imprimindo o relatório | a fazer |
| T3 | `unknown` do codex: descobrir de onde vem usage sem modelo; se for limite do payload, decidir com o dono sobre preço-fallback por provider | a fazer |

## Contratos

- Só toca evento com `cost_usd IS NULL`: custo já calculado é IMUTÁVEL.
- Idempotente: a segunda execução encontra 0 eventos para preencher.
- `daily_agg` recebe o INCREMENTO dos custos novos — mesma semântica do upsert
  da ingestão (NULL + custo = custo; custo + custo = soma).
- Relatório honesto: eventos atualizados, custo adicionado e quantos continuam
  sem custo (sem modelo / sem preço na tabela).
- Nada disso é automático no launch: é um passe explícito, com resultado no
  stdout — o dono vê o que mudou.
