#!/usr/bin/env bash
set -Eeuo pipefail

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn(){ printf '\n[WARN] %s\n' "$*" >&2; }

ROOT="$HOME/.qwen-cluster"
LLAMA_DIR="$HOME/llm/llama.cpp"
LLAMA_COMMIT="0d9ceae1e38291035605613ab41a8f5e693d6fcd"
MODEL_DIR="$HOME/models/orcarouter-qwen3.8-27b"
MODEL="$MODEL_DIR/Qwen3.8-27B-Uncensored-Q4_K_M.gguf"
MMPROJ="$MODEL_DIR/mmproj-Qwen3.8-27B-Uncensored-f16.gguf"
MODEL_SHA="3445102e9cde5d562508642c100a2f5ac3368a5a3f748442811d7a95daee3bec"
MMPROJ_SHA="add205b7bfdb3f71f6da36b0a82aa20928dd829a920878c602628cdfbebc5288"

log "Installing base packages and C++ toolchain"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl git jq tmux cmake ninja-build clang build-essential g++ \
  libstdc++-14-dev pkg-config python3 python3-venv python3-pip ffmpeg

if ! printf 'int main(){return 0;}\n' >/tmp/qwen-cxx-smoke.cpp || ! c++ /tmp/qwen-cxx-smoke.cpp -o /tmp/qwen-cxx-smoke; then
  warn "C++ linker still cannot find libstdc++; attempting compiler-specific package repair"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y g++ libstdc++-14-dev build-essential
  c++ /tmp/qwen-cxx-smoke.cpp -o /tmp/qwen-cxx-smoke
fi
rm -f /tmp/qwen-cxx-smoke.cpp /tmp/qwen-cxx-smoke

mkdir -p "$ROOT/logs" "$MODEL_DIR" "$HOME/llm"

log "Ensuring Tailscale rescue access"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if ! tailscale status >/dev/null 2>&1; then
  sudo tailscale up --hostname=qwen-vm1
fi
sudo tailscale set --ssh || true
TS_DNS="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("Self",{}).get("DNSName","").rstrip("."))' || true)"
TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"

log "Restoring Infinity"
INF_DIR="$HOME/infinity-codex"
if [ ! -d "$INF_DIR/.git" ]; then
  if git clone https://github.com/isiliconx/infinity-codex.git "$INF_DIR" 2>/dev/null; then :; else
    warn "Private infinity-codex clone unavailable; using public devspace rescue MCP"
    git clone https://github.com/isiliconx/devspace.git "$INF_DIR"
  fi
fi
cd "$INF_DIR"
npm install
npm run build
if [ -n "$TS_DNS" ]; then
  PUB="https://$TS_DNS"
  sudo tailscale funnel --bg --yes http://127.0.0.1:7676 || true
else
  PUB="http://127.0.0.1:7676"
fi
mkdir -p "$HOME/.config/infinity"
if [ ! -s "$HOME/.config/infinity/auth.json" ] && [ ! -s "$HOME/.infinity/auth.json" ]; then
  OWNER="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"
else
  OWNER=""
fi
# Initialize only if config is missing; preserve existing auth/config when present.
if [ ! -s "$HOME/.config/infinity/config.json" ] && [ ! -s "$HOME/.infinity/config.json" ]; then
  INFINITY_OAUTH_OWNER_TOKEN="${OWNER:-$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)}" INFINITY_ALLOWED_ROOTS="$HOME" INFINITY_PUBLIC_BASE_URL="$PUB" node dist/cli.js setup >/tmp/infinity-setup.out 2>&1 || true
fi
tmux kill-session -t infinity-rescue 2>/dev/null || true
tmux new-session -d -s infinity-rescue "cd '$INF_DIR' && while true; do INFINITY_PUBLIC_BASE_URL='$PUB' INFINITY_TRUST_PROXY=1 node dist/cli.js serve >> '$ROOT/logs/infinity-rescue.log' 2>&1; sleep 2; done"

log "Restoring llama.cpp"
if [ ! -d "$LLAMA_DIR/.git" ]; then
  git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
