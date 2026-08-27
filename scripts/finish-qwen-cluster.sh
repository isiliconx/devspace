#!/usr/bin/env bash
set -Eeuo pipefail

CL="$HOME/.qwen-cluster"
LOGS="$CL/logs"
BIN="$HOME/llm/llama.cpp/build/bin"
MODEL="$HOME/models/orcarouter-qwen3.8-27b/Qwen3.8-27B-Uncensored-Q4_K_M.gguf"
MMPROJ="$HOME/models/orcarouter-qwen3.8-27b/mmproj-Qwen3.8-27B-Uncensored-f16.gguf"
API_KEY_FILE="$CL/api.key"
mkdir -p "$CL" "$LOGS"
log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

for f in "$BIN/llama-server" "$MODEL" "$MMPROJ" "$API_KEY_FILE"; do
  [ -e "$f" ] || { echo "Missing required file: $f" >&2; exit 1; }
done

log "Current cluster diagnostics"
free -h || true
printf '%s\n' '--- tmux ---'
tmux ls 2>/dev/null || true
printf '%s\n' '--- processes ---'
pgrep -af 'llama-server|qwen-stack-watch|socat.*50054|tailscale nc.*50053' || true
printf '%s\n' '--- watchdog log ---'
tail -40 "$LOGS/qwen-stack-watch.log" 2>/dev/null || true
printf '%s\n' '--- bridge log ---'
tail -20 "$LOGS/qwen-rpc-bridge.log" 2>/dev/null || true

log "Ensuring VM2 RPC bridge"
command -v socat >/dev/null 2>&1 || { sudo apt-get update -y >/dev/null; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y socat netcat-openbsd >/dev/null; }
cat > "$CL/run-rpc-bridge.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exec socat TCP-LISTEN:50054,bind=127.0.0.1,reuseaddr,fork EXEC:'sudo -n tailscale nc qwen-vm2 50053',nofork
EOF
chmod 700 "$CL/run-rpc-bridge.sh"
if ! tmux has-session -t qwen-rpc-bridge 2>/dev/null; then
  tmux new-session -d -s qwen-rpc-bridge "$CL/run-rpc-bridge.sh >> '$LOGS/qwen-rpc-bridge.log' 2>&1"
fi
sleep 2

probe_rpc(){
  rm -f /tmp/qwen-rpc-final-probe.out
  timeout 20 "$BIN/llama-server" --rpc 127.0.0.1:50054 --list-devices > /tmp/qwen-rpc-final-probe.out 2>&1 || true
  grep -q 'RPC0:' /tmp/qwen-rpc-final-probe.out
}
if ! probe_rpc; then
  echo 'RPC bridge is not delivering VM2. Probe:' >&2
  cat /tmp/qwen-rpc-final-probe.out >&2 || true
  tail -50 "$LOGS/qwen-rpc-bridge.log" >&2 || true
  exit 2
fi
grep -m1 'RPC0:' /tmp/qwen-rpc-final-probe.out

log "Installing direct Qwen launch wrapper"
cat > "$CL/run-qwen.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
exec "$BIN/llama-server" \\
  -m "$MODEL" \\
  --mmproj "$MMPROJ" \\
  --no-mmproj-offload \\
  --rpc 127.0.0.1:50054 \\
  -ngl 32 \\
  -c 65536 \\
  --alias qwen \\
  -np 1 \\
  --cache-type-k q4_0 \\
  --cache-type-v q4_0 \\
  --no-cache-prompt \\
  --no-cache-idle-slots \\
  -t 4 \\
  --reasoning off \\
  --host 127.0.0.1 \\
  --port 18082 \\
  --metrics \\
  --no-webui
EOF
chmod 700 "$CL/run-qwen.sh"

log "Launching Qwen directly and proving the process starts"
tmux kill-session -t qwen-stack-watch 2>/dev/null || true
tmux kill-session -t qwen-2node-64k-mm 2>/dev/null || true
pkill -f '^.*/llama-server .*--port 18082' 2>/dev/null || true
: > "$LOGS/qwen-server.log"
tmux new-session -d -s qwen-2node-64k-mm "$CL/run-qwen.sh >> '$LOGS/qwen-server.log' 2>&1"
sleep 5

