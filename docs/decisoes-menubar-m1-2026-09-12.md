# Decisões de menu bar — M1 (2026-09-12, pós-1.0)

Paridade visual com a referência MIT (CodexBar) no item da menu bar, sem
mudar a string canônica e sem pesar o app (10 providers mantidos).

## 1. Seis SVGs faltantes portados (cursor/openrouter/alibaba/antigravity/deepseek/grok)

Cópias intactas de `Sources/CodexBar/Resources/ProviderIcon-*.svg` (MIT —
`NOTICE` atualizado com os 10 arquivos). Os 4 anteriores conferem
bit-a-bit (`cmp`). Efeito: nenhum provider cai mais no fallback de sigla
na menu bar nem no painel; `copilot` segue em fallback (sem ícone na
referência). Teste `PanelLogoTests` atualizado (4→10 + fallback=copilot).

## 2. Tokens visuais de pace + reset (só pintura)

`menuBarPaceFragment` (port de `MenuBarDisplayText.paceText`: "+69%" /
"-50%" / "0%" / nil) + `menuBarResetFragment` ("↻ 2h 44m", mesmo countdown
do painel). O label mostra pace só com sinal (déficit/reserva — "0%"/nil
omite, sem ruído) e reset só com `resetsAt` futuro. A string canônica
(`displayString`, AX, heartbeat, render gate) NÃO muda — teste
`visualFragmentsNeverLeakIntoCanonicalString` fixa isso (Regra 9).

## 3. Não-portado nesta fase (consciente)

- Dim de stale (a referência dimma com falha de refresh): sem sinal de
  falha no `ProviderDisplay` — inventar seria chute.
- Editor de layout com condicionais, `NSStatusItem` por provider, Overview,
  widgets: o que mais pesa; o look default (modo percent) já é coberto.
- Dash "—" p/ token indisponível: omitimos p/ economizar largura do bar.

**Evidência**: `docs/qa/evidence/menubar-m1-pace-reset.png` (item real:
`680.8k 10% -90% ↻ 6d 15h 43% ↻ 1h 3m …` com logos) + diff full-width
2560pt com/sem app (DIFERENTE = pinta ✓). Gates: 582 testes / 93 suítes,
e2e 0 falhas, ui-smoke PASS (AX `C:1.5k` intacto).