fi
cd "$LLAMA_DIR"
git fetch --all --tags --prune
git checkout "$LLAMA_COMMIT"
rm -rf build
CC=clang CXX=clang++ cmake -S . -B build -G Ninja -DGGML_RPC=ON -DLLAMA_CURL=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"

log "Ensuring exact Qwen model files"
# Keep existing verified files. If absent, leave an explicit warning rather than downloading an unverified replacement source.
if [ -f "$MODEL" ]; then
  echo "$MODEL_SHA  $MODEL" | sha256sum -c -
else
  warn "Main GGUF is not present on this new VM. The bootstrap restored the controller/tooling, but the exact model must be copied/downloaded from the previously verified source before Qwen can start."
fi
if [ -f "$MMPROJ" ]; then
  echo "$MMPROJ_SHA  $MMPROJ" | sha256sum -c -
else
  warn "Vision projector is not present on this new VM."
fi

log "Discovering VM2 RPC over Tailscale"
VM2_IP="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); peers=d.get("Peer",{}); xs=[]
for p in peers.values():
 n=(p.get("HostName") or p.get("DNSName") or "").lower()
 if "qwen-vm2" in n:
  xs += p.get("TailscaleIPs",[])
print(next((x for x in xs if ":" not in x),""))' || true)"
VM2_RPC="0"
if [ -n "$VM2_IP" ] && timeout 2 bash -c "</dev/tcp/$VM2_IP/50053" 2>/dev/null; then VM2_RPC="1"; fi

log "Starting authenticated API gateway when model is available"
API_KEY_FILE="$ROOT/api.key"
if [ ! -s "$API_KEY_FILE" ]; then
  umask 077
  python3 - <<'PY' > "$API_KEY_FILE"
import secrets
print(secrets.token_urlsafe(32))
PY
fi
chmod 600 "$API_KEY_FILE"

cat > "$ROOT/gateway.py" <<'PY'
import http.server, http.client, os
KEY=open(os.path.expanduser('~/.qwen-cluster/api.key')).read().strip()
UP=('127.0.0.1',18082)
ALLOWED={'https://www.typingmind.com','https://typingmind.com'}
class H(http.server.BaseHTTPRequestHandler):
    def cors(self):
        o=self.headers.get('Origin','')
        if o in ALLOWED: self.send_header('Access-Control-Allow-Origin',o)
        self.send_header('Access-Control-Allow-Methods','GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers','Authorization, Content-Type')
        self.send_header('Cache-Control','no-store')
    def do_OPTIONS(self):
        self.send_response(204); self.cors(); self.end_headers()
    def _go(self):
        if self.path=='/health':
            try:
                c=http.client.HTTPConnection(*UP,timeout=2); c.request('GET','/health'); r=c.getresponse(); b=r.read(); self.send_response(r.status); self.send_header('Content-Type','application/json'); self.cors(); self.end_headers(); self.wfile.write(b)
            except Exception:
                self.send_response(503); self.send_header('Content-Type','application/json'); self.cors(); self.end_headers(); self.wfile.write(b'{"status":"unavailable"}')
            return
        if not self.path.startswith('/v1/'):
            self.send_response(404); self.cors(); self.end_headers(); return
        if self.headers.get('Authorization','') != 'Bearer '+KEY:
            self.send_response(401); self.send_header('Content-Type','application/json'); self.cors(); self.end_headers(); self.wfile.write(b'{"error":{"message":"Invalid API key","type":"invalid_request_error","code":"invalid_api_key"}}'); return
        try:
            n=int(self.headers.get('Content-Length','0') or 0); body=self.rfile.read(n) if n else None
            c=http.client.HTTPConnection(*UP,timeout=1800)
            hdr={k:v for k,v in self.headers.items() if k.lower() not in {'host','content-length','connection'}}
            c.request(self.command,self.path,body=body,headers=hdr); r=c.getresponse(); self.send_response(r.status)
            for k,v in r.getheaders():
                if k.lower() not in {'connection','transfer-encoding','access-control-allow-origin'}: self.send_header(k,v)
            self.cors(); self.end_headers()
            while True:
                b=r.read(65536)
                if not b: break
                self.wfile.write(b); self.wfile.flush()
        except Exception:
            self.send_response(503); self.send_header('Content-Type','application/json'); self.cors(); self.end_headers(); self.wfile.write(b'{"error":{"message":"Upstream unavailable","type":"unavailable_error"}}')
    do_GET=_go; do_POST=_go
    def log_message(self,*a): pass
