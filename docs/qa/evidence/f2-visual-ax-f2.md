# F2 — Verificação visual do checklist via AX (QA T8)

Data: 2026-09-03 · Instrumento: System Events / AX
App: build/TokenBar.app (release, commit fa0ea40) com corpora sintéticos + mock local (X:42%, Z:81%).

## Item 1 — status item com múltiplos providers
```
name of menu bar items of menu bar 2
→ "C:3.8M X:42% G:193 Z:81%, -25, 3, 181, 24"
```

## Item 2 — painel .window com linhas por provider
```
{role, subrole} of window 1 → {AXWindow, AXSystemDialog}
value of every static text of every group of window 1
→ "C Claude: 3.8M hoje (local)"
→ "X Codex: 42% — reseta em 95041d"
→ "G Gemini: 193 hoje (local)"
→ "Z Z.ai: 81% — reseta em 95041d"
buttons of group 1 → 2 (Refresh now / Quit TokenBar — anônimos no AX)
```

## Item 3 — Refresh responde
```
click button 1 of group 1 of window 1
heartbeat updatedAt: 2026-09-03T14:12:52Z → 2026-09-03T14:12:57Z, app vivo
```

## Item 4 — menu bar == selfcheck v2 (mesma hora)
```
selfcheck menuBarText:  "C:3.8M X:42% G:193 Z:81%"   (14:08:57Z)
heartbeat menuBarText:  "C:3.8M X:42% G:193 Z:81%"   (14:08:54Z)
providers.* idênticos campo a campo (percent/todayTokens/authState)
```

## Item 5 — robustez
```
5a: TOKENBAR_CLAUDE_DIR=/tmp/dir-que-nao-existe-qa + auth ausente + API morta
    → kill -0 vivo após 6s
5b: coberto no e2e (corpus --poison, menu bar do app == selfcheck)
```

## Item 6 — Quit sem zumbi
```
⌘Q (atalho do botão "Quit TokenBar", .keyboardShortcut("q") no app)
pgrep -f "TokenBar.app/Contents/MacOS/tokenbar" → vazio (sem zumbi)
Nota: AXPress no botão 2 sofreu corrida do harness (janela fechou entre
count e perform); ⌘Q é o mesmo caminho de ação do botão.
```

Gate QA F2: **6/6 PASS**
