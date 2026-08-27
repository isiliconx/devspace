#!/usr/bin/env bash
set -Eeuo pipefail

CL="$HOME/.qwen-cluster"
LOGS="$CL/logs"
OWNER="$CL/infinity-owner-token"
API="$CL/api.key"

[ -x "$CL/run-infinity.sh" ] || { echo "Missing $CL/run-infinity.sh" >&2; exit 1; }
[ -x "$CL/api/start-gateway.sh" ] || { echo "Missing $CL/api/start-gateway.sh" >&2; exit 1; }
[ -s "$OWNER" ] || { echo "Missing $OWNER" >&2; exit 1; }
[ -s "$API" ] || { echo "Missing $API" >&2; exit 1; }

umask 077
openssl rand -hex 24 > "$OWNER.new"
printf 'sk-qwen-%s\n' "$(openssl rand -hex 24)" > "$API.new"
mv "$OWNER.new" "$OWNER"
mv "$API.new" "$API"
chmod 600 "$OWNER" "$API"

tmux kill-session -t infinity-rescue 2>/dev/null || true
tmux new-session -d -s infinity-rescue \
  "while true; do '$CL/run-infinity.sh' >> '$LOGS/infinity.log' 2>&1; sleep 2; done"

tmux kill-session -t qwen-api-gateway 2>/dev/null || true
tmux new-session -d -s qwen-api-gateway \
  "while true; do '$CL/api/start-gateway.sh' >> '$LOGS/api-gateway.log' 2>&1; sleep 2; done"

sleep 3
KEY="$(cat "$API")"
TS_DNS="$(sudo tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"].get("DNSName","").rstrip("."))')"
QH="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:18082/health || true)"
UNAUTH="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:18080/v1/models || true)"
AUTH="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $KEY" http://127.0.0.1:18080/v1/models || true)"
PREFLIGHT="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X OPTIONS -H 'Origin: https://www.typingmind.com' -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: authorization,content-type' http://127.0.0.1:18080/v1/chat/completions || true)"
PUBLIC_AUTH="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -H "Authorization: Bearer $KEY" "https://$TS_DNS/v1/models" || true)"

printf '\n=== LIVE QWEN HARDENING COMPLETE ===\n'
printf 'QWEN_HEALTH=%s\n' "$QH"
printf 'LOCAL_UNAUTH_MODELS=%s\n' "$UNAUTH"
printf 'LOCAL_AUTH_MODELS=%s\n' "$AUTH"
printf 'TYPINGMIND_PREFLIGHT=%s\n' "$PREFLIGHT"
printf 'PUBLIC_AUTH_MODELS=%s\n' "$PUBLIC_AUTH"
printf 'QWEN_API_BASE=https://%s/v1\n' "$TS_DNS"
printf 'INFINITY_MCP=https://%s:8443/mcp\n' "$TS_DNS"
printf 'QWEN_KEY_FILE=%s\n' "$API"
printf 'INFINITY_OWNER_TOKEN_FILE=%s\n' "$OWNER"
printf 'SECRETS=rotated; old printed values are invalid\n'
printf '\nUse: cat %s  -> paste directly into TypingMind only.\n' "$API"
printf 'Use: cat %s  -> paste directly into the Infinity OAuth prompt only.\n' "$OWNER"
printf 'Do not paste either value into chat.\n'
