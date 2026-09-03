# TokenBar

Native macOS menu bar app that keeps your AI coding usage visible — light enough to never think about it.

**Status: F1** — Claude Code local token counting. Full roadmap: `docs/specs/2026-09-02-design.md` (pt-BR).

## Build (no Xcode required)

```bash
./run-tests.sh                 # build + tests (Swift Testing; never run bare `swift test` — false green on CLT toolchains)
./scripts/make-app.sh          # → build/TokenBar.app
./scripts/e2e.sh               # full end-to-end incl. resource budget
```

## Privacy

Read-only on your CLI session files. No credentials, no network, no telemetry in F1.
