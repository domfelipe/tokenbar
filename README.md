# TokenBar

Native macOS menu bar app that keeps your AI coding usage visible — light enough to never think about it.

**Status: F2** — Codex, Gemini CLI and Z.ai in the menu bar, on top of the F1 Claude local core. Full roadmap: `docs/specs/2026-09-02-design.md` (pt-BR).

## What you see (F2)

Order is fixed C · X · G · Z; providers without data stay hidden.

| Fragment | Provider | Source |
|---|---|---|
| `C:12.4k` | Claude Code | local transcripts (`~/.claude/projects`) |
| `X:62%` | Codex (OpenAI/ChatGPT) | usage API (`wham/usage`) + local sessions |
| `G:193` | Gemini CLI | local sessions (`~/.gemini/tmp/**/chats`), real tokens |
| `Z:81%` | Z.ai coding plan | usage API (`quota/limit`) |

Open the panel for a line per provider (percent + reset time, or today's tokens), **Refresh now** and **Quit TokenBar** (⌘Q).

Behavior highlights: adaptive scheduler (idle 5 min, menu 60 s, pressure ≥ 80% → 30 s, error backoff ×2 capped at 30 min, zero network during sleep) · graceful degradation (API down → last good state, local providers keep counting; restart mid-day keeps today's totals) · per-provider cursor files + day snapshot, self-healing against truncation and corrupted state.

## Build (no Xcode required)

```bash
./run-tests.sh                 # build + tests (Swift Testing; never run bare `swift test` — false green on CLT toolchains)
./scripts/make-app.sh          # → build/TokenBar.app
./scripts/e2e.sh               # full end-to-end: mock API server, 4 providers, degradation, resource budget
```

## Environment overrides

Every override is optional and intended for tests/e2e — a normal launch uses none of them.

| Variable | What it redirects |
|---|---|
| `TOKENBAR_SUPPORT_DIR` | App Support directory holding per-provider state (`<provider>-cursors.json`, `<provider>-ledger.json`). Isolates tests/e2e from real state. |
| `TOKENBAR_E2E_DIR` | Directory where the E2E heartbeat JSON (per-provider diagnostics) is written. |
| `TOKENBAR_CLAUDE_DIR` | Claude Code `projects` transcript directory (default `~/.claude/projects`). |
| `TOKENBAR_CODEX_DIR` | Codex rollout sessions directory (default `~/.codex/sessions`). |
| `TOKENBAR_CODEX_AUTH` | Path of the Codex `auth.json` read for the API token (default `~/.codex/auth.json`). |
| `TOKENBAR_CODEX_API` | Base URL of the Codex usage API — the canonical path `backend-api/wham/usage` is appended (default `https://chatgpt.com`). |
| `TOKENBAR_ZAI_API` | Base URL of the Z.ai quota API — the canonical path `api/monitor/usage/quota/limit` is appended; the host also selects the region (default `https://api.z.ai`). |
| `TOKENBAR_ZAI_CONFIG` | Path of the Z.ai `config.json` (apiKey + region, default `~/.zcode/v2/config.json`). |
| `TOKENBAR_ZAI_AUTH` | Path of the Z.ai `credentials.json` (OAuth fallback token, default `~/.zcode/v2/credentials.json`). |
| `TOKENBAR_GEMINI_DIR` | Gemini CLI state directory whose `tmp/<project>/chats/session-*.jsonl` files are ingested (default `~/.gemini`). |

## Privacy

Read-only on your CLI session files AND on credentials (`~/.codex/auth.json`, `~/.zcode/v2/config.json`, `~/.zcode/v2/credentials.json` — never written, never logged). No telemetry. The only network traffic is the usage query to each configured provider, with your token — which never appears in any log, heartbeat or artifact. Fixtures and tests use `fake-*` values only; the repo is public.

## Docs (pt-BR)

- `docs/specs/2026-09-02-design.md` — design/spec
- `docs/specs/f2-data-sources.md` — F2 data sources reference (endpoints, shapes, fixture rules)
- `docs/decisoes-f1.md`, `docs/decisoes-f2.md` — technical decisions (context → decision → consequence)
- `docs/qa/f1-*.md`, `docs/qa/f2-*.md` — QA gates and Red Team reports
