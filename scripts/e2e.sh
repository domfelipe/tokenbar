#!/bin/bash
# E2E F2: corpus sintético + mock server (Codex/Z.ai) → app real com os 4
# providers (C/X/G/Z) → menu bar correto, live update, degradação graciosa e
# orçamento de recursos. Prova do Goal E2E: todos os checks PASS + exit 0.
#
# Verdade de referência (padrão F1): selfcheck — a MESMA pipeline do app sobre
# o MESMO corpus no MESMO dia — para os providers locais (C/G). Para os
# API-driven (X/Z) a verdade é o próprio mock: percentuais sintéticos fixos
# (Codex 42%, Z.ai 81%) que o check exige verbatim.
#
# Degradação (spec §5): 500 persistente → selfcheck tokeniza "http"; mock morto
# → app segue vivo (heartbeat continua via providers locais) e selfcheck
# diagnostica "network". NÃO há retry storm: o mock loga cada request com o
# header Authorization e as credenciais do APP são tokens fake distintos das do
# SELFcheck — o contador atribui cada request e prova que o app não fez nada
# além do burst inicial (≤ 4 na vida do mock) e que o pico por janela
# deslizante de 10 s é ≤ 2 (backoff ×2 a partir de 5 min torna storm
# estruturalmente impossível).
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/tokenbar-e2e.XXXXXX)"
CORPUS="$TMP/corpus"                 # Claude (genfixtures, --poison)
CODEX_DIR="$TMP/codex-sessions"      # vazio: X vem só da API (sem scan local)
GEMINI_DIR="$TMP/gemini"             # sessão sintética do Gemini CLI
CRED="$TMP/cred"
STATE="$TMP/state"
MOCK_MODE="$TMP/mock-mode"           # "ok" (default) | "500" — usado pelo RT/E2E
MOCK_LOG="$TMP/mock-requests.log"    # "<epoch> <path> <Authorization>" por request
MOCK_PORT_FILE="$TMP/mock-port"
mkdir -p "$STATE" "$CRED" "$CODEX_DIR" "$GEMINI_DIR/tmp/projeto-e2e/chats"
FAILURES=0
say() { echo "[e2e] $*"; }
check() {  # check <nome> <condição shell>
  if eval "$2"; then say "PASS: $1"; else say "FAIL: $1"; FAILURES=$((FAILURES+1)); fi
}
json_field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))$2)" "$1" 2>/dev/null || echo MISSING; }
: > "$MOCK_LOG"

say "TMP=$TMP"

# ---------------------------------------------------------------------------
# 1. Mock server (python3 http.server + handler JSON embutido): serve as
#    rotas canônicas da spec F2 com shapes sintéticos — Codex `wham/usage`
#    (§1.3, primary 42% / secondary 7%, reset_at em SEGUNDOS) e Z.ai
#    `quota/limit` (§2.3, success/code válidos, TOKENS_LIMIT 5h 81% e
#    semanal 34%, nextResetTime em MILISSEGUNDOS). Loga cada request (com o
#    header Authorization — fixtures são fake, nada real p/ vazar) e obedece
#    o modo do arquivo $MOCK_MODE (200 sintético | 500 p/ teste de storm).
# ---------------------------------------------------------------------------
python3 - "$TMP" <<'PYEOF' &
import http.server, json, sys, time, os

tmp = sys.argv[1]
log_path = os.path.join(tmp, "mock-requests.log")
mode_path = os.path.join(tmp, "mock-mode")
port_path = os.path.join(tmp, "mock-port")

CODEX = {
    "account_id": "fake-account-e2e",
    "plan_type": "plus",
    "rate_limit": {
        "primary_window":   {"used_percent": 42, "reset_at": 9999999999, "limit_window_seconds": 18000},
        "secondary_window": {"used_percent": 7,  "reset_at": 9999999999, "limit_window_seconds": 604800},
    },
    "credits": {"has_credits": False, "unlimited": False, "balance": None},
}
ZAI = {
    "success": True, "code": 200, "msg": "",
    "data": {
        "planName": "GLM Coding Plan (e2e)",
        "limits": [
            {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 81,
             "usage": 100000, "currentValue": 81000, "remaining": 19000,
             "nextResetTime": 9999999999999, "usageDetails": []},
            {"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 34,
             "usage": 1000000, "currentValue": 340000, "remaining": 660000,
             "nextResetTime": 9999999999999, "usageDetails": []},
        ],
    },
}