if ! pgrep -f '^.*/llama-server .*--port 18082' >/dev/null 2>&1; then
  echo 'llama-server exited immediately. Log:' >&2
  cat "$LOGS/qwen-server.log" >&2 || true
  tmux capture-pane -pt qwen-2node-64k-mm 2>/dev/null || true
  exit 3
fi
printf 'LLAMA_PROCESS=%s\n' "$(pgrep -f '^.*/llama-server .*--port 18082' | head -1)"
printf 'LLAMA_LOG_BYTES=%s\n' "$(stat -c %s "$LOGS/qwen-server.log" 2>/dev/null || echo 0)"
tail -20 "$LOGS/qwen-server.log" 2>/dev/null || true

log "Waiting for 64K Qwen health; keeping it alive even if DERP makes first load slow"
healthy=0
for i in $(seq 1 120); do
  code="$(curl -sS -o /tmp/qwen-health.body -w '%{http_code}' --max-time 3 http://127.0.0.1:18082/health 2>/dev/null || true)"
  if [ "$code" = "200" ]; then healthy=1; break; fi
  if ! pgrep -f '^.*/llama-server .*--port 18082' >/dev/null 2>&1; then
    echo 'llama-server died during load. Recent log:' >&2
    tail -120 "$LOGS/qwen-server.log" >&2 || true
    exit 4
  fi
  if [ $((i % 6)) -eq 0 ]; then
    printf '\n--- still loading: %ss ---\n' "$((i*5))"
    tail -8 "$LOGS/qwen-server.log" 2>/dev/null || true
    free -h | sed -n '1,2p' || true
  fi
  sleep 5
done

if [ "$healthy" != 1 ]; then
  echo 'Qwen is still loading after 10 minutes. The process is alive; leaving it running.' >&2
  echo 'This usually means the DERP relay is the bottleneck. Recent log:' >&2
  tail -80 "$LOGS/qwen-server.log" >&2 || true
  exit 5
fi

log "Installing corrected self-healing watchdog"
cat > "$CL/qwen-stack-watch.sh" <<EOF
#!/usr/bin/env bash
set -u
CL="$CL"
BIN="$BIN"
LOGS="$LOGS"
probe_rpc(){
  timeout 20 "\$BIN/llama-server" --rpc 127.0.0.1:50054 --list-devices > /tmp/qwen-rpc-watch-probe.out 2>&1 || true
  grep -q 'RPC0:' /tmp/qwen-rpc-watch-probe.out
}
qwen_running(){ pgrep -f '^.*/llama-server .*--port 18082' >/dev/null 2>&1; }
while true; do
  if qwen_running; then sleep 15; continue; fi
  if ! probe_rpc; then sleep 15; continue; fi
  tmux kill-session -t qwen-2node-64k-mm 2>/dev/null || true
  tmux new-session -d -s qwen-2node-64k-mm "\$CL/run-qwen.sh >> '\$LOGS/qwen-server.log' 2>&1"
  sleep 30
done
EOF
chmod 700 "$CL/qwen-stack-watch.sh"
tmux new-session -d -s qwen-stack-watch "$CL/qwen-stack-watch.sh >> '$LOGS/qwen-stack-watch.log' 2>&1" 2>/dev/null || true

log "Verifying API gateway and TypingMind browser preflight"
node --check "$CL/api/gateway.mjs"
if ! tmux has-session -t qwen-api-gateway 2>/dev/null; then
  tmux new-session -d -s qwen-api-gateway "while true; do '$CL/api/start-gateway.sh' >> '$LOGS/api-gateway.log' 2>&1; sleep 2; done"
  sleep 2
fi
UNAUTH="$(curl -sS -o /tmp/qwen-unauth.body -w '%{http_code}' --max-time 5 http://127.0.0.1:18080/v1/models || true)"
PREFLIGHT_HEADERS="$(curl -sS -D - -o /dev/null --max-time 5 -X OPTIONS \
  -H 'Origin: https://www.typingmind.com' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: Authorization, Content-Type' \
  http://127.0.0.1:18080/v1/chat/completions || true)"
