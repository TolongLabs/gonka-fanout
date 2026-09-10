#!/usr/bin/env bash
# Gonka Fan-Out setup: bring the proxy up, wire the gonkarouter provider, and prove the
# selected alias is callable before any worker launches. Idempotent: safe to re-run.
#
# The GonkaRouter key is read interactively (read -s) and written only into config.yaml.
# It never appears in argv, in the environment of any child, or in a transcript. Never run
# this script with shell tracing turned on.
set -euo pipefail

if [[ $- == *x* ]]; then
  echo "refusing to run under shell tracing (set -x would echo the API key)" >&2
  exit 1
fi

CLIPROXY_DIR="${CLIPROXY_DIR:-$HOME/.cli-proxy-api}"
CLIPROXY_PORT="${CLIPROXY_PORT:-8317}"
CLIPROXY_BIN="${CLIPROXY_BIN:-$HOME/.local/opt/cliproxyapi/cli-proxy-api}"
CONFIG="$CLIPROXY_DIR/config.yaml"
PROXY_URL="http://127.0.0.1:$CLIPROXY_PORT"

# Default model ids; override with environment if the provider serves different ones.
GONKA_MODEL_ID="${GONKA_MODEL_ID:-deepseek-ai/DeepSeek-V4-Flash-0731}"
GONKA_ALIAS="${GONKA_ALIAS:-deepseek-v4-flash-gonka}"
GONKA_DISPLAY="${GONKA_DISPLAY:-DeepSeek V4 Flash (Gonka)}"

err() { echo "gonka-setup: error: $*" >&2; exit 1; }
info() { echo "gonka-setup: $*"; }

[ -d "$CLIPROXY_DIR" ] || mkdir -p "$CLIPROXY_DIR"
[ -f "$CONFIG" ] || err "no config at $CONFIG; install CLIProxyAPI first"

# --- 1. Ensure the gonkarouter block exists, adding it if it does not. ----------------
if ! grep -q 'name: "gonkarouter"' "$CONFIG"; then
  info "no gonkarouter block in config; adding it"
  if ! grep -q '^openai-compatibility:' "$CONFIG"; then
    err "no openai-compatibility: key in $CONFIG; add it before re-running"
  fi
  read -r -s -p "GonkaRouter API key (sk-...): " GONKA_KEY
  echo >&2
  [ -n "$GONKA_KEY" ] || err "empty key"
  # Append the block under the existing openai-compatibility: key.
  cat >> "$CONFIG" <<EOF
  - name: "gonkarouter"
    base-url: "https://api.gonkarouter.io/v1"
    api-key-entries:
      - api-key: "$GONKA_KEY"
    models:
      - name: "$GONKA_MODEL_ID"
        alias: "$GONKA_ALIAS"
        display-name: "$GONKA_DISPLAY"
EOF
  unset GONKA_KEY
fi

# --- 2. Bring the proxy up if its port is closed. -------------------------------------
if ! (exec 3<>"/dev/tcp/127.0.0.1/$CLIPROXY_PORT") 2>/dev/null; then
  info "port $CLIPROXY_PORT closed; starting proxy"
  [ -x "$CLIPROXY_BIN" ] || err "proxy binary not found at $CLIPROXY_BIN"
  nohup "$CLIPROXY_BIN" -config "$CONFIG" >> "$CLIPROXY_DIR/proxy.log" 2>&1 &
  sleep 3
fi

# --- 3. Read the local proxy token from config, never into argv. ----------------------
CLIPROXY_TOKEN=$(grep -A1 '^api-keys:' "$CONFIG" | tail -1 | tr -d '" -')
[ -n "$CLIPROXY_TOKEN" ] || err "could not read proxy token from $CONFIG"

# --- 4. Canary: prove the alias is callable through the Messages path workers use. ----
PROBE_MAX_TOKENS=64
PROBE_BODY=$(mktemp)
trap 'rm -f "$PROBE_BODY"' EXIT
exec {PROBE_HEADER_FD}<<<"header = \"Authorization: Bearer $CLIPROXY_TOKEN\""
PROBE_STATUS=$(
  jq -n --arg model "$GONKA_ALIAS" --argjson max_tokens "$PROBE_MAX_TOKENS" \
    '{model:$model,max_tokens:$max_tokens,messages:[{role:"user",content:"Reply only: READY"}]}' \
    | curl -sS --config "/dev/fd/$PROBE_HEADER_FD" -o "$PROBE_BODY" -w '%{http_code}' \
        -H 'accept: application/json' -H 'content-type: application/json' \
        --data-binary @- "$PROXY_URL/v1/messages"
)
exec {PROBE_HEADER_FD}<&-
unset CLIPROXY_TOKEN

if [ "$PROBE_STATUS" = 200 ] \
  && jq -e '
       .type == "message" and .stop_reason == "end_turn"
       and ([.content[]? | select(.type == "text") | .text] | join("\n")
           | test("(^|\\n)[[:space:]]*READY[[:space:]]*$"))
     ' "$PROBE_BODY" >/dev/null; then
  info "canary passed for $GONKA_ALIAS; the proxy is wired and callable"
  # The alias is the value to pass as --model on dispatch.
  printf '%s\n' "$GONKA_ALIAS"
  exit 0
fi

echo "gonka-setup: canary failed (HTTP $PROBE_STATUS)" >&2
if grep -Eqi '(error|code)[^0-9]{0,20}1010' "$PROBE_BODY"; then
  echo "Inconclusive Cloudflare 1010; repeat the identical request with curl/requests/httpx" >&2
else
  jq -r '.error.message? // .error? // "invalid response"' "$PROBE_BODY" 2>/dev/null \
    || echo "non-JSON response" >&2
fi
echo "Failed response retained at $PROBE_BODY" >&2
exit 1