class Handler(http.server.BaseHTTPRequestHandler):
    def _log(self, path):
        with open(log_path, "a") as f:
            f.write("%.3f %s %s\n" % (time.time(), path, self.headers.get("Authorization", "-")))

    def do_GET(self):
        self._log(self.path)
        try:
            mode = open(mode_path).read().strip()
        except OSError:
            mode = "ok"
        if mode == "500":
            self.send_response(500)
            self.end_headers()
            return
        if "wham/usage" in self.path:
            body = json.dumps(CODEX).encode()
        elif "quota/limit" in self.path:
            body = json.dumps(ZAI).encode()
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # silencia o log padrão (o nosso é o arquivo)
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_path, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PYEOF
MOCK_PID=$!
for _ in $(seq 1 50); do [ -s "$MOCK_PORT_FILE" ] && break; sleep 0.1; done
PORT="$(cat "$MOCK_PORT_FILE" 2>/dev/null || echo 0)"
trap 'kill "$APP_PID" "$MOCK_PID" 2>/dev/null || true; sleep 0.3; rm -rf "$TMP"' EXIT
say "mock em 127.0.0.1:$PORT (pid $MOCK_PID)"

check "mock no ar: wham/usage 200 com rate_limit.primary_window" \
  "curl -s --max-time 5 \"http://127.0.0.1:$PORT/backend-api/wham/usage\" | python3 -c 'import json,sys;d=json.load(sys.stdin);exit(0 if d[\"rate_limit\"][\"primary_window\"][\"used_percent\"]==42 else 1)'"
check "mock no ar: quota/limit 200 com success=true" \
  "curl -s --max-time 5 \"http://127.0.0.1:$PORT/api/monitor/usage/quota/limit\" | python3 -c 'import json,sys;d=json.load(sys.stdin);exit(0 if d[\"success\"] and d[\"code\"]==200 else 1)'"

# ---------------------------------------------------------------------------
# 2. Corpora sintéticos + credenciais fake (NUNCA reais — spec §9).
# ---------------------------------------------------------------------------
say "gerando corpus Claude + sessão Gemini + credenciais fake"
swift run -c release genfixtures --out "$CORPUS" --sessions 4 --lines 150 --seed 7 --poison >/dev/null

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
cat > "$GEMINI_DIR/tmp/projeto-e2e/chats/session-e2e.jsonl" <<EOF
{"kind":"main","sessionId":"fake-session-e2e","projectHash":"projeto-e2e","startTime":"$NOW_ISO","lastUpdated":"$NOW_ISO"}
{"type":"gemini","id":"fake-gem-e2e-1","timestamp":"$NOW_ISO","content":"resposta fake","model":"gemini-2.5-flash","tokens":{"input":100,"output":54,"cached":0,"thoughts":39,"tool":0,"total":193}}
EOF

cat > "$CRED/codex-auth.json" <<'EOF'
{"OPENAI_API_KEY": null, "auth_mode": "chatgpt",
 "tokens": {"access_token": "fake-token-e2e", "account_id": "fake-account-e2e",
            "id_token": "fake-jwt-e2e", "refresh_token": "fake-refresh-e2e"}}
EOF
cat > "$CRED/zai-config.json" <<'EOF'
{"provider": {"builtin:zai-coding-plan":
  {"options": {"apiKey": "fake-api-key-e2e", "baseURL": "https://api.z.ai/api/anthropic"}}}}
EOF
# Gêmeas com token DISTINTO para o selfcheck: o log do mock registra o header
# Authorization, então o contador consegue atribuir cada request ao APP (tokens
# acima) ou ao SELFcheck (tokens -selfcheck) — é o que torna a prova de retry
# storm por atribuição possível (curl não manda Authorization e já sai de fora).
cat > "$CRED/codex-auth-selfcheck.json" <<'EOF'
{"OPENAI_API_KEY": null, "auth_mode": "chatgpt",
 "tokens": {"access_token": "fake-token-e2e-selfcheck", "account_id": "fake-account-e2e",
            "id_token": "fake-jwt-e2e", "refresh_token": "fake-refresh-e2e"}}
EOF
cat > "$CRED/zai-config-selfcheck.json" <<'EOF'
{"provider": {"builtin:zai-coding-plan":
  {"options": {"apiKey": "fake-api-key-e2e-selfcheck", "baseURL": "https://api.z.ai/api/anthropic"}}}}
EOF

