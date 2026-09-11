#!/bin/bash
# E2E v5 (F5): corpus sintético + mock server (Codex/Z.ai/OpenRouter) → app
# real com os providers do wiring (C/X/G/Z + os 6 F5; OpenRouter EXERCITADO de
# verdade via override TOKENBAR_OPENROUTER_API) → menu bar correto, live
# update, degradação graciosa, orçamento de recursos (COM o banco SQLite
# aberto) + persistência + migração + painel rico/multi-conta (heartbeat v5:
# credits real + alertsStatus honesto, ADITIVOS) + ALERTA DISPARADO de verdadE:
# `alerts:enabled` plantado no banco antes do 1º launch e o app rodando com o
# GATEWAY DE CAPTURA (TOKENBAR_E2E_ALERTS_CAPTURE — mesma fronteira
# NotificationSending, render/identifier do gateway real; NUNCA o
# UNUserNotificationCenter real no e2e, ruling F5-NOTIF). Dedupe provado no
# relaunch: estado persistido no banco não re-dispara e erro de rede não
# inventa alerta. Todas as esperas são POR CONTEÚDO (arquivo/valor esperado,
# nunca sleep cego — os sleeps fixos existentes são janelas de MEDIÇÃO da
# spec §7).
#
# Verdade de referência (padrão F1): selfcheck — a MESMA pipeline do app sobre
# o MESMO corpus no MESMO dia — para os providers locais (C/G). Para os
# API-driven (X/Z/O) a verdade é o próprio mock: valores sintéticos fixos
# (Codex 42%, Z.ai 81%, OpenRouter saldo 62.80/janela 49%) que o check exige
# verbatim.
#
# Degradação (spec §5): 500 persistente → selfcheck tokeniza "http"; mock morto
# → app segue vivo (heartbeat continua via providers locais) e selfcheck
# diagnostica "network". NÃO há retry storm: o mock loga cada request com o
# header Authorization e as credenciais do APP são tokens fake distintos das do
# SELFcheck — o contador atribui cada request e prova que o app não fez nada
# além do burst inicial (esperado 4: 1 codex + 1 zai + 2 openrouter
# credits+key) e que o pico por janela deslizante de 10 s é ≤ 4 (backoff ×2 a
# partir de 5 min torna storm estruturalmente impossível).
#
# Persistência (F3): o app persiste eventos em $SUPPORT/tokenbar.sqlite e o
# heartbeat v3 expõe history7d. Cenários novos:
#   (a) `tokenbar history` (mesmo banco, mesma query da UI) consistente com o
#       heartbeat (todayTokens == série diária == history7d) em JSON e CSV;
#   (b) migração: cursors.json legado F2 na support dir (sem DB — extraído do
#       banco da fase 1, byte-fiel ao que o JSONFileOffsetStore gravava) → o
#       app migra (rename .migrated), NÃO re-escaneia (ledger restaurado via
#       stamp de cursores → totais preservados, não dobrados) e NÃO retroage
#       no banco (backfill fora de escopo); evento NOVO pós-migração persiste
#       exatamente 1× — migration re-run (3º launch) é idempotente (Red Team
#       caso 3);
#   (c) selfcheck v3: com o DB do próprio tmp aberto, history7d presente com
#       os tokens do corpus (pin do fix do review T4).
# Pacing/mês (F4, aditivo no heartbeat v3):
#   (d) sonda selfcheck com sessões Codex sintéticas em 2 dias: pacing PRESENTE
#       (projectedFraction == fração da janela crítica 42%; .session não
#       projeta sobre agregados diários → flat, sem esgotamento inventado) —
#       enquanto Z.ai (janela 81% com reset, ZERO histórico diário) e Claude
#       (sem janela) OMITEM o campo — a honestidade "<2 pontos → sem chute"
#       provada nos dois sentidos;
#   (e) app real: monthTokens/monthCostUsd do claude consistentes com o
#       history7d do MESMO payload (30d ⊇ 7d ⊇ corpus < 48h → iguais).
# Multi-conta (F4): contas CLAUDE com dir própria (ingest local — ZERO request
# extra ao mock; as provas de rede da seção 7 já fecharam): registro
# programático via sqlite3 (fonte do ciclo é o registry, guard de overlap é da
# UI — Red Team caso 5), agregado = soma exata sem duplicação, toggle ativa
# tira a conta do ciclo, frota de 30 contas coberta num ciclo só dentro do
# orçamento, heartbeat SEM paths/ids de conta (higiene §9) e remoção devolve
# o display ao layout F2.
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/tokenbar-e2e.XXXXXX)"
CORPUS="$TMP/corpus"                 # Claude (genfixtures, --poison)
CODEX_DIR="$TMP/codex-sessions"      # vazio: X vem só da API (sem scan local)
GEMINI_DIR="$TMP/gemini"             # sessão sintética do Gemini CLI
CRED="$TMP/cred"
STATE="$TMP/state"
SUPPORT="$TMP/support"               # DB + cursores (TOKENBAR_SUPPORT_DIR)
MOCK_MODE="$TMP/mock-mode"           # "ok" (default) | "500" — usado pelo RT/E2E
MOCK_LOG="$TMP/mock-requests.log"    # "<epoch> <path> <Authorization>" por request
MOCK_PORT_FILE="$TMP/mock-port"
mkdir -p "$STATE" "$SUPPORT" "$CRED" "$CODEX_DIR" "$GEMINI_DIR/tmp/projeto-e2e/chats"
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
#    rotas canônicas da spec F2 + OpenRouter (F5) com shapes sintéticos —
#    Codex `wham/usage` (§1.3, primary 42% / secondary 7%, reset_at em
#    SEGUNDOS), Z.ai `quota/limit` (§2.3, success/code válidos, TOKENS_LIMIT
#    5h 81% e semanal 34%, nextResetTime em MILISSEGUNDOS) e OpenRouter
#    `/credits` (100.00 − 37.20 → saldo 62.80) + `/key` (limit 50,
#    limit_remaining 25.5 → janela 49%). Loga cada request (com o header
#    Authorization — fixtures são fake, nada real p/ vazar) e obedece o modo
#    do arquivo $MOCK_MODE (200 sintético | 500 p/ teste de storm).
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
# OpenRouter (F5): /credits (saldo 62.80) + /key (janela 49% da key).
OR_CREDITS = {"data": {"total_credits": 100.00, "total_usage": 37.20}}
OR_KEY = {"data": {"limit": 50, "limit_remaining": 25.5, "usage": 37.2,
                   "usage_daily": 1.5, "usage_weekly": 8.25, "usage_monthly": 30.0,
                   "limit_reset": "monthly"}}

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
        elif self.path.endswith("/credits"):
            body = json.dumps(OR_CREDITS).encode()
        elif self.path.endswith("/key"):
            body = json.dumps(OR_KEY).encode()
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
check "mock no ar: /credits 200 com saldo 62.80" \
  "curl -s --max-time 5 \"http://127.0.0.1:$PORT/credits\" | python3 -c 'import json,sys;d=json.load(sys.stdin)[\"data\"];exit(0 if d[\"total_credits\"]-d[\"total_usage\"]==62.8 else 1)'"
