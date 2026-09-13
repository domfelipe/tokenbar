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
| T3 | `unknown` do codex: causa encontrada e CORRIGIDA (ver abaixo); falta re-atribuir o histórico já gravado | feito (código) / aberto (dados) |

## Achado da T3 (13/09) — o que o grupo "unknown" É

**Não é limitação do payload nem modelo não precificado**: são eventos do Codex
ingeridos SEM model, porque o model só existe em linhas `turn_context` e vive
APENAS na memória do `CodexModelTracker` (limpo na troca de arquivo, por
higiene). Uma leitura INCREMENTAL que começa depois do último `turn_context` —
app reiniciado com o cursor salvo, ou eventos anexados ao arquivo depois daquele
`turn_context` — não vê a linha e gravava o evento com `model = nil` ⇒ grupo
"unknown" no banco (no dado do dono: 307M tokens em 08/09, 44M em 10/09, 30M em
12/09, 355K em 13/09 — sempre na conta `local`).

Evidências:
1. Simulação do parser sobre os 633 arquivos de sessão: 10,4B tokens e ZERO
   `token_count` antes do primeiro `turn_context` ⇒ uma releitura completa hoje
   atribuiria model a tudo.
2. Teste de reprodução fiel (`incrementalReadSeedsModelFromFilePrefix`): duas
   leituras com tracker NOVO na segunda e um `token_count` anexado sem
   `turn_context` antes — falha com `model == nil` sem o fix e passa com ele.
3. `grep` confirma: o único ponto que cria evento no Codex
   (`CodexSessionIngester`) cria com `model: nil` e depende do stamp do tracker.

**Fix**: antes do primeiro stamp de cada arquivo, o ingester semeia o tracker com
o último `turn_context` ANTERIOR ao offset do cursor (lê só o prefixo, 1× por
arquivo por processo; offset 0 não precisa). Nenhuma mudança de schema.

**Aberto**: os ~390M de tokens já gravados continuam "unknown" — o dado antigo
não se corrige sozinho. Re-atribuir exige um passe que releia as sessões e
corrija (ou reconstrua) as linhas afetadas por dia; entra junto do re-pricing da
T1, com o mesmo cuidado de idempotência e transação.

## Contratos

- Só toca evento com `cost_usd IS NULL`: custo já calculado é IMUTÁVEL.
- Idempotente: a segunda execução encontra 0 eventos para preencher.
- `daily_agg` recebe o INCREMENTO dos custos novos — mesma semântica do upsert
  da ingestão (NULL + custo = custo; custo + custo = soma).
- Relatório honesto: eventos atualizados, custo adicionado e quantos continuam
  sem custo (sem modelo / sem preço na tabela).
- Nada disso é automático no launch: é um passe explícito, com resultado no
  stdout — o dono vê o que mudou.
