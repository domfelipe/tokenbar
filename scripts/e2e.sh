#!/bin/bash
# E2E F1: corpus sintético → app real → menu bar correto, live update, orçamento de recursos.
# Prova do Goal E2E: 6 PASS + exit 0. Verdade de referência = selfcheck (mesma pipeline
# do app sobre o MESMO corpus no MESMO dia) — nunca o resumo do genfixtures, que com
# --poison exclui linhas inválidas por conta própria (SDD-8/T11).
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/tokenbar-e2e.XXXXXX)"
CORPUS="$TMP/corpus"; STATE="$TMP/state"
mkdir -p "$STATE"
FAILURES=0
say() { echo "[e2e] $*"; }
check() {  # check <nome> <condição shell>
  if eval "$2"; then say "PASS: $1"; else say "FAIL: $1"; FAILURES=$((FAILURES+1)); fi
}
json_field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))$2)" "$1" 2>/dev/null || echo MISSING; }

say "TMP=$TMP"

# 1. corpus determinístico (timestamps espalham 24h; totais de "hoje" vêm do selfcheck,
#    que roda a MESMA pipeline do app sobre o MESMO corpus no MESMO dia — comparação exata)
say "gerando corpus"
swift run -c release genfixtures --out "$CORPUS" --sessions 4 --lines 150 --seed 7 --poison

# 2. verdade de referência (fora da UI). Exit code do selfcheck NÃO é sinal (SDD-9/T12:
#    o try? engole falhas e sai 0) — só o parse do JSON importa.
SELFCHECK="$(swift run -c release tokenbar selfcheck "$CORPUS")"
say "selfcheck: $SELFCHECK"
SC_TEXT="$(echo "$SELFCHECK" | python3 -c "import json,sys;print(json.load(sys.stdin)['menuBarText'])")"

# 3. app bundle real com overrides — MESMO caminho de corpus do selfcheck (T5/SDD-4:
#    não normalizar path na mão).
./scripts/make-app.sh release
TOKENBAR_CLAUDE_DIR="$CORPUS" TOKENBAR_E2E_DIR="$STATE" \
  "build/TokenBar.app/Contents/MacOS/tokenbar" &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true; sleep 0.3; rm -rf "$TMP"' EXIT

# 4. menu bar correto em ≤ 30 s (heartbeat é escrito no primeiro ingest do app)
for i in $(seq 1 30); do
  [ -f "$STATE/state.json" ] && break
  sleep 1
done
check "heartbeat criado em 30s" "[ -f '$STATE/state.json' ]"
APP_TEXT="$(json_field "$STATE/state.json" "['menuBarText']")"
check "menu bar text igual ao selfcheck ('$APP_TEXT' == '$SC_TEXT')" "[ '$APP_TEXT' = '$SC_TEXT' ]"

# 5. live update: append de linha válida → FSEvents → debounce 3 s → heartbeat em ≤ 10 s (Δ +333)
BEFORE_TOTAL="$(json_field "$STATE/state.json" "['todayTokens'].get('claude',0)")"
LINE='{"type":"assistant","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'","message":{"usage":{"input_tokens":111,"output_tokens":222}}}'
echo "$LINE" >> "$(ls "$CORPUS"/session-0/*.jsonl | head -1)"
UPDATED=0
for i in $(seq 1 10); do
  sleep 1
  AFTER_TOTAL="$(json_field "$STATE/state.json" "['todayTokens'].get('claude',0)")"
  if [ "$AFTER_TOTAL" != "MISSING" ] && [ "$AFTER_TOTAL" -ge "$((BEFORE_TOTAL + 333))" ] 2>/dev/null; then
    UPDATED=1; break
  fi
done
check "live update após append (Δ=+333 observado)" "[ '$UPDATED' = '1' ]"

# 6. orçamento de recursos após 60 s ocioso (spec §7: CPU < 0,5%; RAM ≤ 40 MB estacionário)
say "aguardando 60s para medir recursos..."
sleep 60
# RAM medida por phys_footprint (vmmap): memória própria do processo, a mesma base da
# coluna "Memory" do Activity Monitor (instrumento do QA manual, Task 15). O rss= do ps
# inclui páginas de arquivo compartilhadas dos frameworks GUI (SwiftUI/AppKit ~60 MB no
# macOS 26) que não são atribuíveis ao app — medido: rss 75 MB vs footprint 15,3 MB.
FOOT_RAW="$(vmmap --summary "$APP_PID" 2>/dev/null | awk '/Physical footprint:/ {print $3; exit}')"
FOOT_KB="$(python3 -c "
import sys
v=sys.argv[1]; n=float(v[:-1]); u=v[-1].upper()
print(int(n*{'K':1,'M':1024,'G':1024**2}.get(u,1)))" "${FOOT_RAW:-0K}" 2>/dev/null || echo 999999)"
RSS_KB="$(ps -o rss= -p $APP_PID | tr -d ' ')"  # informativo (compartilhado), não é o gate
CPU="$(ps -o %cpu= -p $APP_PID | tr -d ' ')"
check "processo vivo (sem crash)" "kill -0 $APP_PID"
check "memória própria (phys_footprint) ${FOOT_RAW:-MISSING} ≤ 40MB (rss informativo: ${RSS_KB:-MISSING}KB)" "[ '${FOOT_KB:-999999}' -le 40960 ]"
check "cpu ${CPU:-MISSING}% ≤ 0.5%" "python3 -c \"exit(0 if float('${CPU:-99}'.replace(',','.')) <= 0.5 else 1)\""

say "concluído: $FAILURES falha(s)"
[ "$FAILURES" = "0" ] && exit 0 || exit 1