PREFLIGHT_CODE="$(printf '%s\n' "$PREFLIGHT_HEADERS" | awk 'NR==1{print $2}')"
PREFLIGHT_ORIGIN="$(printf '%s\n' "$PREFLIGHT_HEADERS" | tr -d '\r' | awk -F': ' 'tolower($1)=="access-control-allow-origin"{print $2; exit}')"
KEY="$(cat "$API_KEY_FILE")"
AUTH="$(curl -sS -o /tmp/qwen-models.body -w '%{http_code}' --max-time 10 -H "Authorization: Bearer $KEY" http://127.0.0.1:18080/v1/models || true)"
printf 'LOCAL_UNAUTH_MODELS=%s\n' "$UNAUTH"
printf 'LOCAL_AUTH_MODELS=%s\n' "$AUTH"
printf 'TYPINGMIND_PREFLIGHT=%s origin=%s\n' "$PREFLIGHT_CODE" "$PREFLIGHT_ORIGIN"

log "Running one real authenticated completion"
cat >/tmp/qwen-smoke.json <<'JSON'
{"model":"qwen","messages":[{"role":"user","content":"Reply exactly: CLUSTER ONLINE"}],"max_tokens":16,"temperature":0}
JSON
SMOKE_CODE="$(curl -sS -o /tmp/qwen-smoke.out -w '%{http_code}' --max-time 180 \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $KEY" \
  --data-binary @/tmp/qwen-smoke.json http://127.0.0.1:18080/v1/chat/completions || true)"
printf 'LOCAL_COMPLETION_HTTP=%s\n' "$SMOKE_CODE"
if [ -s /tmp/qwen-smoke.out ]; then
  python3 - <<'PY'
import json
try:
    d=json.load(open('/tmp/qwen-smoke.out'))
    print('LOCAL_COMPLETION_TEXT='+str(d.get('choices',[{}])[0].get('message',{}).get('content','')))
except Exception as e:
    print('LOCAL_COMPLETION_PARSE_ERROR='+str(e))
PY
fi

TS_DNS="$(sudo tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"].get("DNSName","").rstrip("."))')"
PUBLIC_AUTH=""
PUBLIC_PREFLIGHT=""
if [ -n "$TS_DNS" ]; then
  PUBLIC_AUTH="$(curl -sS -o /tmp/qwen-public-models.body -w '%{http_code}' --max-time 15 -H "Authorization: Bearer $KEY" "https://$TS_DNS/v1/models" 2>/dev/null || true)"
  PUBLIC_PREFLIGHT="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -X OPTIONS \
    -H 'Origin: https://www.typingmind.com' -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: Authorization, Content-Type' \
    "https://$TS_DNS/v1/chat/completions" 2>/dev/null || true)"
fi

printf '\n=== QWEN CLUSTER FINAL RESULT ===\n'
printf 'RPC0=%s\n' "$(grep -m1 'RPC0:' /tmp/qwen-rpc-final-probe.out || echo missing)"
printf 'QWEN_HEALTH=200\n'
printf 'LOCAL_UNAUTH_MODELS=%s\n' "$UNAUTH"
printf 'LOCAL_AUTH_MODELS=%s\n' "$AUTH"
printf 'TYPINGMIND_PREFLIGHT=%s origin=%s\n' "$PREFLIGHT_CODE" "$PREFLIGHT_ORIGIN"
printf 'LOCAL_COMPLETION_HTTP=%s\n' "$SMOKE_CODE"
printf 'PUBLIC_MODELS_HTTP=%s\n' "${PUBLIC_AUTH:-not-tested}"
printf 'PUBLIC_PREFLIGHT_HTTP=%s\n' "${PUBLIC_PREFLIGHT:-not-tested}"
printf 'PUBLIC_API=https://%s/v1\n' "$TS_DNS"
printf 'INFINITY_MCP=https://%s:8443/mcp\n' "$TS_DNS"
printf 'PRIVATE_DESKTOP=https://%s:9443\n' "$TS_DNS"