check "mock no ar: /key 200 com limit 50" \
  "curl -s --max-time 5 \"http://127.0.0.1:$PORT/key\" | python3 -c 'import json,sys;d=json.load(sys.stdin)[\"data\"];exit(0 if d[\"limit\"]==50 and d[\"limit_remaining\"]==25.5 else 1)'"

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
# (achado P1 do e2e final da T8). F5: OpenRouter exercitado via mock (override
# TOKENBAR_OPENROUTER_API + key no env — 1 key = 1 conta) e o GATEWAY DE
# CAPTURA de alertas (a captura grava cada AlertEvent como linha JSON — o app
# NUNCA toca no UNUserNotificationCenter no e2e). HERMETICIDADE DOS 6 NOVOS
# PROVIDERS (achado do run 3: a máquina de execução tinha Cursor/Grok reais →
# U:19%/K:11% no texto e REQUEST REAL com credencial real!): as descobertas de
# credencial apontam para arquivo INEXISTENTE no lab e as env-only são
# NEUTRALIZADAS com vazio — todos os 6 degradam `.missing` e saem da barra
# (nunca rede real, nunca máquina-dependente).
COMMON_ENV=(
  TOKENBAR_CODEX_API="http://127.0.0.1:$PORT"
  TOKENBAR_ZAI_API="http://127.0.0.1:$PORT"
  TOKENBAR_OPENROUTER_API="http://127.0.0.1:$PORT"
  OPENROUTER_API_KEY="fake-openrouter-e2e"
  TOKENBAR_SUPPORT_DIR="$SUPPORT"
  TOKENBAR_CODEX_DIR="$CODEX_DIR"
  TOKENBAR_CODEX_AUTH="$CRED/codex-auth.json"
  TOKENBAR_ZAI_CONFIG="$CRED/zai-config.json"
  TOKENBAR_ZAI_AUTH="$CRED/credentials-ausentes.json"
  TOKENBAR_GEMINI_DIR="$GEMINI_DIR"
  TOKENBAR_CLAUDE_DIR="$CORPUS"
  TOKENBAR_E2E_ALERTS_CAPTURE="$STATE/alerts.jsonl"
  TOKENBAR_CURSOR_DB="$CRED/credentials-ausentes.json"
  TOKENBAR_GROK_AUTH="$CRED/credentials-ausentes.json"
  TOKENBAR_ANTIGRAVITY_CREDS="$CRED/credentials-ausentes.json"
  DEEPSEEK_API_KEY=""
  ALIBABA_CODING_PLAN_API_KEY=""
  ALIBABA_QWEN_API_KEY=""
  DASHSCOPE_API_KEY=""
)
mkdir -p "$TMP/support"
# Selfcheck usa as credenciais "-selfcheck" (mesmo shape, token distinto) —
# ver comentário das fixtures; todo o mais é idêntico ao env do app.
SELF_ENV=(
  "${COMMON_ENV[@]}"
  TOKENBAR_CODEX_AUTH="$CRED/codex-auth-selfcheck.json"
  TOKENBAR_ZAI_CONFIG="$CRED/zai-config-selfcheck.json"
  OPENROUTER_API_KEY="fake-openrouter-e2e-selfcheck"
)

# ---------------------------------------------------------------------------
# 2.5 (F5 T7) SEED LAUNCH: o app é construído e lançado UMA VEZ SEM alertas —
#      é ele quem cria o banco (migrations na abertura; o CLI `history` só lê
#      banco existente). Kill, PLANTA `alerts:enabled=true` na tabela settings
#      (substitute honesto do toggle da Settings — ruling F5-NOTIF: o e2e
#      NUNCA pede permissão real), e o launch PRINCIPAL (§4) sobe com o
#      AlertEngine já ligado e o gateway de captura provando os disparos.
# ---------------------------------------------------------------------------
say "seed launch (build + 1º launch sem alertas, só p/ criar o banco)"
./scripts/make-app.sh release >/dev/null
# Regressão do fix do hang via `open` (F3/F4): os bundles SPM (.copy) precisam
# estar dentro do .app — sem eles Bundle.module pendura a main thread em
# NSBundle URLForResource quando lançado via LaunchServices.
for b in GRDB_GRDB TokenBar_TokenBarCore TokenBar_TokenBarUI; do
  check "bundle de recursos no .app: $b.bundle em Contents/Resources" \
    "[ -d 'build/TokenBar.app/Contents/Resources/$b.bundle' ]"
done
env "${COMMON_ENV[@]}" TOKENBAR_E2E_DIR="$STATE" \
  "build/TokenBar.app/Contents/MacOS/tokenbar" &
SEED_PID=$!
SEED_OK=0
# Espera POR CONTEÚDO até o ÚLTIMO provider com dado publicar (openrouter 49%
# depois do Z no texto) — matar no meio da fila deixaria um request em voo
# contando na janela de 10 s do burst do launch principal (flake do run 2).
for _ in $(seq 1 30); do
  APP_TEXT_SEED="$(json_field "$STATE/state.json" "['menuBarText']" 2>/dev/null)"
  case "$APP_TEXT_SEED" in *Z:81*O:49*) SEED_OK=1 && break;; esac
  sleep 1
done
check "seed launch: app de pé e ciclo completo publicado em 30s (X/Z/O do mock no texto)" "[ '$SEED_OK' = '1' ]"
kill -9 "$SEED_PID" 2>/dev/null; wait "$SEED_PID" 2>/dev/null
SUPPORT_DB="$SUPPORT/tokenbar.sqlite"
SEED_TABLES="$(sqlite3 "$SUPPORT_DB" "SELECT COUNT(*) FROM settings" 2>/dev/null || echo ERR)"
check "seed: DB com tabela settings criada pelo app" "[ '$SEED_TABLES' != 'ERR' ]"
sqlite3 "$SUPPORT_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('alerts:enabled','true');"
SEED_PLANTED="$(sqlite3 "$SUPPORT_DB" "SELECT value FROM settings WHERE key='alerts:enabled'" 2>/dev/null)"
check "seed: alerts:enabled=true plantado no banco (substitute do toggle da Settings)" \
  "[ '$SEED_PLANTED' = 'true' ]"

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

# Cenário (c) F3: o selfcheck agora cria o próprio support dir → o DB dele
# abre → a ingest persiste o corpus e o heartbeat v3 traz history7d com custo
# computado (claude-sonnet-4-6 é precificado). O corpus tem eventos de até 24h
# no passado (podem cair no dia de ONTEM), então history7d (janela 7d) é
# ≥ todayTokens (só hoje) — a igualdade só valeria com tudo no mesmo dia.
# Pin do fix do review T4 (support dir inexistente → DB nunca abria).
check "selfcheck v3: history7d presente, tokens ≥ todayTokens > 0 e custo > 0" \
  "echo \"\$SELFCHECK\" | python3 -c '
