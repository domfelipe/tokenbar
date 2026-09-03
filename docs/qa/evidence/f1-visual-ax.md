# F1 — Verificação visual dos itens 1, 2, 3, 6 do QA (pós-autorização Accessibility)

Data: 2026-09-02 · Instrumento: System Events / AX (Screen Recording segue negada — não é necessária)
App: build/TokenBar.app (release, commit 5dd0733), lançado via `open` (LaunchServices), sem env overrides.

## Item 1 — status item visível na menu bar ✅
```
osascript: tell process "tokenbar" to get {name, description, position, size} of menu bar items of menu bar 2
→ "TB, status menu, 1040, 3, 29, 24"
```
Texto "TB" correto (corpus real sem eventos hoje — roteiro prevê TB). Label AX == string computada do
SnapshotStore → confirma reatividade do label do MenuBarExtra (⚠️ da Task 10, resolvido).

## Item 2 — menu abre com entradas corretas ✅
```
click menu bar item 1 of menu bar 2; name of menu items of menu 1
→ {"TokenBar F1 — local mode", <separador>, "Refresh now", <separador>, "Quit TokenBar"}
```

## Item 3 — "Refresh now" responde ✅
```
click menu item "Refresh now" → menu item ... of application process tokenbar (sem erro)
pgrep -x tokenbar → ALIVE pós-Refresh
```

## Item 6 — Quit pelo menu, sem zumbi ✅
```
click menu item "Quit TokenBar" → sem erro
pgrep -fl tokenbar → vazio ("encerrou limpo — sem zumbi")
```

Gate QA final: **6/6 PASS** (itens 4 e 5 já verificados na rodada automatizada de 2026-09-02).
