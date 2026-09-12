# Decisões de UI — 2026-09-12 (pós-1.0)

## 1. Painel sem barra de rolagem

`contentMaxHeight` 470→560pt + `.scrollIndicators(.hidden)` no ScrollView do
detalhe (`ProviderPanelView`). O caso comum (1 provider selecionado, ≤2 contas)
cabe inteiro; o ScrollView permanece como rede de segurança para muitas contas.
Evidência: `docs/qa/evidence/f6-panel-noscroll.png` (todas as seções visíveis).

## 2. Item da menu bar pintava incompleto/nada ("sumiu as infos")

**Causa-raiz**: `Image(nsImage:)` com **SVG** (representação vetorial, sem
pixels fixos) no label do `MenuBarExtra` quebra o sizing/render do status item.
Sintomas vistos: item colapsado para ~49pt mostrando só o 1º par logo+valor
(build HStack), e item sem pintar nada (build Text+Image inline). Com `Text`
puro o item sempre pintou completo — prova por diff de pixels.

**Fix**: label = **Text único** (medição exata — mecanismo do label original)
com logos **INLINE** via `Text(Image(nsImage:))`, usando **bitmaps 3x
rasterizados** na carga (`ProviderLogo.bitmap(for:points:)`, cache por
id+points). O painel continua usando o SVG original (nítido em qualquer
tamanho e imune — o bug é específico do status item).

**Evidência**: diff de pixels da menu bar INTEIRA (2560pt) com/sem o app +
`docs/qa/evidence/menubar-logos-fixed.png` — `[X-logo]7% [Z-logo]17% U19%
K11%` completo; AX volta a medir ~145pt (antes 49pt).

### Lições (processo)

- **Diff de pixels em região fixa é armadilha**: o item realoca no bar
  (display ultrawide 2560pt + Bartender). Sempre diff da LARGURA TOTAL.
- **AX name ≠ pixels**: o `accessibilityLabel` sempre reportou a string
  completa enquanto o item não pintava — verificação visual é obrigatória
  para render.
- **Confunder**: existe um **CodexBar.app instalado** na máquina com item
  `[logo]7%` próprio (monitora o mesmo codex) — não confundir com o nosso.
- **ImageRenderer (panelrender) não rasteriza NSImage** — logos somem no
  harness; textos medem normalmente. O harness serve p/ texto/layout, não
  para validar imagem no status item.
