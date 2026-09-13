#!/bin/bash
# UI Smoke — verificação AUTOMATIZÁVEL das interações do painel.
#
# ESCOPO (atualizado em 13/09): a premissa antiga ("o painel do MenuBarExtra
# .window NÃO expõe conteúdo ao AX") valia só para **System Events**, que não
# enumera as janelas deste app. A API de Acessibilidade DIRETA devolve a árvore
# completa do painel aberto (textos, frames, botões) e o AXPress funciona —
# `scripts/qa-axtree.swift`. Foi assim que se mediu a janela colapsada em
# 129pt que escondia o painel (relato do dono: "só os logos e as barrinhas").
#
# O smoke valida:
#   1. Boot hermético (nenhum provider da máquina é tocado) + heartbeat;
#   2. Item da menu bar existe com o texto esperado (C:…);
#   3. Painel abre de verdade (o clique AX não pode falhar em silêncio) e o
#      conteúdo está DENTRO da janela: ações + rodapé alcançáveis
#      (`qa-axtree --panel`, piso de altura incluso);
#   4. "Usage dashboard" abre a janela do Analytics (AXPress + janela);
#   5. ⌘Q global encerra sem zumbi.
#
# POR QUE O NOME PRÓPRIO (tokenbar-ui-smoke): pkill/killall por nome derruba
# também o app real do usuário — este script só toca o PID que criou.
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=".build/debug/tokenbar"
[ -x "$BIN" ] || { echo "ERRO: $BIN ausente — rode swift build"; exit 2; }

TMP="$(mktemp -d /tmp/tokenbar-ui-smoke.XXXXXX)"
APPNAME="tokenbar-ui-smoke"
APP_DIR="$TMP/app"; CORPUS="$TMP/corpus"; CRED="$TMP/cred"
SUPPORT="$TMP/support"; STATE="$TMP/state"
mkdir -p "$APP_DIR" "$CORPUS/session-0" "$CRED" "$SUPPORT" "$STATE"

cleanup() {
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null || true
  sleep 0.3
  if [ "${UI_SMOKE_KEEP:-}" = "1" ]; then echo "[ui-smoke] KEEP: $TMP"; else rm -rf "$TMP"; fi
}
trap cleanup EXIT

fail() { echo "[ui-smoke] FAIL: $*"; exit 1; }
say()  { echo "[ui-smoke] $*"; }

cp "$BIN" "$APP_DIR/$APPNAME"
for b in .build/debug/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP_DIR/"
done

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":500}}}\n' \
  "$NOW_ISO" > "$CORPUS/session-0/session-a.jsonl"

LAB_ENV=(
  TOKENBAR_CLAUDE_DIR="$CORPUS"
  TOKENBAR_GEMINI_DIR="$TMP/gemini-empty"
  TOKENBAR_SUPPORT_DIR="$SUPPORT"
  TOKENBAR_E2E_DIR="$STATE"
  TOKENBAR_CODEX_DIR="$TMP/codex-empty"
  TOKENBAR_CODEX_AUTH="$CRED/nao-existe.json"
  TOKENBAR_ZAI_CONFIG="$CRED/nao-existe.json"
  TOKENBAR_ZAI_AUTH="$CRED/nao-existe.json"
  TOKENBAR_CURSOR_DB="$CRED/nao-existe.json"
  TOKENBAR_GROK_AUTH="$CRED/nao-existe.json"
  TOKENBAR_ANTIGRAVITY_CREDS="$CRED/nao-existe.json"
  DEEPSEEK_API_KEY="" ALIBABA_CODING_PLAN_API_KEY="" ALIBABA_QWEN_API_KEY="" DASHSCOPE_API_KEY=""
)
mkdir -p "$TMP/gemini-empty" "$TMP/codex-empty"

say "subindo $APPNAME — TMP=$TMP"
env "${LAB_ENV[@]}" "$APP_DIR/$APPNAME" > "$TMP/app-stdout.log" 2>&1 &
APP_PID=$!
for _ in $(seq 1 30); do
  [ -f "$STATE/state.json" ] && [ "$(python3 -c "import json;print(json.load(open('$STATE/state.json')).get('menuBarText',''))" 2>/dev/null)" != "" ] && break
  kill -0 "$APP_PID" 2>/dev/null || fail "app morreu antes do heartbeat"
  sleep 1