# Env comum app/selfcheck: TODOS os caminhos apontam p/ o TMP (nunca os reais
# de ~/.codex, ~/.gemini, ~/.zcode — o e2e não pode depender nem tocar a
# máquina; o scan do Codex real ~10 GB tornaria o teste inviável). O SUPPORT
#_DIR isola cursores/ledger do App Support real: sem ele, corpora descartáveis
# acumulam entradas no store real e o snapshot do dia as ressuscita entre runs
# (achado P1 do e2e final da T8).
COMMON_ENV=(
  TOKENBAR_CODEX_API="http://127.0.0.1:$PORT"
  TOKENBAR_ZAI_API="http://127.0.0.1:$PORT"
  TOKENBAR_SUPPORT_DIR="$TMP/support"
  TOKENBAR_CODEX_DIR="$CODEX_DIR"
  TOKENBAR_CODEX_AUTH="$CRED/codex-auth.json"
  TOKENBAR_ZAI_CONFIG="$CRED/zai-config.json"
  TOKENBAR_ZAI_AUTH="$CRED/credentials-ausentes.json"
  TOKENBAR_GEMINI_DIR="$GEMINI_DIR"
  TOKENBAR_CLAUDE_DIR="$CORPUS"
)
mkdir -p "$TMP/support"
# Selfcheck usa as credenciais "-selfcheck" (mesmo shape, token distinto) —
# ver comentário das fixtures; todo o mais é idêntico ao env do app.
SELF_ENV=(
  "${COMMON_ENV[@]}"
  TOKENBAR_CODEX_AUTH="$CRED/codex-auth-selfcheck.json"
  TOKENBAR_ZAI_CONFIG="$CRED/zai-config-selfcheck.json"
)

# ---------------------------------------------------------------------------
# 3. Verdade de referência: selfcheck v2 com o mock NO AR (mesma pipeline do
#    app; exit code não é sinal — SDD-9 — só o parse do JSON importa).
# ---------------------------------------------------------------------------
SELFCHECK="$(env "${SELF_ENV[@]}" swift run -c release tokenbar selfcheck "$CORPUS")"
say "selfcheck (mock no ar): $SELFCHECK"
SC_TEXT="$(echo "$SELFCHECK" | python3 -c "import json,sys;print(json.load(sys.stdin)['menuBarText'])")"
check "selfcheck v2 mostra os API-driven com % do mock (X:42% e Z:81% em '$SC_TEXT')" \
  "echo \"\$SC_TEXT\" | grep -q 'X:42%' && echo \"\$SC_TEXT\" | grep -q 'Z:81%'"
check "selfcheck v2 mostra os locais (C e G) em '$SC_TEXT'" \
  "echo \"\$SC_TEXT\" | grep -qE 'C:[0-9]' && echo \"\$SC_TEXT\" | grep -q 'G:193'"

# ---------------------------------------------------------------------------
# 3.5 Erro HTTP persistente ANTES do app subir: mock em modo 500 → selfcheck
#     diagnostica o token "http" nos API-driven (mesmo caminho de
#     UsageHTTPError.http que o app pega sob 500). Volta p/ "ok" em seguida
#     para o burst inicial do app ser 200 — o contador de requests (seção 7)
#     precisa distinguir exatamente quem pediu o quê.
# ---------------------------------------------------------------------------
echo 500 > "$MOCK_MODE"
SELFCHECK_500="$(env "${SELF_ENV[@]}" swift run -c release tokenbar selfcheck "$CORPUS")"
say "selfcheck (mock 500): $SELFCHECK_500"
check "selfcheck sob 500: erro tokenizado 'http' em codex e zai" \
  "echo \"\$SELFCHECK_500\" | python3 -c 'import json,sys;p=json.load(sys.stdin)[\"providers\"];exit(0 if p[\"codex\"].get(\"error\")==\"http\" and p[\"zai\"].get(\"error\")==\"http\" else 1)'"
echo ok > "$MOCK_MODE"

# ---------------------------------------------------------------------------
# 4. App real com os mesmos overrides — MESMO caminho de corpus do selfcheck.
# ---------------------------------------------------------------------------
./scripts/make-app.sh release >/dev/null
env "${COMMON_ENV[@]}" TOKENBAR_E2E_DIR="$STATE" \
  "build/TokenBar.app/Contents/MacOS/tokenbar" &
APP_PID=$!

