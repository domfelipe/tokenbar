# QA F2 — Codex + Gemini + Z.ai (Task 8, protocolo QA DomHubs)

- **Data:** 2026-09-03
- **Branch:** `f2-codex-gemini-zai` @ `fa0ea40` (fixes do Red Team F2 inclusos)
- **Ambiente:** macOS 26.5.1 (Build 25F80), arm64, toolchain Command Line Tools (sem Xcode)
- **Protocolo:** prova de conclusão requisito por requisito (evidência autoritativa ou status "não verificado")
- **Veredito do gate:** 🟢 **APROVADO — 6/6** · suíte 199/199 testes verdes · E2E v2 15/15 PASS (exit 0) · checklist visual 6/6 via AX · Red Team 7 casos com 2 fixes e regressões (ver `f2-redteam-report.md`).

---

## 1. Resumo por requisito

| # | Requisito | Evidência | Status |
|---|-----------|-----------|--------|
| — | Suíte completa (`./run-tests.sh`) | **199/199 testes em 23 suítes** (184 base F2 + 15 regressões de QA/Red Team). Log integral na execução final da T8 | ✅ PASS |
| — | E2E v2 (`./scripts/e2e.sh`) | **15 PASS, 0 falha, exit 0** — mock server python3 embutido nas rotas canônicas (`wham/usage`, `quota/limit`), menu bar 4 providers, live update, degradação, orçamento de recursos. Saída integral em [§2.2](#22-e2e-v2---scriptse2esh) | ✅ PASS |
| 1 | Item na menu bar com múltiplos providers | AX (System Events): `name of menu bar items of menu bar 2` → **`C:3.8M X:42% G:193 Z:81%`** — 4 providers na ordem canônica, % nos API-driven (X/Z), tokens nos locais (C/G) | ✅ PASS |
| 2 | Clique → menu abre (painel `.window` com linhas por provider) | Painel abre como `AXWindow`/`AXSystemDialog` com **4 static texts** (uma linha por provider) + 2 botões: `C Claude: 3.8M hoje (local)` · `X Codex: 42% — reseta em 95041d` · `G Gemini: 193 hoje (local)` · `Z Z.ai: 81% — reseta em …` | ✅ PASS |
| 3 | "Refresh now" responde sem erro | Clique AX no botão (group 1 da janela): `updatedAt` do heartbeat avançou **14:12:52Z → 14:12:57Z**, processo vivo. Reforço: no Red Team caso 4 o mesmo caminho recuperou X:42%/Z:81% → X:55%/Z:91% quando o mock voltou | ✅ PASS |
| 4 | Texto da menu bar == selfcheck v2 na mesma hora | `selfcheck` T+3s == heartbeat do app real T0: `menuBarText` **idênticos** (`C:3.8M X:42% G:193 Z:81%`) e payloads `providers.*` idênticos campo a campo (percent/todayTokens/authState). Artefatos: `docs/qa/evidence/f2-selfcheck-2026-09-03.json` | ✅ PASS |
| 5 | Robustez: dir inexistente sem crash; corpus `--poison` consistente com selfcheck | **5a:** `TOKENBAR_CLAUDE_DIR=/tmp/dir-que-nao-existe-qa` (+ auth ausente, API morta) → vivo após 6s. **5b:** corpus poison coberto pelo E2E (genfixtures `--poison`; menu bar do app == selfcheck sobre o mesmo corpus) | ✅ PASS |
| 6 | Quit via painel sem processo zumbi | ⌘Q (atalho do botão "Quit TokenBar", declarado no app) com painel aberto → `pgrep` **vazio**, sem zumbi. Nota de instrumento em [§3.2](#32-itens-3-e-6---notas-de-instrumento) | ✅ PASS |

**Placar do checklist manual: 6/6 PASS.**

---

## 2. Suíte completa e E2E

### 2.1 Suíte de testes — `./run-tests.sh`

Resultado da execução final: **199 testes em 23 suítes, todos verdes**. Composição: 184 da T7 + 11 de snapshot do ledger (RT7) + 1 de provider degradado no heartbeat + 1 de saturação do Gemini (RT1) + 1 de cursores perdidos (RT5) + 1 de rollover-sem-rescan-espúrio. Relatórios de Red Team detalham cada regressão.

### 2.2 E2E v2 — `./scripts/e2e.sh`

Saída da execução de referência (15 checks):

```text
[e2e] PASS: mock no ar: wham/usage 200 com rate_limit.primary_window
[e2e] PASS: mock no ar: quota/limit 200 com success=true
[e2e] PASS: selfcheck v2 mostra os API-driven com % do mock (X:42% e Z:81%)
[e2e] PASS: selfcheck v2 mostra os locais (C e G)
[e2e] PASS: heartbeat criado em 30s
[e2e] PASS: menu bar text igual ao selfcheck ('C:3.4M X:42% G:193 Z:81%')
[e2e] PASS: heartbeat: percent API-driven do mock (codex=42, zai=81)
[e2e] PASS: heartbeat v2: authState ok e fetchedAt fresco nos API-driven
[e2e] PASS: live update após append (Δ=+333 observado)
[e2e] PASS: degradação: mock morto → app vivo e heartbeat continua (Δ=+222)
[e2e] PASS: sem retry storm: 0 request(s) do app na janela (≤ 3 = burst inicial)
[e2e] PASS: selfcheck pós-morte: erro tokenizado 'network' em codex e zai
[e2e] PASS: processo vivo (sem crash, mock morto há >60s)
[e2e] PASS: memória própria (phys_footprint) 18.2M ≤ 40MB
[e2e] PASS: cpu 0.0% ≤ 0.5%
[e2e] concluído: 0 falha(s)
```

Destaques v2: mock server python3 (`http.server`) embutido no script serve shapes sintéticos da spec nas rotas canônicas via `TOKENBAR_CODEX_API`/`TOKENBAR_ZAI_API`; degradação prova app vivo + heartbeat continuando via providers locais; o diagnóstico da degradação vem do selfcheck v2 (erro tokenizado `network`, nunca URL crua — spec §9); o log de requests do mock captura o header `Authorization` e só contém tokens `fake-*` (spec §9).

---

## 3. Checklist manual — evidências detalhadas

Instrumento: System Events / AX (Accessibility autorizada; Screen Recording segue negada — não é necessária). App: `build/TokenBar.app` (release), lançado direto, com overrides `TOKENBAR_*` para corpora sintéticos e mock local nas duas APIs.

### 3.1 Itens 1, 2 e 4 — menu bar, painel e consistência com selfcheck

```text
osascript: name of menu bar items of menu bar 2
→ "C:3.8M X:42% G:193 Z:81%"            (item 1 — 4 providers, ordem C/X/G/Z)

click menu bar item 1 → {role, subrole} of window 1
→ {AXWindow, AXSystemDialog}            (painel .window do MenuBarExtra)

value of every static text of every group of window 1
→ "C Claude: 3.8M hoje (local)"
→ "X Codex: 42% — reseta em 95041d"
→ "G Gemini: 193 hoje (local)"
→ "Z Z.ai: 81% — reseta em 95041d"      (item 2 — uma linha por provider + botões)

selfcheck T+3s menuBarText == heartbeat T0 menuBarText == nome AX do item 1
→ "C:3.8M X:42% G:193 Z:81%"            (item 4 — fonte única: SnapshotStore)
```

O sufixo "reseta em 95041d" é o comportamento correto para o reset sintético do mock (epoch ano 2286) — honesto, não é defeito.

### 3.2 Itens 3 e 6 — notas de instrumento

- **Item 3:** os botões do painel são anônimos no AX (`name`/`title` = missing value); a identificação foi por posição (botão 1 = Refresh, botão 2 = Quit, ordem do SwiftUI). O clique no botão 1 avançou o `updatedAt` do heartbeat (14:12:52Z → 14:12:57Z) com o app vivo — prova de re-ingest. O caminho funcional completo (refresh → erro → recuperação com valores novos) está no Red Team caso 4.
- **Item 6:** o `AXPress` no botão 2 sofreu uma condição de corrida do harness (a janela fechou entre o `count` e o `perform`), então o quit foi exercitado por **⌘Q** — o atalho declarado no código exatamente no botão "Quit TokenBar" (`.keyboardShortcut("q")`) — mesmo caminho de ação do botão. `pgrep` vazio após 3s, sem zumbi.

### 3.3 Item 5 — robustez

**5a.** Diretório inexistente + credencial Codex ausente + API morta: processo vivo após 6s (`kill -0` ok), heartbeat escrito. **5b.** Corpus poison (`--poison`): o E2E compara o menu bar do app real com o selfcheck sobre o MESMO corpus — valores idênticos (linhas inválidas ignoradas pela mesma pipeline).

---

## 4. Observações (o que este QA não cobre)

- **Validação Z.ai com credencial REAL ao vivo:** durante a T8 uma instância do app rodou sem overrides e buscou o endpoint real da Z.ai com a credencial local — recebeu dados válidos (uso exibido). O fallback embutido (apiKey → OAuth) segue sem distinguir QUAL das duas credenciais foi aceita; pendência de validação real mantida com mitigação (ver decisões F2).
- FSEvents através de sleep real do Mac segue manual (sem automação) — os observers de sleep/wake estão wired e cobertos por testes de scheduler.
- Distribuição/notarização, LaunchAtLogin e multi-usuário fora do escopo da F2.
- `selfcheck` sai 0 mesmo com falhas (SDD-9): todos os comparativos usam só o parse do JSON.

---

*Gerado pelo agente QA do DevSquad DomHubs. Evidências: `docs/qa/evidence/f2-selfcheck-2026-09-03.json`, `docs/qa/evidence/f2-rt3-500storm-requests.log`, `docs/qa/evidence/f2-rt6-footprint.log`, `docs/qa/evidence/f2-visual-ax-f2.md`.*
