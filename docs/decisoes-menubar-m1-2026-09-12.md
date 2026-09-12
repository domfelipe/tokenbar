# Decisões de menu bar — M1 (2026-09-12, pós-1.0)

Paridade visual com a referência MIT (CodexBar) no item da menu bar: só
logo + % (reset e pacing vivem SÓ no painel — decisão do dono).

## 1. Seis SVGs faltantes portados (cursor/openrouter/alibaba/antigravity/deepseek/grok)

Cópias intactas de `Sources/CodexBar/Resources/ProviderIcon-*.svg` (MIT —
`NOTICE` atualizado com os 10 arquivos; os 4 anteriores conferem bit-a-bit
via `cmp`). Nenhum provider cai mais no fallback de sigla; `copilot` segue
em fallback (sem ícone na referência). `PanelLogoTests` atualizado.

## 2. Label = imagem única pré-renderizada (`MenuBarLabelImage`, AppKit)

Achados por pixels — o AX mede normal e mente (Regra 9):

1. `Text` com `Image` inline: mede ~zero e pinta em branco no status item.
2. `HStack`: o item é enquadrado na largura do 1º par e o resto clipa.
3. Bitmap com `isTemplate = true`: pinta em branco invisível no status
   item (no painel/janelas o template funciona).
4. `NSRectFillUsingOperation` não existe mais neste SDK — usar
   `NSRect.fill(using:)`.

Por isso o label inteiro (logos silhueta branca + texto branco 11 medium)
é desenhado num `NSBitmapImageRep` 2x e exibido como UMA imagem: medida
honesta (largura = pixels reais) e pintura determinística. A silhueta
branca equivale ao look de template (fills dos SVGs são mistos: alibaba
#111/deepseek currentColor sumiriam na barra escura). Cache `NSCache`
(teto 8) por string canônica — custo ~zero por ciclo. AX segue a string
canônica (`C:1.5M X:10% …`), heartbeat e render gate intactos.

Testes que fixam: `bitmapsHaveVisiblePixels` (raster nunca em branco),
`MenuBarLabelImageTests` (largura honesta, fallback de sigla, cache).

## 3. Não-portado (consciente)

- Pace/reset na barra (dono: só %; reset só no painel).
- Barra CLARA: silhueta branca some nela — exigiria tinta por appearance
  ou NSStatusItem AppKit (follow-up; a barra do dono é escura).
- Editor de layout com condicionais, `NSStatusItem` por provider, Overview,
  widgets: o que mais pesa; o look default já é coberto.

**Evidência**: `docs/qa/evidence/menubar-m1-logos.png` (`[codex]10%
[Z]43% [cursor]19%` com logos, pixels reais) + diff full-width 2560pt
com/sem app (DIFERENTE = pinta ✓). Gates: 583 testes / 93 suítes verdes,
ui-smoke PASS. E2E oscila 0–5 falhas de timing do mock NESTA máquina com e
sem a mudança (HEAD limpo também falha) — flake de ambiente sob carga, não
regressão: a mudança é só render do label, sem tocar fetch/scheduler/DB.
