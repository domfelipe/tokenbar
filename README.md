# TokenBar

Native macOS menu bar app that keeps your AI coding usage visible — light enough to never think about it.

**Status: F5 (Task 1)** — everything from F4 (Codex, Gemini CLI, Z.ai, Claude local core; SQLite history with estimated cost, Analytics window and CSV/JSON export, multi-account) plus the panel redesign ported 1:1 from the MIT reference CodexBar (`NOTICE` in the repo root): provider chip-bar with logos and per-chip quota indicator, segmented usage bar with pace stripe, large-stat dashboard ("Today / 30d / Recent tokens / 30d tokens"), daily bar chart with peak label, "Top model" line, action rows and the Refresh ⌘R / Settings… ⌘, (disabled until F5 T3) / About / Quit ⌘Q footer. Full roadmap: `docs/specs/2026-09-02-design.md` (pt-BR).

> **Trademark notice:** Provider logos are ported from CodexBar (MIT — see `NOTICE`); trademarks belong to their owners — used for identification only, not affiliated.

## What you see (F2)

Order is fixed C · X · G · Z; providers without data stay hidden.

| Fragment | Provider | Source |
|---|---|---|
| `C:12.4k` | Claude Code | local transcripts (`~/.claude/projects`) |
| `X:62%` | Codex (OpenAI/ChatGPT) | usage API (`wham/usage`) + local sessions |
| `G:193` | Gemini CLI | local sessions (`~/.gemini/tmp/**/chats`), real tokens |
| `Z:81%` | Z.ai coding plan | usage API (`quota/limit`) |

Open the panel for the provider chip-bar, usage-window bars with the pace stripe and pacing line, the large-stat dashboard with the daily chart, action rows (Usage dashboard, Export, Add account…) and the Refresh/Settings/About/Quit footer.

Behavior highlights: adaptive scheduler (idle 5 min, menu 60 s, pressure ≥ 80% → 30 s, error backoff ×2 capped at 30 min, zero network during sleep) · graceful degradation (API down → last good state, local providers keep counting; restart mid-day keeps today's totals; database unavailable → app runs in F2 mode, never crashes) · per-provider cursors + day snapshot, self-healing against truncation and corrupted state.

## Rich panel & multi-account (F4/F5)

- **Chip-bar, not lines.** The panel opens on a chip per provider (logo + short name + a 2pt quota indicator). The selected provider shows: usage-window bars (`Weekly 74% used`, `Renews in 6d 16h` — past reset shows `Renewed`, never a negative countdown) with a green/red pace stripe and pacing line (`69% in deficit · Exhausts in 2h 44m`), the large-stat dashboard (`Today $0.08`, `30d $2.10`, `Recent tokens`, `30d tokens`), a 30-day bar chart with a peak label ("$282") and detail lines ("Last 7 days: …", "Top model: …", estimate disclaimer). Panel design ported 1:1 from the MIT reference (CodexBar) — see `NOTICE`.
- **Pacing is honest or absent.** When a provider has a quota window AND at least two days of local history, the panel estimates whether the current pace exhausts the window (`69% in deficit · Exhausts in 2h 44m`; no deficit → `N% in reserve` / `On pace · Lasts until reset`). The stripe marks the projected end of the window (red = overshoot, green = fits). No history, unknown reset or unknown fraction → no line, no stripe at all; session windows project flat (daily aggregates cannot resolve them).
- **Multi-account.** Providers that support it (Claude, Codex, Z.ai) get "Add account…" — a label, a credential file (read-only, never logged) and an optional data directory (own corpus; empty = API-only). Registered accounts cycle alongside the default account with isolated cursors/high-water marks per account. The panel lists accounts (toggle active/inactive, context-menu remove) and the provider total is the SUM of accounts while windows show the worst-case (most-pressed) account. Directories overlapping an existing scan root are blocked at registration — they would double-count history permanently. Invalid paths degrade the account alone with an "invalid path" badge.
- **Logos** are ported from the MIT reference (CodexBar `ProviderIcon-*.svg` — attribution in `NOTICE`); trademarks belong to their owners, identification only. Providers without a ported icon fall back to their letter tile.

## History, cost & export (F3)

- **SQLite (WAL via GRDB)** at `~/Library/Application Support/TokenBar/tokenbar.sqlite`. Every ingested event is persisted (same transaction updates the daily aggregate); legacy F2 `cursors.json` files migrate automatically on first launch (renamed `.migrated`) — no re-scan, no backfill.
- **Estimated cost (`~$`)** is computed at ingest time from the versioned pricing table (`Sources/TokenBarCore/Resources/pricing.json` — public per-MTok prices from vendor pages, PR-welcome). Models without a public price get no cost (NULL, never $0). Costs are never recomputed retroactively.
- **`tokenbar history [--days N] [--provider P] [--format csv|json]`** prints the daily series from the same database the UI reads. Empty window → header-only CSV / `[]`, exit 0.
- **Export** (panel action row) writes `history-<timestamp>.csv|.json` (RFC 4180 CSV, n-null JSON) to `<App Support>/TokenBar/exports/` and reveals them in Finder.
- The database is additive: corruption, full disk or permission errors degrade to F2 behavior (no history display, app keeps working). E2E covers migration, re-run idempotency and resource budget with the database open.

## Build (no Xcode required)

```bash
./run-tests.sh                 # build + tests (Swift Testing; never run bare `swift test` — false green on CLT toolchains)
./scripts/make-app.sh          # → build/TokenBar.app
./scripts/e2e.sh               # full end-to-end: mock API server, 4 providers, degradation, persistence, migration, resource budget
```

## Environment overrides

Every override is optional and intended for tests/e2e — a normal launch uses none of them.

| Variable | What it redirects |
|---|---|
| `TOKENBAR_SUPPORT_DIR` | App Support directory holding ALL persisted state: `tokenbar.sqlite` (+ WAL), per-provider cursors/ledger, `exports/`. Isolates tests/e2e from real state. |
| `TOKENBAR_E2E_DIR` | Directory where the E2E heartbeat JSON (per-provider diagnostics, incl. `history7d`) is written. |
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
- `docs/decisoes-f1.md`, `docs/decisoes-f2.md`, `docs/decisoes-f3.md` — technical decisions (context → decision → consequence)
- `docs/qa/f1-*.md`, `docs/qa/f2-*.md`, `docs/qa/f3-*.md` — QA gates and Red Team reports
