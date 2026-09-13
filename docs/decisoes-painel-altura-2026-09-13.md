# Painel: janela colapsada em 129pt — causa, correção e gate (2026-09-13)

Relato do dono: *"eu só consigo ver os logos mas o analytics e as outras coisas
eu não consigo ver no painel, aliás o painel só me traz os logos e as
barrinhas"*.

## Causa-raiz

`ScrollView` **não tem altura intrínseca**, e o `MenuBarExtra` (estilo
`.window`) dimensiona a JANELA pela altura ideal do conteúdo. Com
`.frame(maxHeight: 560)` o scroll pedia ~0pt: a janela abria com **129pt**
(= chip bar 31 + divisor + scroll ~0 + divisor + rodapé ~96) e todo o miolo —
KPIs, mini gráfico, contas, ações e as próprias linhas de menu — ficava FORA da
janela. Não era overflow de conteúdo (não havia rolagem possível): era TAMANHO
de janela. `maxHeight` limita, não define.

Medição da janela real (CGWindowList, com o painel aberto): **310x129 antes**,
**310x489 depois**; no ui-smoke (hermético) 310x524. Transcrição completa em
`docs/qa/evidence/panel-height-2026-09-13.log`.

### Por que passou batido

1. A evidência do painel era o render do `panelrender`, que monta o corpo do
   painel **por cópia, sem o ScrollView** e com altura livre — nunca exercitou
   a janela real. O `f6-panel-noscroll.png` ("todas as seções visíveis")
   provava o layout, não o tamanho da janela.
2. A premissa registrada em 12/09 — "o painel do MenuBarExtra não expõe
   conteúdo ao AX" — é **falsa**: valia para **System Events**, que não
   enumera as janelas deste app. A API de Acessibilidade DIRETA
   (`AXUIElementCopyAttributeValue`) devolve a árvore completa do painel
   aberto, com frames, e o `AXPress` clica nos botões.
3. O `ui-smoke` clicava no item via `osascript` com `2>/dev/null` e **sem
   checar o erro**: quando o acesso assistivo estava negado, o script dizia
   "toggle do painel ok (app vivo)" sem ter clicado nada.

## Correção

1. **`ProviderPanelView.scrollHeight(measured:cap:)`** — altura DEFINIDA: a
   altura medida do conteúdo (via `PreferenceKey` + `GeometryReader` dentro do
   scroll), com **piso de 1pt** (pedir 0 era o colapso) e teto em
   `contentMaxHeight`. O indicador de rolagem aparece **só** quando o conteúdo
   de fato passa do teto — sem overflow, o painel fica como na referência.
2. **`ProviderActionRows` fora do `ScrollView`** — "Add account… / Usage
   dashboard / Export" agora ficam entre o scroll e o rodapé. São ações do app,
   não conteúdo do provider: não podem afundar abaixo do teto. Era exatamente o
   caminho do "Usage dashboard" que o dono não encontrava.

## Gate (para não regredir em silêncio)

`scripts/qa-axtree.swift` (novo instrumento, AX DIRETO):

- `--panel <pid>`: exige altura ≥ 300pt e os 7 itens de ação/rodapé **dentro**
  da janela do painel (o guarda contra o colapso de 129pt);
- `--press <pid> <rótulo>`: AXPress em um botão do painel;
- `--wait-window <pid> <título>`: espera uma janela aparecer.

`scripts/ui-smoke.sh` agora: (a) **falha** se o clique via AX no item não
funcionar; (b) abre o painel e roda `qa-axtree --panel`; (c) pressiona "Usage
dashboard" e exige que a janela "TokenBar Analytics" apareça. Testes unitários
do requisito: `PanelSizingTests` (piso, teto, NaN/infinito).

## Verificação

- `./run-tests.sh`: **595 testes / 95 suítes verdes** (594 → +1 do painel).
- `ui-smoke`: PASS — `painel: 310x524` com 7 itens dentro da janela e "Usage
  dashboard abre a janela do Analytics".
- App real: painel **310x489** (era 129); árvore AX mostra chip bar
  (Claude/Codex/Z.ai/Cursor), `AXScrollArea` 310x282 (header, janela diária,
  KPIs, mini gráfico de 30d, "Last 7 days" e "Top model") e as 7 ações dentro
  da janela — evidência: `docs/qa/evidence/panel-actions-2026-09-13.png`
  (render do harness com a composição nova) + o log acima.
- Bônus da mesma medição: a janela do Analytics, aberta por `AXPress`, mostrou
  o ledger real com `2026-09-11 | 37.139.242 | —` (NULL ≠ 0 ao vivo, dado do
  dono).

## Achado de operação (apareceu durante a verificação)

Depois de `./scripts/make-app.sh release` — que **re-assina** o bundle ad-hoc a
cada build — o `open build/TokenBar.app` pode subir o processo **sem criar o
item da menu bar** (AX responde "menu bar 2 … índice inválido", nenhuma janela
do app). Não é o código: o registro do app no **LaunchServices** fica velho
quando a assinatura do bundle muda. Correção:

    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R build/TokenBar.app
    open build/TokenBar.app

E **nunca subir duas instâncias** (`open -n` + exec direto): cada uma cria o
próprio item na menu bar e as consultas AX por nome de processo ficam ambíguas —
foi o que me fez perseguir um "hang" que não existia. Sempre `pkill -x tokenbar`
antes de relançar.

## Como reproduzir a verificação

    osascript -e 'tell application "System Events" to tell process "tokenbar" to get name of menu bar item 1 of menu bar 2'
    osascript -e 'tell application "System Events" to tell process "tokenbar" to click menu bar item 1 of menu bar 2'
    xcrun swiftc -O scripts/qa-axtree.swift -o /tmp/qa-axtree
    /tmp/qa-axtree --panel $(pgrep -x tokenbar)                    # → PASS: 310x489, 7 itens dentro
    /tmp/qa-axtree --press $(pgrep -x tokenbar) "Usage dashboard"  # → abre a janela
    /tmp/qa-axtree --wait-window $(pgrep -x tokenbar) "TokenBar Analytics"

## Limite conhecido

O piso de 300pt do gate é guarda contra o COLAPSO, não contrato de layout:
provider com conteúdo acima de 560pt rola dentro do teto, com indicador
visível.
