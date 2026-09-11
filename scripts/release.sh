#!/bin/bash
# TokenBar — release LOCAL: build .app (release), zip, checksum sha256 e notas.
# NÃO publica nada — só prepara artefatos em build/ (push da tag e upload da
# release são decisão do dono do repo; em CI, o workflow `ci.yml` faz o mesmo
# pipeline automaticamente no push de uma tag `v*`).
#
# Uso: ./scripts/release.sh [VERSION]
#   VERSION aceita "1.0.0" ou "v1.0.0" (default: 1.0.0)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
VERSION="${VERSION#v}"
export TOKENBAR_VERSION="$VERSION"

echo "==> Building TokenBar.app (release, versão $VERSION)"
./scripts/make-app.sh release

cd build
ZIP="TokenBar-${VERSION}.zip"
rm -f "$ZIP" "$ZIP.sha256" "TokenBar-${VERSION}-notes.md"

echo "==> Zip ($ZIP)"
# ditto (não zip): preserva extended attributes/metadata do bundle — o jeito
# correto de distribuir um .app assinado (aqui: ad-hoc).
ditto -c -k --keepParent TokenBar.app "$ZIP"

echo "==> Checksum"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

COMMIT="$(git rev-parse --short HEAD)"
DATE="$(date +%Y-%m-%d)"
cat > "TokenBar-${VERSION}-notes.md" <<NOTES
# TokenBar ${VERSION}

Release date: ${DATE} · Commit: ${COMMIT}

## Highlights

- 10 providers: Claude Code, Codex, Gemini CLI, Z.ai, Cursor, OpenRouter,
  Qwen/Alibaba, Antigravity, DeepSeek, Grok.
- Menu bar fragments (C · X · G · Z + F5 providers) and the rich panel ported
  1:1 from the MIT reference CodexBar (see NOTICE).
- SQLite history with estimated cost, Analytics window, CSV/JSON export,
  multi-account.
- Limit alerts with per-crossing dedupe + Settings window (⌘,): launch at
  login, refresh intervals, thresholds, menu bar visibility.

## Install

1. Download \`TokenBar-${VERSION}.zip\` and unzip.
2. Move \`TokenBar.app\` to /Applications.
3. Right-click the app → **Open** (ad-hoc signed build — Gatekeeper asks once).

Verify integrity (optional):

    shasum -a 256 -c TokenBar-${VERSION}.zip.sha256

## Notes

- Requires macOS 14+. No Xcode required to run.
- Read-only on CLI session files AND credentials; no telemetry.
- See README.md for environment overrides and provider details.
NOTES

echo "==> Artefatos em build/:"
ls -la "$ZIP" "$ZIP.sha256" "TokenBar-${VERSION}-notes.md"
echo "OK: release local pronto (nada foi publicado)."
