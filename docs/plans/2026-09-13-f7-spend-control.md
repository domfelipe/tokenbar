# F7 — Spend control (orçamento, projeção e alerta de gasto)

Fase pedida depois do Usage & Spend ("o app diz quanto você gastou; ainda
não diz 'você vai estourar dia 22'"). Reusa o que já existe: `PricingTable`
(NULL ≠ 0), `daily_agg`, `AppSettingsStore`, `AlertEngine` (F5), painel e
Analytics. **Nada de provider novo, nada de API nova.**

## Escopo

| # | Entrega | Onde |
|---|---|---|
| T1 | Gasto do MÊS-CALENDÁRIO por provider + projeção de fechamento + tipo de orçamento (puro) | `TokenBarCore` |
| T2 | Orçamento global e por provider persistido em `settings` + escrita viva | `AppSettingsStore`, Settings |
| T3 | Alerta de orçamento no `AlertEngine` (cruza e dispara 1×; re-arma no mês novo) | `AlertEngine` |
| T4 | UI: linha no painel (mês vs orçamento) + seção "Budget" no Analytics | `TokenBarUI` |
| T5 | Evidência (panelrender/AX) + gate + review independente + commit por task | — |

## Decisões de contrato

1. **Mês-calendário, não "últimos 30 dias"**: o período do orçamento é o mês
   do calendário do BANCO (mesmo `calendar` do rollover e do `dayString`), de
   00:00 do dia 1 até HOJE inclusive — dia futuro é anomalia de relógio e não
   entra (decisão registrada em `decisoes-usage-spend-2026-09-13.md`).
2. **NULL ≠ 0 continua valendo**: custo do mês `nil` quando nenhum grupo do mês
   tem preço computável. Sem custo computável não há projeção — a UI mostra
   "—", nunca "~$0.00" nem projeção inventada.
3. **Projeção = mês-corrido / dias corridos do mês × dias do mês**, com o dia
   corrente contando como completo (é o dado que existe). Dia 1 projeta o
   próprio dia — zero à esquerda é honesto.
4. **Orçamento efetivo de um provider** = o teto dele quando existe, senão o
   global; sem nenhum dos dois → sem orçamento (nenhum alerta, nenhuma linha).
5. **Sanitização** (padrão do projeto): valor não-finito, ≤ 0 ou acima do teto
   absurdo → tratado como ausente (nunca crash, nunca chute).
6. **Alerta de orçamento** reusa a máquina de dedupe do `AlertEngine` (dispara
   1× ao cruzar, segue suprimido enquanto acima, re-arma quando cai ou quando o
   período renova — no orçamento, a virada do mês). Os thresholds são os mesmos
   da config (`alerts:thresholds`), agora sobre a FRAÇÃO do orçamento.

## Fora de escopo (registrado, não pedido)

Multi-moeda (tudo em USD, como o resto); orçamento por semana/dia; histórico
de meses fechados; notificação fora do gateway existente.

## Regra de ouro da fase

Cada task fecha com teste headless (núcleo puro) e a UI fecha com evidência
verificável — o gate do painel (`qa-axtree --panel`) e o `ui-smoke` já provam
estrutura e cliques, então a fase NÃO se fecha com "parece certo".

## Status (13/09) — fase ENTREGUE

| Task | Commit | Estado |
|---|---|---|
| T1 núcleo (mês, projeção, orçamento) | `b6d22d5` | ✅ |
| T2 orçamento persistido + aba de Settings | `4d5b941` | ✅ |
| T3 alertas de gasto/projeção + wiring no ciclo | `1e467d9` | ✅ |
| T4a linha "Budget" no painel | `159cbb7` | ✅ |
| Fix da aba Budget (estilo do Form) | `30a2157` | ✅ |
| T4b seção "Budget" no Analytics | `65e7a11` | ✅ |
| T5 review independente + docs | este commit | ✅ |

Decisões, verificação e limites em `docs/decisoes-f7-spend-control-2026-09-13.md`.
Pendência aberta registrada lá: preços dos modelos locais (Claude do dono com
custo NULL) — decisão do dono, fora do escopo.
