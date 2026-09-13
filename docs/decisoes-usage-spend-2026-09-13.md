# Usage & Spend — ledger diário + heatmap de custo (2026-09-13)

Feature pedida pelo dono ("além de igualar o design, qual funcionalidade
melhor que o CodexBar?" → **Usage & Spend**), na linha do *Usage & Spend* +
*Daily Statistic* da referência MIT. Escopo em **USD** (mesma semântica
NULL ≠ 0 do `PricingTable` versionado); multi-moeda não foi pedido.

## O que entrou

| Peça | Onde |
|---|---|
| `WindowDay` + `windowDays(days:now:)` | `Sources/TokenBarCore/Persistence/HistoryQueries.swift` |
| `LedgerRow` + `ledgerRows(from:)` | `Sources/TokenBarUI/AnalyticsModel.swift` |
| `HeatmapCell` + `heatmapCells(from:window:)` | `Sources/TokenBarUI/AnalyticsModel.swift` |
| Seções "Usage & spend" e "Daily cost heatmap" | `Sources/TokenBarUI/AnalyticsView.swift` |
| Harness `panelrender --analytics <png>` (banco sintético de 30 dias) | `Sources/panelrender/PanelRenderMain.swift` |
| Evidência | `docs/qa/evidence/usage-spend-30d.png` |

## Decisões (e por quê)

1. **Custo NULL ≠ 0, e a distinção é VISÍVEL.** Dia em que nenhum provider
   tinha preço computável sai como "—"; zero REAL sai como "~$0.00"; dia sem
   evento não entra no ledger, mas ocupa célula vazia no heatmap. Mesma regra
   do `dayCosts`, agora preservando o dia em vez de omiti-lo do chart.
2. **A coluna da semana vem do calendar do BANCO** (`WindowDay.weekday`), não
   do `Calendar.current` da view: as datas das células são 00:00 nesse
   calendar, e recalcular num fuso a oeste (America/Sao_Paulo) jogaria o dia
   para a coluna anterior. Grade Mon..Sun (1 = segunda … 7 = domingo).
3. **A janela do heatmap é a MESMA do `WHERE day >= ?`**: `windowDays` reusa
   `windowStartDate`, então grade e `dailySeries` concordam por construção
   (teste: primeiro dia da grade == primeiro dia da série).
4. **`AnalyticsView` mudou de módulo** (`Sources/tokenbar/` →
   `Sources/TokenBarUI/`), partida em `AnalyticsContent` (miolo, SEM
   ScrollView) + `AnalyticsView` (ScrollView + `.task`/`.onDisappear`).
   Motivo: o harness de QA só enxerga o módulo de UI e o `ImageRenderer` não
   compõe ScrollView (limitação conhecida desde o QA F4). Sem essa mudança a
   janela ficaria sem evidência por pixels — e não há captura de tela
   disponível nesta máquina (ver adendo no handoff 2026-09-13).
5. **Período segue 24h/7d/30d.** Estender não foi pedido; `daily_agg` já
   retém tudo e o knob é só `days:`.
6. **Um dia por linha no ledger, desc, só dias COM evento**; heatmap desenha a
   grade INTEIRA do período (esparso é aceitável e esperado).

## Verificação (Regra 9)

- `./run-tests.sh`: **594 testes / 94 suítes verdes** (eram 583 antes da
  feature: +8 dela, +3 do review) — 2 novos no `HistoryQueryTests` (grade da
  janela e "hoje"/coluna seguindo o calendar INJETADO, testado com banco em
  UTC+14 para não passar verde num host UTC), 4 no `AnalyticsModelTests`
  (agregação, NULL ≠ 0, intensidade relativa, grade esparsa no reload) e 6 no
  `AnalyticsUsageSpendViewTests` (grade Mon..Sun alinhada por coluna, lacuna
  no meio da semana, lacuna cruzando o domingo, janela de 1 dia, vazio,
  placeholder "—" ≠ "~$0.00").
- Evidência: `panelrender --analytics` imprime "período 30d, 30 dias no
  ledger, 30 células no heatmap (27 com custo computável)" e grava o PNG.
- Conferência do render por PIXELS de forma programática (o modelo desta
  sessão não lê imagem, e captura de tela está bloqueada): mapa de densidade
  (`scripts/qa-density.swift`) mostra a ordem real das seções — picker →
  tokens/dia → custo/dia → ledger de 30 linhas (tokens e custo alinhados à
  direita) → grade 7×5 do heatmap + legenda → top models → rodapé.
- Medição linha a linha da coluna de custo (`scripts/qa-bands.swift`), que
  prova o requisito NULL ≠ 0 NO ARTEFATO: 27 faixas de tinta com 66–69 px
  (as linhas "~$X.XX") e exatamente 3 faixas de 17×2 px alinhadas à direita
  (x=1502..1518) — a travessão "—" — nos 3 dias sem preço computável
  (2026-08-16, 2026-08-26, 2026-09-05). Nenhuma linha com "$0.00" inventado.
- PNG de evidência REGERADO depois dos ajustes do review (legenda e grade) e
  remedido: 28 faixas no ledger (1 cabeçalho + 27 linhas "~$X.XX" de 66–69 px),
  3 travessões de 17×2 px nos dias sem preço e a legenda já lendo
  "blank = no computable cost or $0.00" — a evidência corresponde ao código
  atual, não a um render antigo.

## Limites conhecidos

- **Dia FUTURO em `daily_agg`** (skew de relógio/import): o ledger sai da
  mesma série dos charts (`WHERE day >= ?`, sem limite superior —
  `HistoryQueries.swift:156`) e o heatmap sai de `windowDays`, que para em
  hoje. Um dia futuro apareceria no ledger/charts e não na grade, e ficaria
  fora do `maxCost` do heatmap. Não há caso conhecido no banco do dono; a
  decisão (clampar a série em `tomorrow` — o que também muda painel e export —
  vs. estender a grade) fica registrada aqui em vez de virar comportamento
  silencioso. Tratar junto de qualquer trabalho de correção de dados.
- **Célula vazia é ambígua por desenho**: custo 0 REAL e dia sem preço
  computável pintam igual (intensidade 0). O dado distingue (0 vs nil, tooltip
  "~$0.00" vs "—") e a legenda diz isso; a cor achata de propósito.

A janela real (`NSWindow`) é coberta por ui-smoke (boot + item + toggle) e
pela conferência visual do dono; a evidência por pixels vem do harness porque
captura de tela não está disponível nesta sessão. Se o dono habilitar
Gravação de Tela + Acessibilidade para o DSH Desktop, o ciclo
"screenshot → diff full-width → evidência" volta a rodar inteiro.