http.server.ThreadingHTTPServer(('127.0.0.1',18080),H).serve_forever()
PY

tmux kill-session -t qwen-api-gateway 2>/dev/null || true
tmux new-session -d -s qwen-api-gateway "python3 '$ROOT/gateway.py' >> '$ROOT/logs/gateway.log' 2>&1"

if [ -f "$MODEL" ]; then
  log "Starting Qwen server"
  RPC_ARGS=()
  if [ "$VM2_RPC" = 1 ]; then RPC_ARGS=(--rpc "$VM2_IP:50053" -ngl 32); else RPC_ARGS=(-ngl 0); fi
  tmux kill-session -t qwen-server 2>/dev/null || true
  tmux new-session -d -s qwen-server "'$LLAMA_DIR/build/bin/llama-server' -m '$MODEL' ${MMPROJ:+--mmproj '$MMPROJ'} --no-mmproj-offload ${RPC_ARGS[*]} -c 65536 -np 1 --cache-type-k q4_0 --cache-type-v q4_0 --no-cache-prompt --no-cache-idle-slots -t 4 --reasoning off --host 127.0.0.1 --port 18082 --metrics --no-webui >> '$ROOT/logs/qwen-server.log' 2>&1"
fi

log "Installing watchdog"
cat > "$ROOT/watch.sh" <<EOF
#!/usr/bin/env bash
while sleep 10; do
  pgrep -f '$ROOT/gateway.py' >/dev/null || tmux new-session -d -s qwen-api-gateway "python3 '$ROOT/gateway.py' >> '$ROOT/logs/gateway.log' 2>&1"
  pgrep -f 'node dist/cli.js serve' >/dev/null || tmux new-session -d -s infinity-rescue "cd '$INF_DIR' && while true; do INFINITY_PUBLIC_BASE_URL='$PUB' INFINITY_TRUST_PROXY=1 node dist/cli.js serve >> '$ROOT/logs/infinity-rescue.log' 2>&1; sleep 2; done"
done
EOF
chmod +x "$ROOT/watch.sh"
tmux kill-session -t qwen-bootstrap-watch 2>/dev/null || true
tmux new-session -d -s qwen-bootstrap-watch "$ROOT/watch.sh"

DESKTOP=""
for p in 6080 6081 5901 5900; do
  if timeout 1 bash -c "</dev/tcp/127.0.0.1/$p" 2>/dev/null; then
    if [ -n "$TS_DNS" ] && [ "$p" = 6080 -o "$p" = 6081 ]; then
      sudo tailscale serve --bg --https=8443 "http://127.0.0.1:$p" || true
      DESKTOP="https://$TS_DNS:8443"
    fi
    break
  fi
done

printf '\n=== RESCUE / API INFO ===\n'
printf 'TAILSCALE_IP=%s\n' "$TS_IP"
printf 'TAILSCALE_DNS=%s\n' "$TS_DNS"
printf 'PRIVATE_DESKTOP=%s\n' "$DESKTOP"
printf 'INFINITY_MCP=%s/mcp\n' "$PUB"
printf 'QWEN_API_BASE=%s\n' "http://127.0.0.1:18080/v1"
printf 'QWEN_CHAT_ENDPOINT=%s\n' "http://127.0.0.1:18080/v1/chat/completions"
printf 'VM2_IP=%s\n' "$VM2_IP"
printf 'VM2_RPC=%s\n' "$VM2_RPC"
printf 'MODEL_PRESENT=%s\n' "$([ -f "$MODEL" ] && echo 1 || echo 0)"
printf 'MMPROJ_PRESENT=%s\n' "$([ -f "$MMPROJ" ] && echo 1 || echo 0)"
printf 'NOTE=API key and Infinity owner token remain stored locally and are not printed by this bootstrap.\n'
