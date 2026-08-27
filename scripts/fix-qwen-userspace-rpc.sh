#!/usr/bin/env bash
set -Eeuo pipefail

CL="$HOME/.qwen-cluster"
LOGS="$CL/logs"
BIN="$HOME/llm/llama.cpp/build/bin"
MODEL="$HOME/models/orcarouter-qwen3.8-27b/Qwen3.8-27B-Uncensored-Q4_K_M.gguf"
MMPROJ="$HOME/models/orcarouter-qwen3.8-27b/mmproj-Qwen3.8-27B-Uncensored-f16.gguf"
mkdir -p "$CL" "$LOGS"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

log "Installing local TCP bridge helper"
sudo apt-get update -y >/dev/null
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y socat netcat-openbsd >/dev/null

command -v tailscale >/dev/null
[ -x "$BIN/llama-server" ]
[ -f "$MODEL" ]
[ -f "$MMPROJ" ]

log "Checking qwen-vm2 over Tailscale"
sudo tailscale status | grep -E 'qwen-vm2|100\.82\.222\.125' || true
sudo tailscale ping --c=1 qwen-vm2 || true

cat > "$CL/run-rpc-bridge.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exec socat TCP-LISTEN:50054,bind=127.0.0.1,reuseaddr,fork EXEC:'sudo -n tailscale nc qwen-vm2 50053',nofork
EOF
chmod 700 "$CL/run-rpc-bridge.sh"

tmux kill-session -t qwen-rpc-bridge 2>/dev/null || true
tmux new-session -d -s qwen-rpc-bridge "$CL/run-rpc-bridge.sh >> '$LOGS/qwen-rpc-bridge.log' 2>&1"

for _ in $(seq 1 20); do
  nc -z -w1 127.0.0.1 50054 >/dev/null 2>&1 && break
  sleep 1
done
nc -z -w2 127.0.0.1 50054 >/dev/null 2>&1 || { echo 'RPC bridge listener failed' >&2; tail -50 "$LOGS/qwen-rpc-bridge.log" >&2 || true; exit 1; }

log "Probing llama RPC through userspace Tailscale bridge"
set +e
timeout 15 "$BIN/llama-server" --rpc 127.0.0.1:50054 --list-devices > /tmp/qwen-rpc-probe.out 2>&1
set -e
cat /tmp/qwen-rpc-probe.out | sed -n '1,12p'
if ! grep -q 'RPC0:' /tmp/qwen-rpc-probe.out; then
  echo 'VM2 RPC did not appear as RPC0. Recent bridge log:' >&2
  tail -50 "$LOGS/qwen-rpc-bridge.log" >&2 || true
  exit 2
fi

log "Installing corrected Qwen watchdog"
cat > "$CL/qwen-stack-watch.sh" <<EOF
#!/usr/bin/env bash
set -u
BIN="$BIN"
MODEL="$MODEL"
MMPROJ="$MMPROJ"
LOG="$LOGS/qwen-server.log"
bridge_ok(){ nc -z -w2 127.0.0.1 50054 >/dev/null 2>&1 && sudo tailscale ping --c=1 qwen-vm2 >/dev/null 2>&1; }
qwen_running(){ pgrep -f '^.*/llama-server .*--port 18082' >/dev/null 2>&1; }
while true; do
  if qwen_running; then sleep 10; continue; fi
  if ! bridge_ok; then sleep 10; continue; fi
  tmux kill-session -t qwen-2node-64k-mm 2>/dev/null || true
  tmux new-session -d -s qwen-2node-64k-mm \
    "\$BIN/llama-server -m '\$MODEL' --mmproj '\$MMPROJ' --no-mmproj-offload --rpc 127.0.0.1:50054 -ngl 32 -c 65536 --alias qwen -np 1 --cache-type-k q4_0 --cache-type-v q4_0 --no-cache-prompt --no-cache-idle-slots -t 4 --reasoning off --host 127.0.0.1 --port 18082 --metrics --no-webui >> '\$LOG' 2>&1"
  sleep 25
done
EOF
chmod 700 "$CL/qwen-stack-watch.sh"

# Ensure reboot helper also restores the local bridge.
if [ -f "$CL/start-after-reboot.sh" ]; then
  if ! grep -q 'qwen-rpc-bridge' "$CL/start-after-reboot.sh"; then
    tmp="$(mktemp)"
    {
      head -n 2 "$CL/start-after-reboot.sh"
      echo "tmux has-session -t qwen-rpc-bridge 2>/dev/null || tmux new-session -d -s qwen-rpc-bridge \"$CL/run-rpc-bridge.sh >> '$LOGS/qwen-rpc-bridge.log' 2>&1\""
      tail -n +3 "$CL/start-after-reboot.sh"
    } > "$tmp"
    mv "$tmp" "$CL/start-after-reboot.sh"
    chmod 700 "$CL/start-after-reboot.sh"
  fi
fi

tmux kill-session -t qwen-stack-watch 2>/dev/null || true
pkill -f '^.*/llama-server .*--port 18082' 2>/dev/null || true
tmux new-session -d -s qwen-stack-watch "$CL/qwen-stack-watch.sh >> '$LOGS/qwen-stack-watch.log' 2>&1"

log "Waiting for Qwen to load"
healthy=0
for i in $(seq 1 72); do
  code="$(curl -sS -o /tmp/qwen-health.body -w '%{http_code}' --max-time 3 http://127.0.0.1:18082/health 2>/dev/null || true)"
  if [ "$code" = "200" ]; then healthy=1; break; fi
  if [ $((i % 6)) -eq 0 ]; then printf 'still loading (%ss)\n' "$((i*5))"; fi
  sleep 5
done

printf '\n=== QWEN RPC FIX RESULT ===\n'
printf 'RPC_BRIDGE=127.0.0.1:50054 -> tailscale nc qwen-vm2:50053\n'
printf 'RPC0=%s\n' "$(grep -m1 'RPC0:' /tmp/qwen-rpc-probe.out || echo missing)"
printf 'QWEN_HEALTH=%s\n' "$( [ "$healthy" = 1 ] && echo 200 || echo waiting )"
sudo tailscale ping --c=1 qwen-vm2 2>&1 | tail -n 2 || true
if [ "$healthy" != 1 ]; then
  echo 'Qwen is not healthy yet. Recent model log:'
  tail -40 "$LOGS/qwen-server.log" 2>/dev/null || true
fi