# 5. Menu bar correto em ≤ 30 s (heartbeat é escrito no primeiro ingest).
for _ in $(seq 1 30); do
  [ -f "$STATE/state.json" ] && break
  sleep 1
done
check "heartbeat criado em 30s" "[ -f '$STATE/state.json' ]"
APP_TEXT="$(json_field "$STATE/state.json" "['menuBarText']")"
check "menu bar text igual ao selfcheck ('$APP_TEXT' == '$SC_TEXT')" "[ '$APP_TEXT' = '$SC_TEXT' ]"
check "heartbeat: percent API-driven do mock (codex=42, zai=81)" \
  "[ \"\$(json_field '$STATE/state.json' \"['providers']['codex']['percent']\")\" = '42' ] && [ \"\$(json_field '$STATE/state.json' \"['providers']['zai']['percent']\")\" = '81' ]"
check "heartbeat v2: authState ok e fetchedAt fresco nos API-driven" \
  "[ \"\$(json_field '$STATE/state.json' \"['providers']['codex']['authState']\")\" = 'ok' ] && [ \"\$(json_field '$STATE/state.json' \"['providers']['zai']['authState']\")\" = 'ok' ] && [ \"\$(json_field '$STATE/state.json' \"['providers']['zai']['fetchedAt']\")\" != '1970-01-01T00:00:00Z' ]"

# Baseline de requests p/ o check de retry storm: tudo que o APP pedir além
# do burst inicial (1 por provider) na janela inteira até a degradação conta.
BASE_REQ="$(wc -l < "$MOCK_LOG" | tr -d ' ')"

# 6. Live update: append de linha válida → FSEvents → debounce 3 s → heartbeat
#    em ≤ 10 s (Δ +333) — padrão F1. Heartbeat v2: total do provider vive em
#    providers.claude.todayTokens (não mais no topo, como na F1).
BEFORE_TOTAL="$(json_field "$STATE/state.json" "['providers']['claude']['todayTokens']")"
LINE='{"type":"assistant","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'","message":{"usage":{"input_tokens":111,"output_tokens":222}}}'
echo "$LINE" >> "$(ls "$CORPUS"/session-0/*.jsonl | head -1)"
UPDATED=0
for _ in $(seq 1 10); do
  sleep 1
  AFTER_TOTAL="$(json_field "$STATE/state.json" "['providers']['claude']['todayTokens']")"
  if [ "$AFTER_TOTAL" != "MISSING" ] && [ "$AFTER_TOTAL" -ge "$((BEFORE_TOTAL + 333))" ] 2>/dev/null; then
    UPDATED=1; break
  fi
done
check "live update após append (Δ=+333 observado)" "[ '$UPDATED' = '1' ]"

# ---------------------------------------------------------------------------
# 7. Degradação: mock MORRE no meio do ciclo → app segue vivo (heartbeat
#    continua pelos providers locais), sem crash e SEM retry storm. Duas provas
#    com o contador do mock (seção 1 loga cada request): o app não fez request
#    além do burst inicial na vida inteira do mock, e o pico por janela
#    deslizante de 10 s fica ≤ 6 (o caminho de erro PERSISTENTE 500 já foi
#    exercitado na seção 3.5 via selfcheck — o Red Team caso 3 repete com o
#    app rodando ~11 min no modo 500 do MESMO mock).
# ---------------------------------------------------------------------------
kill -9 "$MOCK_PID" 2>/dev/null
wait "$MOCK_PID" 2>/dev/null
LINE2='{"type":"assistant","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'","message":{"usage":{"input_tokens":74,"output_tokens":148}}}'
echo "$LINE2" >> "$(ls "$CORPUS"/session-1/*.jsonl | head -1)"
DEGRADED=0
LAST_UPDATED="$(json_field "$STATE/state.json" "['updatedAt']")"
for _ in $(seq 1 10); do
  sleep 1
  NEW_TOTAL="$(json_field "$STATE/state.json" "['providers']['claude']['todayTokens']")"
  NEW_UPDATED="$(json_field "$STATE/state.json" "['updatedAt']")"
  if [ "$NEW_TOTAL" != "MISSING" ] && [ "$NEW_TOTAL" -ge "$((AFTER_TOTAL + 222))" ] 2>/dev/null \
     && [ "$NEW_UPDATED" != "$LAST_UPDATED" ]; then
    DEGRADED=1; break
  fi