import json,sys
p=json.load(sys.stdin)[\"providers\"][\"claude\"]
h=p.get(\"history7d\")
exit(0 if h and h[\"tokens\"]>=p[\"todayTokens\"]>0 and (h.get(\"costUsd\") or 0)>0 else 1)'"

# Hermeticidade dos providers F5 (achado do run 3): com as credenciais da
# MÁQUINA neutralizadas, cursor/grok/alibaba/antigravity/deepseek degradam
# `.missing` e NÃO entram no texto — o texto esperado é EXATAMENTE
# C/X/G/Z/O. Qualquer fragmento U:/K:/Q:/V:/D: = vazamento de máquina.
check "hermeticidade F5: texto é EXATAMENTE C X G Z O — sem fragmento de provider da máquina" \
  "echo \"\$SC_TEXT\" | grep -qE '^C:[0-9.]+[kM]? X:42% G:193 Z:81% O:49%$'"

# ---------------------------------------------------------------------------
# 3.1 (F4-d) Sonda de pacing: sessões Codex sintéticas em 2 DIAS (formato
#     rollout §1.5 — event_msg/token_count com last_token_usage) + Claude
#     VAZIO. O selfcheck roda com o mock NO AR, então a janela crítica do
#     codex é a session 42% do mock. Provas simétricas de honestidade do
#     PacingEngine:
#       - codex: 2 pontos diários + janela com fração → pacing PRESENTE; mas
#         janela .session não projeta sobre agregados diários → FLAT
#         (projectedFraction == 0.42, exhaustedIn/deficitPct null — nada de
#         esgotamento inventado);
#       - zai: tem fração 81% e resetsAt, mas ZERO histórico diário (api-only)
#         → pacing AUSENTE (<2 pontos → sem chute);
#       - claude: sem janela com fração → pacing AUSENTE.
#     O DB do selfcheck é o dele (/tmp/tokenbar-selfcheck) — o hwm de lá retém
#     os 2 dias entre rodadas; a sonda é estável (flat independe do dia).
# ---------------------------------------------------------------------------
PACING_DIR="$TMP/codex-pacing"
EMPTY_CLAUDE="$TMP/empty-claude"
mkdir -p "$PACING_DIR/$(date -u +%Y/%m/%d)" "$EMPTY_CLAUDE"
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
OLD_TS="$(date -u -v-24H +%Y-%m-%dT%H:%M:%S.000Z)"
cat > "$PACING_DIR/$(date -u +%Y/%m/%d)/rollout-pacing.jsonl" <<EOF
{"timestamp":"$OLD_TS","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":900,"output_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0}}}}
{"timestamp":"$NOW_TS","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":400,"output_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0}}}}
EOF
SC_PACING="$(env "${SELF_ENV[@]}" TOKENBAR_CODEX_DIR="$PACING_DIR" swift run -c release tokenbar selfcheck "$EMPTY_CLAUDE")"
say "selfcheck sonda pacing: $SC_PACING"
check "sonda pacing: codex COM 2 dias de histórico → pacing presente e FLAT (projectedFraction=0.42, sem esgotamento inventado)" \
  "echo \"\$SC_PACING\" | python3 -c '
import json,sys
p=json.load(sys.stdin)[\"providers\"][\"codex\"].get(\"pacing\")
exit(0 if p and p[\"projectedFraction\"]==0.42 and p[\"exhaustedIn\"] is None and p[\"deficitPct\"] is None else 1)'"
check "sonda pacing: zai COM fração+reset mas ZERO histórico diário → pacing AUSENTE (sem chute)" \
  "echo \"\$SC_PACING\" | python3 -c '
import json,sys
p=json.load(sys.stdin)[\"providers\"][\"zai\"]
exit(0 if p.get(\"pacing\") is None and p.get(\"percent\")==81 else 1)'"
check "sonda pacing: claude sem janela com fração → pacing AUSENTE" \
  "echo \"\$SC_PACING\" | python3 -c '
import json,sys
p=json.load(sys.stdin)[\"providers\"][\"claude\"]
exit(0 if p.get(\"pacing\") is None else 1)'"

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
#    (binário já construído no seed launch §2.5; alerts:enabled já plantado —
#    este launch sobe com o AlertEngine LIGADO e o gateway de captura ativo.)
# ---------------------------------------------------------------------------
env "${COMMON_ENV[@]}" TOKENBAR_E2E_DIR="$STATE" \
  "build/TokenBar.app/Contents/MacOS/tokenbar" &
APP_PID=$!

# 5. Menu bar correto em ≤ 30 s (heartbeat é escrito no primeiro ingest).
#    O publish acontece a CADA provider (o state.json surge com só o claude
#    já no meio do 1º ciclo), então a espera é pelo CONTEÚDO completo —
#    todos os providers com dado no payload (locais + API-driven + OpenRouter
#    F5, que entra na ordem alfabética DEPOIS do Z) — não pela existência do
#    arquivo.
for _ in $(seq 1 30); do
  APP_TEXT_NOW="$(json_field "$STATE/state.json" "['menuBarText']" 2>/dev/null)"
  case "$APP_TEXT_NOW" in *G:193*Z:81*O:49*) break;; esac
  sleep 1
done
check "heartbeat criado em 30s" "[ -f '$STATE/state.json' ]"
APP_TEXT="$(json_field "$STATE/state.json" "['menuBarText']")"
check "menu bar text igual ao selfcheck ('$APP_TEXT' == '$SC_TEXT')" "[ '$APP_TEXT' = '$SC_TEXT' ]"
check "heartbeat: percent API-driven do mock (codex=42, zai=81, openrouter=49)" \
  "[ \"\$(json_field '$STATE/state.json' \"['providers']['codex']['percent']\")\" = '42' ] && [ \"\$(json_field '$STATE/state.json' \"['providers']['zai']['percent']\")\" = '81' ] && [ \"\$(json_field '$STATE/state.json' \"['providers']['openrouter']['percent']\")\" = '49' ]"
check "heartbeat v2: authState ok e fetchedAt fresco nos API-driven" \
  "[ \"\$(json_field '$STATE/state.json' \"['providers']['codex']['authState']\")\" = 'ok' ] && [ \"\$(json_field '$STATE/state.json' \"['providers']['zai']['authState']\")\" = 'ok' ] && [ \"\$(json_field '$STATE/state.json' \"['providers']['zai']['fetchedAt']\")\" != '1970-01-01T00:00:00Z' ]"

# F5 (heartbeat v5, ADITIVO): provider NOVO exercitado de verdade no app real
# — OpenRouter com janela da key (49%) e CREDITS do snapshot (saldo 62.80 do
# mock); providers sem credits não têm a chave (nada fake).
check "heartbeat v5: credits REAL do openrouter (remaining 62.8 = 100 − 37.2 do mock)" \
  "python3 -c '
import json,sys
p=json.load(open(sys.argv[1]))[\"providers\"][\"openrouter\"]
c=p.get(\"credits\") or {}
exit(0 if c.get(\"remaining\")==62.8 and c.get(\"unlimited\") is False else 1)' '$STATE/state.json'"
check "heartbeat v5: codex/zai SEM credits no payload (mock devolve balance null — chave ausente, honesto)" \
  "python3 -c '
import json,sys
p=json.load(open(sys.argv[1]))[\"providers\"]
exit(0 if \"credits\" not in p[\"codex\"] and \"credits\" not in p[\"zai\"] else 1)' '$STATE/state.json'"

# F5 (T7): ALERTA DISPARADO no 1º ciclo com `alerts:enabled` plantado — o
# gateway de captura grava cada AlertEvent como linha JSON. Esperado: EXATOS 2
# disparos (zai session 81% cruza 50 e 75; codex 42% e openrouter 49% ficam
# abaixo; weekly 34% idem) com o MESMO render EN do gateway real. Estado
# honesto no heartbeat: alertsStatus 'enabled' (gateway captor é granted).
ALERT_OK=0
for _ in $(seq 1 15); do
  [ -f "$STATE/alerts.jsonl" ] && [ "$(wc -l < "$STATE/alerts.jsonl" | tr -d ' ')" = "2" ] && ALERT_OK=1 && break
  sleep 1
done
check "F5 alerts: EXATOS 2 disparos no 1º ciclo (zai cruza t50+t75 — nada abaixo dispara)" "[ '$ALERT_OK' = '1' ]"
check "F5 alerts: render EN do gateway real (títulos 'Z.ai · 50/75% of session window used')" \
  "grep -q '\"title\":\"Z.ai · 50% of session window used\"' '$STATE/alerts.jsonl' && grep -q '\"title\":\"Z.ai · 75% of session window used\"' '$STATE/alerts.jsonl'"
check "F5 alerts: identifiers de dedupe por (provider,conta,janela,causa) — zai.local.session.t50/t75" \
  "grep -q 'tokenbar.alert.zai.local.session.t50' '$STATE/alerts.jsonl' && grep -q 'tokenbar.alert.zai.local.session.t75' '$STATE/alerts.jsonl'"
check "F5 alerts: body com countdown real do reset ('Resets in …', nada inventado)" \
  "grep -q '\"body\":\"Resets in ' '$STATE/alerts.jsonl'"
check "F5 alerts: alertsStatus 'enabled' no heartbeat (gateway granted — estado honesto)" \
  "[ \"\$(json_field '$STATE/state.json' \"['alertsStatus']\")\" = 'enabled' ]"

# 5.1 (F4-e) Campos ADITIVOS do heartbeat v3 no app real: monthTokens/
#     monthCostUsd do claude presentes e consistentes com o history7d do
#     MESMO payload (corpus < 48h → janela 30d == janela 7d); codex — que tem
#     fração do mock mas NÃO tem histórico diário no app (sessions vazio) —
#     OMITE pacing (a omissão honesta provada também no payload do app).
check "heartbeat v4: claude monthTokens/monthCostUsd consistentes com history7d (30d == 7d com corpus < 48h)" \
  "python3 -c '
import json,sys
p=json.load(open(sys.argv[1]))[\"providers\"][\"claude\"]
h7=p[\"history7d\"]
exit(0 if p.get(\"monthTokens\")==h7[\"tokens\"] and p.get(\"monthCostUsd\")==h7.get(\"costUsd\") and (h7.get(\"costUsd\") or 0)>0 else 1)' '$STATE/state.json'"
check "heartbeat v4: codex sem histórico diário → pacing AUSENTE no app (fração 42% não vira forecast)" \
  "python3 -c '
import json,sys
p=json.load(open(sys.argv[1]))[\"providers\"][\"codex\"]
exit(0 if p.get(\"pacing\") is None and p[\"percent\"]==42 else 1)' '$STATE/state.json'"

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
# Espera POR CONTEÚDO com folga: sob load pós-suíte pesada o ciclo
# (FSEvents → debounce 3s → ingest) já passou de 10s (flake observado 1×);
# 25 iterações mantêm a semântica (conteúdo, não sleep fixo) com headroom.
for _ in $(seq 1 25); do
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
for _ in $(seq 1 25); do
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
# conta). Duas provas de backoff: o app fez ≤ 10 requests na vida INTEIRA do
# mock (esperado 8 = DOIS bursts de 4: seed launch + launch principal, cada um
# com 1 codex + 1 zai + 2 openrouter credits+key) e o pico em qualquer janela
# deslizante de 10 s é ≤ 8 — o e2e moderno é rápido o bastante para os DOIS
# bursts legítimos caírem na mesma janela (pico observado 8); um STORM real
# apareceria como dezenas POR SEGUNDO (centenas na janela) — o backoff ×2
# parte de 5 min, então cadência alta é estruturalmente impossível.
read -r APP_TOTAL BURST_10S <<EOF2
$(python3 - "$MOCK_LOG" <<'PYEOF'
import sys
app_auth = ("Bearer fake-token-e2e", "Bearer fake-api-key-e2e", "Bearer fake-openrouter-e2e")
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
check "requests do APP na vida do mock atribuídos pelo token: ${APP_TOTAL:-99} (≤ 10; esperado 8 = 2 bursts)" \
  "[ '${APP_TOTAL:-99}' -le 10 ]"
check "requests/10s do APP limitados pelo backoff: pico ${BURST_10S:-99} na janela deslizante de 10s (≤ 8)" \
  "[ '${BURST_10S:-99}' -le 8 ]"

# Diagnóstico da degradação (selfcheck v2 com o mock MORTO): erro tokenizado
# "network" por provider — nunca mensagem crua com URL (spec §9).
SELFCHECK_DOWN="$(env "${SELF_ENV[@]}" swift run -c release tokenbar selfcheck "$CORPUS")"
say "selfcheck (mock morto): $SELFCHECK_DOWN"
check "selfcheck pós-morte: erro tokenizado 'network' em codex e zai" \
  "echo \"\$SELFCHECK_DOWN\" | python3 -c 'import json,sys;p=json.load(sys.stdin)[\"providers\"];exit(0 if p[\"codex\"].get(\"error\")==\"network\" and p[\"zai\"].get(\"error\")==\"network\" else 1)'"

# ---------------------------------------------------------------------------
# 7.7 (F5 T7) DEDUPE PERSISTIDO: relaunch com o mock MORTO. O estado de dedupe
#     (zai t50/t75, resetsAt carimbado) sobreviveu no banco `alerts:state`;
#     além disso, snapshot que falha NÃO entra na avaliação — erro de rede não
#     inventa alerta. Espera POR CONTEÚDO: updatedAt avançar (novo ciclo
#     publicado) — então o arquivo de captura ainda tem EXATAS 2 linhas e o
#     estado segue 'enabled' (config persistida + gateway granted).
# ---------------------------------------------------------------------------
say "F5 alerts: relaunch (mock morto) p/ provar dedupe persistido e silêncio sob erro"
kill -9 "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null
env "${COMMON_ENV[@]}" TOKENBAR_E2E_DIR="$STATE" \
  "build/TokenBar.app/Contents/MacOS/tokenbar" &
APP_PID=$!
DEDUPE_OK=0
for _ in $(seq 1 45); do
  NEW_UPDATED="$(json_field "$STATE/state.json" "['updatedAt']" 2>/dev/null)"
  NEW_CLAUDE="$(json_field "$STATE/state.json" "['providers']['claude']['todayTokens']" 2>/dev/null)"
  if [ "$NEW_UPDATED" != "MISSING" ] && [ "$NEW_CLAUDE" != "MISSING" ] \
     && [ "$NEW_UPDATED" != "$LAST_UPDATED" ] && [ "$NEW_CLAUDE" -ge "$((AFTER_TOTAL + 222))" ] 2>/dev/null; then
    DEDUPE_OK=1 && break
  fi
  sleep 1
done
check "F5 dedupe: app re-aberto publicou ciclo (claude preservado, updatedAt avançou)" "[ '$DEDUPE_OK' = '1' ]"
check "F5 dedupe: captura ainda com EXATAS 2 linhas — estado persistido não re-dispara, erro não inventa alerta" \
  "[ \"\$(wc -l < '$STATE/alerts.jsonl' | tr -d ' ')\" = '2' ]"
check "F5 dedupe: alertsStatus segue 'enabled' (config do banco + gateway granted)" \
  "[ \"\$(json_field '$STATE/state.json' \"['alertsStatus']\")\" = 'enabled' ]"

# ---------------------------------------------------------------------------
# 7.5 (F3-a) Histórico consistente: `tokenbar history` (mesmo banco, mesma
#     família de queries da UI) bate com o heartbeat. O corpus tem eventos de
#     até 24h no passado (podem cair no dia de ONTEM local), então a
#     consistência exigida é por JANELA: todo evento tem <48h → série 3d ==
#     série 7d == history7d do heartbeat; a série 1d (só hoje, MESMO calendar
#     e filtro do ledger) == todayTokens — seguro porque o live update da
#     seção 6 já provou que os appends contam como hoje. Custo > 0 prova
#     precificação (claude-sonnet-4-6/gemini-2.5-flash estão na tabela). O CLI
#     roda ENQUANTO o app tem o WAL aberto — leitor concorrente é uso normal
#     (spec §6).
# ---------------------------------------------------------------------------
HB="$STATE/state.json"
HB_CLAUDE="$(json_field "$HB" "['providers']['claude']['todayTokens']")"
HB_GEMINI="$(json_field "$HB" "['providers']['gemini']['todayTokens']")"
HB_H7="$(json_field "$HB" "['providers']['claude']['history7d']['tokens']")"
HIST_JSON="$(env "${COMMON_ENV[@]}" swift run -c release tokenbar history --days 3 --format json)"
HIST_7D="$(env "${COMMON_ENV[@]}" swift run -c release tokenbar history --days 7 --format json)"
HIST_CSV="$(env "${COMMON_ENV[@]}" swift run -c release tokenbar history --days 3 --format csv)"
say "history 3d json: $HIST_JSON"
totals() {  # totals <json_history> → "claude=<n> gemini=<n> claude_cost=<f>"
  echo "$1" | python3 -c '
import json,sys
rows=json.load(sys.stdin)
tok={}; cost={}
for r in rows:
    tok[r["provider"]]=tok.get(r["provider"],0)+r["tokens"]
    if r["costUsd"] is not None: cost[r["provider"]]=cost.get(r["provider"],0)+r["costUsd"]
print("claude=%d gemini=%d claude_cost=%.6f" % (tok.get("claude",0),tok.get("gemini",0),cost.get("claude",0)))'
}
T3="$(totals "$HIST_JSON")"; T7="$(totals "$HIST_7D")"
CLAUDE_3D="$(echo "$T3" | sed 's/.*claude=\([0-9]*\).*/\1/')"
GEMINI_3D="$(echo "$T3" | sed 's/.*gemini=\([0-9]*\).*/\1/')"
say "totais: 3d[$T3] 7d[$T7] | heartbeat C=$HB_CLAUDE G=$HB_GEMINI h7=$HB_H7"
check "history 3d == history 7d (corpus inteiro dentro de 48h): claude=$CLAUDE_3D" \
  "[ '$T3' = '$T7' ]"
check "history 3d do claude == history7d do heartbeat ($CLAUDE_3D == $HB_H7)" \
  "[ '$CLAUDE_3D' = '$HB_H7' ]"
check "history 3d cobre o dia de hoje: claude 3d ≥ todayTokens ($CLAUDE_3D ≥ $HB_CLAUDE)" \
  "[ '$CLAUDE_3D' -ge '$HB_CLAUDE' ]"
HIST_1D="$(env "${COMMON_ENV[@]}" swift run -c release tokenbar history --days 1 --format json)"
T1D="$(totals "$HIST_1D")"
CLAUDE_1D="$(echo "$T1D" | sed 's/.*claude=\([0-9]*\).*/\1/')"
GEMINI_1D="$(echo "$T1D" | sed 's/.*gemini=\([0-9]*\).*/\1/')"
check "history 1d (só hoje) == todayTokens do heartbeat (claude $CLAUDE_1D == $HB_CLAUDE, gemini $GEMINI_1D == $HB_GEMINI)" \
  "[ '$CLAUDE_1D' = '$HB_CLAUDE' ] && [ '$GEMINI_1D' = '$HB_GEMINI' ]"
check "history: custo do claude computado (> 0, modelo precificado)" \
  "echo '$T3' | grep -qE 'claude_cost=[0-9.]*[1-9]'"
check "history CSV: mesmo total do JSON (parse RFC 4180, formatos consistentes)" \
  "echo \"\$HIST_CSV\" | python3 -c '
import csv,json,sys
tok={}
for r in csv.DictReader(sys.stdin): tok[r[\"provider\"]]=tok.get(r[\"provider\"],0)+int(r[\"tokens\"])
exit(0 if tok.get(\"claude\")==$CLAUDE_3D and tok.get(\"gemini\")==$GEMINI_3D else 1)'"

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

# ---------------------------------------------------------------------------
# 9. (F3-b) Migração de cursors.json legado (F2, sem DB) + idempotência da
#    migration (Red Team caso 3). Simulação do upgrade de um usuário F2:
#    cursores EM DIA e snapshot do dia preservados, SEM banco — os cursors.json
#    são extraídos do banco da fase 1 (mesmo mapa `path → {offset[,seenIDs]}`
#    que o JSONFileOffsetStore do F2 gravava; paths já resolvidos, como o
#    enumerator grava). Provas: (i) migração renomeia para .migrated;
#    (ii) NÃO re-escaneia — o ledger do dia restaura via stamp de cursores e
#    os totais do heartbeat ficam EXATOS (não zerados, não dobrados);
#    (iii) NÃO retroage no banco — bytes atrás do cursor legado não viram
#    eventos (backfill fora de escopo, decisão T1: history vazio);
#    (iv) evento NOVO pós-migração persiste exatamente 1× (display soma sobre
#    o ledger restaurado, banco ganha 1 evento);
#    (v) migration RE-RUN (3º launch, cursors já .migrated) é no-op e o banco
#    não dobra (Red Team caso 3). Orçamento medido de novo no app re-aberto
#    (DB aberto, ingest de re-leitura zero).
# ---------------------------------------------------------------------------
say "migração: capturando estado da fase 1 e matando o app"
MIG_T1="$(json_field "$HB" "['providers']['claude']['todayTokens']")"
MIG_G="$(json_field "$HB" "['providers']['gemini']['todayTokens']")"
MIG_LAST_UPDATED="$(json_field "$HB" "['updatedAt']")"
kill -9 "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null
SUPPORT_DB="$SUPPORT/tokenbar.sqlite"
for p in claude gemini; do
  sqlite3 "$SUPPORT_DB" "SELECT value FROM settings WHERE key='cursors:$p'" \
    > "$SUPPORT/$p-cursors.json" 2>/dev/null
done
check "cursors.json legados plantados no formato F2 (offset presente)" \
  "grep -q 'offset' '$SUPPORT/claude-cursors.json' && grep -q 'offset' '$SUPPORT/gemini-cursors.json'"
rm -f "$SUPPORT_DB" "$SUPPORT_DB-wal" "$SUPPORT_DB-shm"
check "banco removido (cenário F2: sem DB)" "[ ! -f '$SUPPORT_DB' ]"

env "${COMMON_ENV[@]}" TOKENBAR_E2E_DIR="$STATE" \
  "build/TokenBar.app/Contents/MacOS/tokenbar" &
APP_PID=$!
# Espera o app NOVO publicar: updatedAt mudou + ambos os locais presentes
# (publish é por provider — o claude sozinho não prova o restore do gemini).
MIGRATED=0
for _ in $(seq 1 60); do
  MIG_C_NOW="$(json_field "$STATE/state.json" "['providers']['claude']['todayTokens']" 2>/dev/null)"
  MIG_G_NOW="$(json_field "$STATE/state.json" "['providers']['gemini']['todayTokens']" 2>/dev/null)"
  [ -f "$SUPPORT/claude-cursors.json.migrated" ] \
    && [ "$MIG_C_NOW" != "MISSING" ] && [ "$MIG_G_NOW" != "MISSING" ] \
    && [ "$(json_field "$STATE/state.json" "['updatedAt']" 2>/dev/null)" != "$MIG_LAST_UPDATED" ] \
    && MIGRATED=1 && break
  sleep 1
done
MIG_C="$(json_field "$STATE/state.json" "['providers']['claude']['todayTokens']")"
MIG_G2="$(json_field "$STATE/state.json" "['providers']['gemini']['todayTokens']")"
check "migração: cursors.json → .migrated e heartbeat de pé em 30s" "[ '$MIGRATED' = '1' ]"
check "migração: NÃO re-escaneia — claude preservado exato ($MIG_C == $MIG_T1, não 0, não dobrado)" \
  "[ '$MIG_C' = '$MIG_T1' ]"
check "migração: gemini preservado exato ($MIG_G2 == $MIG_G)" "[ '$MIG_G2' = '$MIG_G' ]"
MIG_HIST="$(env "${COMMON_ENV[@]}" swift run -c release tokenbar history --days 7 --format json)"
check "migração: NÃO retroage no banco novo (history 7d vazio — backfill fora de escopo)" \
  "[ \"\$(echo \"\$MIG_HIST\" | tr -d '[:space:]')\" = '[]' ]"

LINE3='{"type":"assistant","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":200}}}'
echo "$LINE3" >> "$(ls "$CORPUS"/session-0/*.jsonl | head -1)"
MIG_UPDATED=0
for _ in $(seq 1 25); do
  sleep 1
  NEW_C="$(json_field "$STATE/state.json" "['providers']['claude']['todayTokens']")"
  if [ "$NEW_C" != "MISSING" ] && [ "$NEW_C" -eq "$((MIG_T1 + 300))" ] 2>/dev/null; then MIG_UPDATED=1; break; fi
done
check "migração: evento novo soma sobre o ledger restaurado (Δ=+300 → $((MIG_T1 + 300)))" "[ '$MIG_UPDATED' = '1' ]"
MIG_HIST2="$(env "${COMMON_ENV[@]}" swift run -c release tokenbar history --days 7 --format json)"
check "migração: evento novo persistiu 1× no banco (1 linha, 300 tokens)" \
  "echo \"\$MIG_HIST2\" | python3 -c '
import json,sys
rows=json.load(sys.stdin)
exit(0 if len(rows)==1 and rows[0][\"provider\"]==\"claude\" and rows[0][\"tokens\"]==300 else 1)'"

say "re-run da migration: relançando o app (cursors já .migrated — no-op esperado)"
RERUN_LAST_UPDATED="$(json_field "$STATE/state.json" "['updatedAt']")"
kill -9 "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null
env "${COMMON_ENV[@]}" TOKENBAR_E2E_DIR="$STATE" \
  "build/TokenBar.app/Contents/MacOS/tokenbar" &
APP_PID=$!
RERUN=0
for i in $(seq 1 120); do
  RERUN_C="$(json_field "$STATE/state.json" "['providers']['claude']['todayTokens']" 2>/dev/null)"
  RERUN_U="$(json_field "$STATE/state.json" "['updatedAt']" 2>/dev/null)"
  [ "$RERUN_C" != "MISSING" ] && [ "$RERUN_C" -eq "$((MIG_T1 + 300))" ] 2>/dev/null \
    && [ "$RERUN_U" != "$RERUN_LAST_UPDATED" ] && RERUN=1 && break
  [ $((i % 10)) = 0 ] && say "re-run diagnóstico t+${i}s: claude=$RERUN_C updatedAt=$RERUN_U (esperado claude=$((MIG_T1 + 300)); inicial=$RERUN_LAST_UPDATED; app vivo=$(kill -0 $APP_PID 2>/dev/null && echo sim || echo NAO))"
  sleep 1
done
check "re-run: idempotente — claude $RERUN_C == $((MIG_T1 + 300)) no 3º launch" "[ '$RERUN' = '1' ]"
check "re-run: banco não dobrou (usage_events ainda == 1)" \
  "[ \"\$(sqlite3 '$SUPPORT_DB' 'SELECT COUNT(*) FROM usage_events' 2>/dev/null)\" = '1' ]"
check "re-run: daily_agg não dobrou (300 tokens)" \
  "[ \"\$(sqlite3 \"$SUPPORT_DB\" 'SELECT input_tokens+output_tokens+cache_read_tokens+cache_write_tokens FROM daily_agg' 2>/dev/null)\" = '300' ]"

say "aguardando 10s para medir recursos do app re-aberto (DB aberto)..."
sleep 10
FOOT_RAW2="$(vmmap --summary "$APP_PID" 2>/dev/null | awk '/Physical footprint:/ {print $3; exit}')"
FOOT_KB2="$(python3 -c "
import sys
v=sys.argv[1]; n=float(v[:-1]); u=v[-1].upper()
print(int(n*{'K':1,'M':1024,'G':1024**2}.get(u,1)))" "${FOOT_RAW2:-0K}" 2>/dev/null || echo 999999)"
CPU2="$(ps -o %cpu= -p $APP_PID | tr -d ' ')"
check "pós-migração: processo vivo" "kill -0 $APP_PID"
check "pós-migração: memória própria (phys_footprint) ${FOOT_RAW2:-MISSING} ≤ 40MB com DB aberto" "[ '${FOOT_KB2:-999999}' -le 40960 ]"
check "pós-migração: cpu ${CPU2:-MISSING}% ≤ 0.5%" "python3 -c \"exit(0 if float('${CPU2:-99}'.replace(',','.')) <= 0.5 else 1)\""

# ---------------------------------------------------------------------------
# 10. (F4) Multi-conta no ciclo do app real. Contas CLAUDE com dir própria
#     (ingest local — ZERO request extra ao mock, que está morto desde a
#     seção 7). Registro PROGRAMÁTICO via sqlite3: a fonte do ciclo é o
#     registry (tabela accounts), o guard de overlap mora na UI — caminho
#     documentado no Red Team F4 caso 5. Provas: agregado = soma EXATA (sem
#     duplicação; hwm/cursor por conta), eventos stampados por conta no DB,
#     toggle ativa tira a conta do ciclo, frota de 30 contas coberta num
#     ciclo só dentro do orçamento, heartbeat sem vazamento de paths/ids e
#     remoção devolve o display ao layout F2 (prune de caches por conta).
# ---------------------------------------------------------------------------
say "F4: corpus da 2ª conta + credencial sintética"
CORPUS2="$TMP/corpus-second"
swift run -c release genfixtures --out "$CORPUS2" --sessions 2 --lines 60 --seed 9 >/dev/null
cat > "$CRED/second-cred.json" <<'EOF'
{"OPENAI_API_KEY": null, "auth_mode": "api_key", "tokens": {"access_token": "fake-token-e2e-second"}}
EOF
# Verdade de referência da 2ª conta (mesma pipeline, corpus só dela): o
# todayTokens que UMA ingest fresca da conta deve somar ao display.
SC2="$(env "${SELF_ENV[@]}" swift run -c release tokenbar selfcheck "$CORPUS2" | python3 -c "import json,sys;print(json.load(sys.stdin)['providers']['claude']['todayTokens'])")"
say "SC2 (corpus 2ª conta, todayTokens): $SC2"
check "corpus da 2ª conta tem eventos HOJE (SC2 > 0 — conta deve somar hoje)" "[ '$SC2' -gt 0 ]"

# Mutação no registry por baixo do app vivo: .timeout (dot-command, SEM
# stdout — PRAGMA imprimiria o próprio valor e corromperia os checks) +
# escritor concorrente do app em WAL (busy ok).
sql() { sqlite3 "$SUPPORT_DB" ".timeout 10000" "$1"; }

BEFORE_B="$(json_field "$STATE/state.json" "['providers']['claude']['todayTokens']")"
sql "INSERT INTO accounts (provider, account_id, label, kind, active, credential_path, directory_path)
     VALUES ('claude','acct-e2e-b','E2E Second','oauth',1,'$CRED/second-cred.json','$CORPUS2');"
check "F4: conta registrada programaticamente no registry (1 linha)" \
  "[ \"\$(sql \"SELECT COUNT(*) FROM accounts WHERE provider='claude'\")\" = '1' ]"
LINE4='{"type":"assistant","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'","message":{"usage":{"input_tokens":111,"output_tokens":222}}}'
echo "$LINE4" >> "$(ls "$CORPUS"/session-0/*.jsonl | head -1)"
B_OK=0
for _ in $(seq 1 30); do
  sleep 1
  NOW_B="$(json_field "$STATE/state.json" "['providers']['claude']['todayTokens']")"
  [ "$NOW_B" != "MISSING" ] && [ "$NOW_B" -eq "$((BEFORE_B + 333 + SC2))" ] 2>/dev/null && B_OK=1 && break
done
check "F4 multi-conta: ciclo cobre as DUAS contas — agregado exato ($NOW_B == $BEFORE_B + 333 + $SC2, sem duplicação)" "[ '$B_OK' = '1' ]"
check "F4 multi-conta: eventos stampados POR CONTA no DB (2 contas no claude)" \
  "[ \"\$(sql \"SELECT COUNT(DISTINCT account) FROM usage_events WHERE provider='claude'\")\" = '2' ]"
check "F4 multi-conta: daily_agg da conta registrada presente (namespace próprio)" \
  "[ \"\$(sql \"SELECT COUNT(*) FROM daily_agg WHERE provider='claude' AND account='acct-e2e-b'\")\" -ge 1 ]"
check "F4 multi-conta: cursor POR CONTA (chave cursors:claude:acct-e2e-b no settings)" \
  "[ -n \"\$(sql \"SELECT value FROM settings WHERE key='cursors:claude:acct-e2e-b'\")\" ]"
check "F4 heartbeat: monthTokens ≥ history7d com 2 contas (agregado DB; custo presente — 30d ⊇ 7d; sem backfill F3, todayTokens é ledger e não participa)" \
  "python3 -c '
import json,sys
p=json.load(open(sys.argv[1]))[\"providers\"][\"claude\"]
m=p.get(\"monthTokens\"); h=(p.get(\"history7d\") or {}).get(\"tokens\")
exit(0 if m is not None and h is not None and m>=h and (p.get(\"monthCostUsd\") or 0)>0 else 1)' '$STATE/state.json'"

say "F4: toggle ativa OFF → conta sai do ciclo; registro permanece"
sql "UPDATE accounts SET active=0 WHERE provider='claude' AND account_id='acct-e2e-b';"
BEFORE_OFF="$(json_field "$STATE/state.json" "['providers']['claude']['todayTokens']")"
LINE5='{"type":"assistant","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'","message":{"usage":{"input_tokens":37,"output_tokens":74}}}'
echo "$LINE5" >> "$(ls "$CORPUS"/session-1/*.jsonl | head -1)"
OFF_OK=0
# Agregado = SOMA das contas cicladas: a conta inativa SAI do display (o
# correto — mesma semântica F2), então o esperado é o canônico (BEFORE_OFF
# menos a parte SC2 da conta) + o append de 111.
EXPECTED_OFF=$((BEFORE_OFF - SC2 + 111))
for _ in $(seq 1 30); do
  sleep 1
  NOW_OFF="$(json_field "$STATE/state.json" "['providers']['claude']['todayTokens']")"
  [ "$NOW_OFF" != "MISSING" ] && [ "$NOW_OFF" -eq "$EXPECTED_OFF" ] 2>/dev/null && OFF_OK=1 && break
done
check "F4 toggle: conta inativa sai do agregado ($NOW_OFF == $EXPECTED_OFF — canônico + append, sem a parte da conta)" "[ '$OFF_OK' = '1' ]"
check "F4 toggle: registro PERMANECE (linha intacta com active=0)" \
  "[ \"\$(sql \"SELECT active FROM accounts WHERE provider='claude' AND account_id='acct-e2e-b'\")\" = '0' ]"

say "F4: frota de 30 contas CLAUDE (137 tokens cada) — ciclo único, orçamento"
FLEET="$TMP/fleet"
FLEET_NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
INSERTS=""
for i in $(seq -w 1 30); do
  mkdir -p "$FLEET/dir-$i/session-0"
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":37}}}\n' "$FLEET_NOW" \
    > "$FLEET/dir-$i/session-0/session-fleet-$i.jsonl"
  [ -n "$INSERTS" ] && INSERTS="$INSERTS,"
  INSERTS="$INSERTS('claude','acct-fleet-$i','Fleet $i','oauth',1,'$CRED/second-cred.json','$FLEET/dir-$i')"
done
sql "INSERT INTO accounts (provider, account_id, label, kind, active, credential_path, directory_path) VALUES $INSERTS;"
check "F4 frota: 31 contas registradas (canônica não está na tabela)" \
  "[ \"\$(sql \"SELECT COUNT(*) FROM accounts WHERE provider='claude'\")\" = '31' ]"
BEFORE_FLEET="$(json_field "$STATE/state.json" "['providers']['claude']['todayTokens']")"
LINE6='{"type":"assistant","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'","message":{"usage":{"input_tokens":60,"output_tokens":90}}}'
echo "$LINE6" >> "$(ls "$CORPUS"/session-0/*.jsonl | head -1)"
FLEET_START="$(date +%s)"
FLEET_OK=0
for _ in $(seq 1 30); do
  sleep 1
  NOW_FLEET="$(json_field "$STATE/state.json" "['providers']['claude']['todayTokens']")"
  [ "$NOW_FLEET" != "MISSING" ] && [ "$NOW_FLEET" -eq "$((BEFORE_FLEET + 150 + 30 * 137))" ] 2>/dev/null && FLEET_OK=1 && break
done
FLEET_SECS=$(( $(date +%s) - FLEET_START ))
say "F4 frota: ciclo cobriu 31 contas em ${FLEET_SECS}s (limite do loop: 30s)"
check "F4 frota: UM ciclo cobre as 31 contas — soma exata ($NOW_FLEET == $BEFORE_FLEET + 150 + 4110) em ${FLEET_SECS}s" "[ '$FLEET_OK' = '1' ]"
check "F4 frota: 30 contas com eventos no DB (local + B + 30 da frota = 32 namespaces)" \
  "[ \"\$(sql \"SELECT COUNT(DISTINCT account) FROM usage_events WHERE provider='claude'\")\" = '32' ]"

PAYLOAD_BYTES="$(wc -c < "$STATE/state.json" | tr -d ' ')"
check "F4 heartbeat: higiene — payload de ${PAYLOAD_BYTES}B ≤ 64KB SEM paths/ids de conta (grep TMP/acct- vazio)" \
  "[ '$PAYLOAD_BYTES' -le 65536 ] && ! grep -qF '$TMP' '$STATE/state.json' && ! grep -q 'acct-' '$STATE/state.json'"

say "F4: orçamento de recursos com 31 contas (10s de acomodação pós-ingest)"
sleep 10
FOOT_RAW4="$(vmmap --summary "$APP_PID" 2>/dev/null | awk '/Physical footprint:/ {print $3; exit}')"
FOOT_KB4="$(python3 -c "
import sys
v=sys.argv[1]; n=float(v[:-1]); u=v[-1].upper()
print(int(n*{'K':1,'M':1024,'G':1024**2}.get(u,1)))" "${FOOT_RAW4:-0K}" 2>/dev/null || echo 999999)"
CPU4="$(ps -o %cpu= -p $APP_PID | tr -d ' ')"
check "F4 orçamento: processo vivo com 31 contas" "kill -0 $APP_PID"
check "F4 orçamento: memória própria (phys_footprint) ${FOOT_RAW4:-MISSING} ≤ 40MB com 31 contas" "[ '${FOOT_KB4:-999999}' -le 40960 ]"
check "F4 orçamento: cpu ${CPU4:-MISSING}% ≤ 0.5% com 31 contas" "python3 -c \"exit(0 if float('${CPU4:-99}'.replace(',','.')) <= 0.5 else 1)\""

say "F4: remoção de todas as contas → display volta ao layout F2 (prune)"
sql "DELETE FROM accounts WHERE provider='claude';"
BEFORE_RM="$(json_field "$STATE/state.json" "['providers']['claude']['todayTokens']")"
LINE7='{"type":"assistant","timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'","message":{"usage":{"input_tokens":40,"output_tokens":80}}}'
echo "$LINE7" >> "$(ls "$CORPUS"/session-1/*.jsonl | head -1)"
RM_OK=0
# Mesma semântica do toggle: removidas não ciclizam → esperado = canônico
# (BEFORE_RM menos os 30×137 da frota) + append de 120.
EXPECTED_RM=$((BEFORE_RM - 30 * 137 + 120))
for _ in $(seq 1 30); do
  sleep 1
  NOW_RM="$(json_field "$STATE/state.json" "['providers']['claude']['todayTokens']")"
  [ "$NOW_RM" != "MISSING" ] && [ "$NOW_RM" -eq "$EXPECTED_RM" ] 2>/dev/null && RM_OK=1 && break
done
check "F4 remoção: contas removidas saem do ciclo ($NOW_RM == $EXPECTED_RM — só a canônica)" "[ '$RM_OK' = '1' ]"
check "F4 remoção: registry vazio e DB não duplicou (eventos da frota permanecem, só-histórico)" \
  "[ \"\$(sql \"SELECT COUNT(*) FROM accounts WHERE provider='claude'\")\" = '0' ]"

say "concluído: $FAILURES falha(s)"
[ "$FAILURES" = "0" ] && exit 0 || exit 1