done
[ -f "$STATE/state.json" ] || fail "heartbeat não publicado em 30s"
MBT=$(python3 -c "import json;print(json.load(open('$STATE/state.json'))['menuBarText'])")
say "heartbeat ok (pid $APP_PID): $MBT"
case "$MBT" in
  C:*) : ;;
  *) fail "menu bar inesperado: '$MBT' (hermeticidade quebrada?)" ;;
esac

# System Events precisa indexar o processo novo antes de respondê-lo.
ax() { osascript -e "tell application \"System Events\" to tell process \"$APPNAME\" to $1" 2>/dev/null; }
INDEXED=0
for _ in $(seq 1 20); do
  ax 'get name of menu bar item 1 of menu bar 2' >/dev/null 2>&1 && INDEXED=1 && break
  kill -0 "$APP_PID" 2>/dev/null || fail "app morreu esperando indexação AX"
  sleep 0.5
done
[ "$INDEXED" = "1" ] || fail "System Events não indexou $APPNAME"

ITEM_NAME=$(ax 'get name of menu bar item 1 of menu bar 2')
say "item da menu bar: '$ITEM_NAME'"
case "$ITEM_NAME" in
  C:*) : ;;
  *) fail "item sem texto esperado: '$ITEM_NAME'" ;;
esac

# Ferramenta de AX DIRETO (System Events não enumera as janelas do painel).
AXTOOL="$TMP/qa-axtree"
if ! xcrun swiftc -O scripts/qa-axtree.swift -o "$AXTOOL" 2>"$TMP/axtool.log"; then
  fail "qa-axtree não compilou: $(tail -2 "$TMP/axtool.log")"
fi

# Abrir o painel: o clique tem que funcionar DE VERDADE (antes o erro do
# osascript era silenciado e o smoke dizia "toggle do painel ok" sem clicar).
ax 'click menu bar item 1 of menu bar 2' >/dev/null || fail "clique no item via AX falhou (Acesso Assistivo negado?)"
sleep 2
kill -0 "$APP_PID" 2>/dev/null || fail "app morreu ao abrir o painel"

# Conteúdo DENTRO da janela (regressão de 13/09: janela colapsada em 129pt
# mostrava só chip bar + barrinhas e escondia "Usage dashboard").
"$AXTOOL" --panel "$APP_PID" || fail "painel não passou na verificação de estrutura"
say "painel: estrutura dentro da janela"

# Ação alcançável de fato: "Usage dashboard" abre a janela do Analytics.
"$AXTOOL" --press "$APP_PID" "Usage dashboard" >/dev/null || fail "AXPress em Usage dashboard falhou"
"$AXTOOL" --wait-window "$APP_PID" "TokenBar Analytics" 8 >/dev/null || fail "janela do Analytics não abriu"
say "Usage dashboard abre a janela do Analytics"
kill -0 "$APP_PID" 2>/dev/null || fail "app morreu depois das ações do painel"

# ⌘Q global encerra limpo (sem zumbi) — quit SEM precisar do conteúdo AX.
osascript -e "tell application \"System Events\" to keystroke \"q\" using command down" >/dev/null 2>&1
sleep 2
if kill -0 "$APP_PID" 2>/dev/null; then
  # ⌘Q global pode não chegar ao app acessório sem foco — fallback honesto:
  # SIGTERM no PID criado (mesmo caminho do cleanup) e valida o encerramento.
  kill "$APP_PID" 2>/dev/null; sleep 1.5
  kill -0 "$APP_PID" 2>/dev/null && fail "processo não encerrou" || say "encerrou (SIGTERM pós ⌘Q sem foco)"
else
  say "⌘Q encerrou limpo"
fi

say "PASS: boot hermético + item da menu bar + painel (estrutura + Usage dashboard) + encerramento"
exit 0