done
check "degradação: mock morto → app vivo e heartbeat continua (Δ=+222, updatedAt avança)" \
  "[ '$DEGRADED' = '1' ] && kill -0 $APP_PID 2>/dev/null"
APP_REQ=$(( $(wc -l < "$MOCK_LOG" | tr -d ' ') - BASE_REQ ))
check "sem retry storm: $APP_REQ request(s) do app além do burst inicial (≤ 3)" \
  "[ '$APP_REQ' -le 3 ]"

# Contador do mock, atribuído por credencial: linhas com o Authorization do APP
# (os selfchecks usam tokens "-selfcheck" e o curl não manda header — saem da
# conta). Duas provas de backoff: o app fez ≤ 4 requests na vida INTEIRA do
# mock (esperado 2 = burst inicial, 1 por provider) e o pico em qualquer janela
# deslizante de 10 s é ≤ 2 (um storm real apareceria como dezenas por segundo —
# o backoff ×2 parte de 5 min, então cadência alta é estruturalmente impossível).
read -r APP_TOTAL BURST_10S <<EOF2
$(python3 - "$MOCK_LOG" <<'PYEOF'
import sys
app_auth = ("Bearer fake-token-e2e", "Bearer fake-api-key-e2e")
ts = []
for line in open(sys.argv[1]):
    parts = line.split(None, 2)
    if len(parts) >= 3 and parts[2].strip() in app_auth:
        ts.append(float(parts[0]))
ts.sort()
best = j = 0
for i in range(len(ts)):
    while ts[i] - ts[j] > 10.0:
        j += 1
    best = max(best, i - j + 1)
print(len(ts), best)
PYEOF
)
EOF2
check "requests do APP na vida do mock atribuídos pelo token: ${APP_TOTAL:-99} (≤ 4; esperado 2 = burst)" \
  "[ '${APP_TOTAL:-99}' -le 4 ]"
check "requests/10s do APP limitado pelo backoff: pico ${BURST_10S:-99} na janela deslizante de 10s (≤ 2)" \
  "[ '${BURST_10S:-99}' -le 2 ]"

# Diagnóstico da degradação (selfcheck v2 com o mock MORTO): erro tokenizado
# "network" por provider — nunca mensagem crua com URL (spec §9).
SELFCHECK_DOWN="$(env "${SELF_ENV[@]}" swift run -c release tokenbar selfcheck "$CORPUS")"
say "selfcheck (mock morto): $SELFCHECK_DOWN"
check "selfcheck pós-morte: erro tokenizado 'network' em codex e zai" \
  "echo \"\$SELFCHECK_DOWN\" | python3 -c 'import json,sys;p=json.load(sys.stdin)[\"providers\"];exit(0 if p[\"codex\"].get(\"error\")==\"network\" and p[\"zai\"].get(\"error\")==\"network\" else 1)'"

# ---------------------------------------------------------------------------
# 8. Orçamento de recursos após 60 s ocioso (spec §7: CPU < 0,5%; RAM ≤ 40 MB).
#    Mesma base da F1: phys_footprint (vmmap), não o rss do ps.
# ---------------------------------------------------------------------------
say "aguardando 60s para medir recursos..."
sleep 60
FOOT_RAW="$(vmmap --summary "$APP_PID" 2>/dev/null | awk '/Physical footprint:/ {print $3; exit}')"
FOOT_KB="$(python3 -c "
import sys
v=sys.argv[1]; n=float(v[:-1]); u=v[-1].upper()
print(int(n*{'K':1,'M':1024,'G':1024**2}.get(u,1)))" "${FOOT_RAW:-0K}" 2>/dev/null || echo 999999)"
RSS_KB="$(ps -o rss= -p $APP_PID | tr -d ' ')"  # informativo (compartilhado), não é o gate
CPU="$(ps -o %cpu= -p $APP_PID | tr -d ' ')"
check "processo vivo (sem crash, mock morto há >60s)" "kill -0 $APP_PID"
check "memória própria (phys_footprint) ${FOOT_RAW:-MISSING} ≤ 40MB (rss informativo: ${RSS_KB:-MISSING}KB)" "[ '${FOOT_KB:-999999}' -le 40960 ]"
check "cpu ${CPU:-MISSING}% ≤ 0.5%" "python3 -c \"exit(0 if float('${CPU:-99}'.replace(',','.')) <= 0.5 else 1)\""

say "concluído: $FAILURES falha(s)"
[ "$FAILURES" = "0" ] && exit 0 || exit 1
