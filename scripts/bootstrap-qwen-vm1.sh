#!/usr/bin/env bash
set -Eeuo pipefail

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn(){ printf '\n[WARN] %s\n' "$*" >&2; }

USER_HOME="${HOME:-/home/ubuntu}"
CLUSTER="$USER_HOME/.qwen-cluster"
LOGS="$CLUSTER/logs"
MODELS="$USER_HOME/models/orcarouter-qwen3.8-27b"
LLAMA="$USER_HOME/llm/llama.cpp"
AUDIO="$USER_HOME/audio/whisper.cpp"
mkdir -p "$CLUSTER" "$LOGS" "$MODELS" "$USER_HOME/llm" "$USER_HOME/audio"

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required on this Cursor VM" >&2
  exit 1
fi

log "Installing base packages + complete C++ toolchain"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl git jq tmux openssl build-essential g++ clang cmake ninja-build \
  python3 python3-venv netcat-openbsd pkg-config ffmpeg cron

# Cursor cloud images can contain clang/c++ without the matching libstdc++ development
# symlink. Prove that a C++ binary can actually LINK, not merely compile.
printf 'int main(){return 0;}\n' > /tmp/qwen-cxx-smoke.cpp
if ! c++ /tmp/qwen-cxx-smoke.cpp -o /tmp/qwen-cxx-smoke >/tmp/qwen-cxx-smoke.log 2>&1; then
  warn "C++ compiler exists but cannot link; repairing matching libstdc++ development package"
  GXX_MAJOR="$(g++ -dumpfullversion -dumpversion 2>/dev/null | cut -d. -f1 || true)"
  if [ -n "$GXX_MAJOR" ]; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y \
      build-essential g++ "libstdc++-${GXX_MAJOR}-dev"
  else
    sudo DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y build-essential g++
  fi
  c++ /tmp/qwen-cxx-smoke.cpp -o /tmp/qwen-cxx-smoke
fi
rm -f /tmp/qwen-cxx-smoke.cpp /tmp/qwen-cxx-smoke /tmp/qwen-cxx-smoke.log

if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)" -lt 22 ]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
fi

# ---------- Tailscale rescue plane ----------
log "Installing / starting Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

if ! sudo tailscale status >/dev/null 2>&1; then
  if command -v systemctl >/dev/null 2>&1 && [ "$(ps -p 1 -o comm= 2>/dev/null || true)" = "systemd" ]; then
    sudo systemctl enable --now tailscaled || true
  fi
fi

if ! sudo tailscale status >/dev/null 2>&1; then
  sudo mkdir -p /var/lib/tailscale /var/run/tailscale
  tmux kill-session -t qwen-tailscaled 2>/dev/null || true
  tmux new-session -d -s qwen-tailscaled \
    "sudo tailscaled --tun=userspace-networking --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock >> '$LOGS/tailscaled.log' 2>&1"
  sleep 3
fi

TS_STATE="$(sudo tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true)"
if [ "$TS_STATE" != "Running" ]; then
  log "Authenticate this VM to the SAME tailnet as qwen-vm2 when the URL appears"
  sudo tailscale up --hostname=qwen-vm1 --ssh --accept-dns=true
else
  sudo tailscale set --ssh || true
fi

TS_JSON="$(sudo tailscale status --json)"
TS_DNS="$(printf '%s' "$TS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"].get("DNSName","").rstrip("."))')"
TS_IP="$(sudo tailscale ip -4 | head -n1)"
[ -n "$TS_DNS" ] || { echo "Could not determine Tailscale DNS name" >&2; exit 1; }

# ---------- Private desktop rescue ----------
log "Configuring private desktop rescue if noVNC is present"
NOVNC_PORT=""
for p in 6080 6081 6901 5800; do
  if nc -z -w1 127.0.0.1 "$p" >/dev/null 2>&1; then NOVNC_PORT="$p"; break; fi
done
if [ -z "$NOVNC_PORT" ]; then
  NOVNC_PORT="$(pgrep -af 'websockify|novnc' 2>/dev/null | sed -nE 's/.*(--listen[ =]|:)([0-9]{4,5}).*/\2/p' | head -n1 || true)"
fi
if [ -n "$NOVNC_PORT" ] && nc -z -w1 127.0.0.1 "$NOVNC_PORT" >/dev/null 2>&1; then
  sudo tailscale serve --bg --yes --https=9443 "http://127.0.0.1:$NOVNC_PORT" || warn "Private desktop Serve setup failed"
  DESKTOP_URL="https://$TS_DNS:9443"
else
  DESKTOP_URL="not-detected"
fi

# ---------- Infinity MCP ----------
log "Restoring Infinity MCP"
INF_DIR="$USER_HOME/infinity-codex"
INF_CMD=""
INF_FLAVOR="infinity"
if [ -x "$INF_DIR/dist/cli.js" ] || [ -f "$INF_DIR/dist/cli.js" ]; then
  INF_CMD="node $INF_DIR/dist/cli.js"
else
  rm -rf "$INF_DIR.tmp" 2>/dev/null || true
  CLONED=0
  if GIT_TERMINAL_PROMPT=0 git clone --depth 1 https://github.com/isiliconx/infinity-codex.git "$INF_DIR.tmp" >/dev/null 2>&1; then
    CLONED=1
  elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && gh repo clone isiliconx/infinity-codex "$INF_DIR.tmp" -- --depth 1 >/dev/null 2>&1; then
    CLONED=1
  elif [ -n "${GITHUB_TOKEN:-}" ] && git clone --depth 1 "https://x-access-token:${GITHUB_TOKEN}@github.com/isiliconx/infinity-codex.git" "$INF_DIR.tmp" >/dev/null 2>&1; then
    CLONED=1
  fi
  if [ "$CLONED" = 1 ]; then
    rm -rf "$INF_DIR"
    mv "$INF_DIR.tmp" "$INF_DIR"
    cd "$INF_DIR"
    if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)" -lt 22 ]; then
      curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    fi
    npm install
    npm run build
    INF_CMD="node $INF_DIR/dist/cli.js"
  else
    warn "Latest private infinity-codex could not be cloned with this VM's GitHub credentials; using public devspace as a temporary rescue MCP."
    PUB_INF="$USER_HOME/devspace-rescue"
    rm -rf "$PUB_INF"
    git clone --depth 1 https://github.com/isiliconx/devspace.git "$PUB_INF"
    cd "$PUB_INF"
    if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)" -lt 22 ]; then
      curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    fi
    npm install
    npm run build
    INF_DIR="$PUB_INF"
    INF_CMD="node $PUB_INF/dist/cli.js"
    INF_FLAVOR="devspace"
  fi
fi

OWNER_FILE="$CLUSTER/infinity-owner-token"
if [ ! -s "$OWNER_FILE" ]; then
  umask 077
  openssl rand -hex 24 > "$OWNER_FILE"
fi
chmod 600 "$OWNER_FILE"

INF_PUBLIC="https://$TS_DNS:8443"
if [ "$INF_FLAVOR" = "infinity" ]; then
cat > "$CLUSTER/run-infinity.sh" <<EOF2
#!/usr/bin/env bash
set -Eeuo pipefail
export INFINITY_OAUTH_OWNER_TOKEN="\$(cat '$OWNER_FILE')"
export INFINITY_ALLOWED_ROOTS="$USER_HOME"
export INFINITY_PUBLIC_BASE_URL="$INF_PUBLIC"
export INFINITY_TRUST_PROXY=1
export INFINITY_TOOL_MODE=full
export HOST=127.0.0.1
export PORT=7676
cd "$INF_DIR"
exec $INF_CMD serve
EOF2
else
cat > "$CLUSTER/run-infinity.sh" <<EOF2
#!/usr/bin/env bash
set -Eeuo pipefail
export DEVSPACE_OAUTH_OWNER_TOKEN="\$(cat '$OWNER_FILE')"
export DEVSPACE_ALLOWED_ROOTS="$USER_HOME"
export DEVSPACE_PUBLIC_BASE_URL="$INF_PUBLIC"
export DEVSPACE_TRUST_PROXY=1
export DEVSPACE_TOOL_MODE=full
export HOST=127.0.0.1
export PORT=7676
cd "$INF_DIR"
exec $INF_CMD serve
EOF2
fi
chmod 700 "$CLUSTER/run-infinity.sh"

tmux kill-session -t infinity-rescue 2>/dev/null || true
tmux new-session -d -s infinity-rescue \
  "while true; do '$CLUSTER/run-infinity.sh' >> '$LOGS/infinity.log' 2>&1; sleep 2; done"
sleep 4
sudo tailscale funnel --bg --yes --https=8443 http://127.0.0.1:7676 || warn "Infinity Funnel setup failed"

# ---------- Exact proven llama.cpp ----------
log "Restoring llama.cpp"
LLAMA_COMMIT="0d9ceae1e38291035605613ab41a8f5e693d6fcd"
if [ ! -d "$LLAMA/.git" ]; then
  rm -rf "$LLAMA"
  git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA"
fi
cd "$LLAMA"
git fetch --all --tags --prune
git checkout -f "$LLAMA_COMMIT"
# A failed CMake compiler probe leaves an incomplete build tree; clear only the build output.
rm -rf build
cmake -S . -B build -G Ninja -DGGML_RPC=ON -DGGML_NATIVE=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j4

# ---------- Exact Qwen files by known SHA ----------
log "Downloading exact Qwen Q4_K_M + vision projector (resumable)"
MODEL="$MODELS/Qwen3.8-27B-Uncensored-Q4_K_M.gguf"
MMPROJ="$MODELS/mmproj-Qwen3.8-27B-Uncensored-f16.gguf"
MODEL_SHA="3445102e9cde5d562508642c100a2f5ac3368a5a3f748442811d7a95daee3bec"
MMPROJ_SHA="add205b7bfdb3f71f6da36b0a82aa20928dd829a920878c602628cdfbebc5288"
MODEL_URL="https://huggingface.co/chimingw/Qwen3.8-27B-Uncensored-OrcaRouter-GGUF/resolve/main/Qwen3.8-27B-Uncensored-OrcaRouter-Q4_K_M.gguf?download=true"
MMPROJ_URL="https://huggingface.co/chimingw/Qwen3.8-27B-Uncensored-OrcaRouter-GGUF/resolve/main/AUX/mmproj-Qwen3.8-27B-Uncensored-OrcaRouter-F16.gguf?download=true"

need_download(){ [ ! -f "$1" ] || [ "$(sha256sum "$1" | awk '{print $1}')" != "$2" ]; }
if need_download "$MODEL" "$MODEL_SHA"; then
  curl -fL --retry 20 --retry-all-errors --continue-at - -o "$MODEL" "$MODEL_URL"
fi
if need_download "$MMPROJ" "$MMPROJ_SHA"; then
  curl -fL --retry 20 --retry-all-errors --continue-at - -o "$MMPROJ" "$MMPROJ_URL"
fi
printf '%s  %s\n' "$MODEL_SHA" "$MODEL" | sha256sum -c -
printf '%s  %s\n' "$MMPROJ_SHA" "$MMPROJ" | sha256sum -c -

# ---------- VM2 worker over private Tailscale TCP ----------
log "Reattaching VM2 worker over Tailscale"
VM2_IP="$(sudo tailscale status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); peers=d.get("Peer",{}).values(); print(next((p.get("TailscaleIPs",[""])[0] for p in peers if p.get("HostName")=="qwen-vm2" or p.get("DNSName","").startswith("qwen-vm2.")),""))')"
VM2_READY=0
if [ -n "$VM2_IP" ]; then
  if sudo tailscale ssh ubuntu@qwen-vm2 'bash -s' <<'VM2BOOT'
set -Eeuo pipefail
CL="$HOME/.qwen-cluster"
mkdir -p "$CL/logs"
BIN="$HOME/llm/llama.cpp/build/bin/ggml-rpc-server"
[ -x "$BIN" ] || { echo "VM2 missing ggml-rpc-server" >&2; exit 2; }
cat > "$CL/vm2-rpc-watch.sh" <<'EOS'
#!/usr/bin/env bash
set -u
BIN="$HOME/llm/llama.cpp/build/bin/ggml-rpc-server"
LOG="$HOME/.qwen-cluster/logs/qwen-rpc.log"
while true; do
  if ! pgrep -f '^.*/ggml-rpc-server .* -p 50053' >/dev/null 2>&1; then
    tmux kill-session -t qwen-rpc 2>/dev/null || true
    tmux new-session -d -s qwen-rpc "$BIN -H 127.0.0.1 -p 50053 -t 4 -c >> '$LOG' 2>&1"
    sleep 2
  fi
  sleep 5
done
EOS
chmod 700 "$CL/vm2-rpc-watch.sh"
tmux kill-session -t qwen-rpc 2>/dev/null || true
tmux kill-session -t qwen-vm2-watch 2>/dev/null || true
tmux new-session -d -s qwen-rpc "$BIN -H 127.0.0.1 -p 50053 -t 4 -c >> '$CL/logs/qwen-rpc.log' 2>&1"
sudo tailscale serve --bg --yes --tcp=50053 tcp://127.0.0.1:50053
tmux new-session -d -s qwen-vm2-watch "$CL/vm2-rpc-watch.sh >> '$CL/logs/qwen-vm2-watch.log' 2>&1"
sleep 2
pgrep -f '^.*/ggml-rpc-server .* -p 50053' >/dev/null
VM2BOOT
  then
    sleep 2
    if nc -z -w5 "$VM2_IP" 50053 >/dev/null 2>&1; then VM2_READY=1; fi
  else
    warn "Tailscale SSH to VM2 failed; Qwen will wait for VM2 instead of overloading VM1."
  fi
else
  warn "qwen-vm2 is not visible in the tailnet yet; Qwen will wait for it."
fi

# ---------- Authenticated OpenAI gateway ----------
log "Installing authenticated API gateway"
API_KEY_FILE="$CLUSTER/api.key"
if [ ! -s "$API_KEY_FILE" ]; then
  umask 077
  printf 'sk-qwen-%s\n' "$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9_-' | head -c 48)" > "$API_KEY_FILE"
fi
chmod 600 "$API_KEY_FILE"

mkdir -p "$CLUSTER/api"
cat > "$CLUSTER/api/gateway.mjs" <<'NODE'
import http from 'node:http';
import fs from 'node:fs';
const key = fs.readFileSync(process.env.QWEN_API_KEY_FILE, 'utf8').trim();
const allowedOrigin = o => {
  if (!o) return null;
  try { const u = new URL(o); return (u.protocol === 'https:' && (u.hostname === 'typingmind.com' || u.hostname === 'www.typingmind.com' || u.hostname.endsWith('.typingmind.com'))) ? o : null; }
  catch { return null; }
};
const cors = (req,res) => {
  const o = allowedOrigin(req.headers.origin);
  if (o) {
    res.setHeader('Access-Control-Allow-Origin', o);
    res.setHeader('Vary', 'Origin');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type');
    res.setHeader('Access-Control-Max-Age', '86400');
  }
};
const json = (res, code, body) => { res.statusCode=code; res.setHeader('content-type','application/json'); res.setHeader('cache-control','no-store'); res.end(JSON.stringify(body)); };
const server = http.createServer((req,res) => {
  cors(req,res);
  if (req.method === 'OPTIONS') { res.statusCode=204; return res.end(); }
  if (req.url === '/health') {
    const p=http.request({host:'127.0.0.1',port:18082,path:'/health',method:'GET'},r=>{r.resume(); json(res,r.statusCode===200?200:503,{status:r.statusCode===200?'ok':'unavailable'});});
    p.setTimeout(2500,()=>p.destroy(new Error('timeout'))); p.on('error',()=>json(res,503,{status:'unavailable'})); return p.end();
  }
  if (!req.url?.startsWith('/v1/')) return json(res,404,{error:{message:'Not found',type:'not_found'}});
  if (req.headers.authorization !== `Bearer ${key}`) return json(res,401,{error:{message:'Invalid API key',type:'invalid_request_error',code:'invalid_api_key'}});
  const headers={...req.headers,host:'127.0.0.1:18082'};
  delete headers['access-control-allow-origin'];
  const up=http.request({host:'127.0.0.1',port:18082,path:req.url,method:req.method,headers},ur=>{
    res.statusCode=ur.statusCode||502;
    for (const [k,v] of Object.entries(ur.headers)) if (v!==undefined && !k.toLowerCase().startsWith('access-control-')) res.setHeader(k,v);
    cors(req,res); ur.pipe(res);
  });
  up.setTimeout(30*60*1000,()=>up.destroy(new Error('upstream timeout'));
  up.on('error',()=>{ if (!res.headersSent) json(res,502,{error:{message:'Upstream unavailable',type:'upstream_error'}}); else res.destroy(); });
  req.pipe(up);
});
server.listen(18080,'127.0.0.1');
NODE

cat > "$CLUSTER/api/start-gateway.sh" <<EOF2
#!/usr/bin/env bash
export QWEN_API_KEY_FILE="$API_KEY_FILE"
exec node "$CLUSTER/api/gateway.mjs"
EOF2
chmod 700 "$CLUSTER/api/start-gateway.sh"
tmux kill-session -t qwen-api-gateway 2>/dev/null || true
tmux new-session -d -s qwen-api-gateway \
  "while true; do '$CLUSTER/api/start-gateway.sh' >> '$LOGS/api-gateway.log' 2>&1; sleep 2; done"
sudo tailscale funnel --bg --yes --https=443 http://127.0.0.1:18080 || warn "Qwen API Funnel setup failed"

# ---------- Qwen watchdog ----------
log "Starting Qwen watchdog"
cat > "$CLUSTER/qwen-stack-watch.sh" <<EOF2
#!/usr/bin/env bash
set -u
BIN="$LLAMA/build/bin"
MODEL="$MODEL"
MMPROJ="$MMPROJ"
VM2_IP="$VM2_IP"
LOG="$LOGS/qwen-server.log"
rpc_ok(){ [ -n "\$VM2_IP" ] && nc -z -w3 "\$VM2_IP" 50053 >/dev/null 2>&1; }
qwen_running(){ pgrep -f '^.*/llama-server .*--port 18082' >/dev/null 2>&1; }
while true; do
  if qwen_running; then sleep 10; continue; fi
  if ! rpc_ok; then sleep 10; continue; fi
  tmux kill-session -t qwen-2node-64k-mm 2>/dev/null || true
  tmux new-session -d -s qwen-2node-64k-mm \
    "\$BIN/llama-server -m '\$MODEL' --mmproj '\$MMPROJ' --no-mmproj-offload --rpc '\$VM2_IP:50053' -ngl 32 -c 65536 --alias qwen -np 1 --cache-type-k q4_0 --cache-type-v q4_0 --no-cache-prompt --no-cache-idle-slots -t 4 --reasoning off --host 127.0.0.1 --port 18082 --metrics --no-webui >> '\$LOG' 2>&1"
  sleep 20
done
EOF2
chmod 700 "$CLUSTER/qwen-stack-watch.sh"
tmux kill-session -t qwen-stack-watch 2>/dev/null || true
tmux new-session -d -s qwen-stack-watch "$CLUSTER/qwen-stack-watch.sh >> '$LOGS/qwen-stack-watch.log' 2>&1"

# ---------- Whisper resident ASR (best-effort; never block core recovery) ----------
log "Restoring Whisper ASR (best effort)"
(
  set -e
  if [ ! -d "$AUDIO/.git" ]; then git clone https://github.com/ggerganov/whisper.cpp.git "$AUDIO"; fi
  cd "$AUDIO"
  git fetch --all --tags --prune
  git checkout -f 97811330
  rm -rf build
  cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
  cmake --build build -j4
  [ -f models/ggml-base.en.bin ] || bash models/download-ggml-model.sh base.en
  tmux kill-session -t qwen-whisper-asr 2>/dev/null || true
  tmux new-session -d -s qwen-whisper-asr "$AUDIO/build/bin/whisper-server -m '$AUDIO/models/ggml-base.en.bin' --host 127.0.0.1 --port 18083 >> '$LOGS/whisper.log' 2>&1"
) || warn "Whisper restore failed; Qwen/Infinity recovery continues."

# ---------- Restart helper / crontab ----------
cat > "$CLUSTER/start-after-reboot.sh" <<EOF2
#!/usr/bin/env bash
set +e
[ -x "$CLUSTER/run-infinity.sh" ] && tmux has-session -t infinity-rescue 2>/dev/null || tmux new-session -d -s infinity-rescue "while true; do '$CLUSTER/run-infinity.sh' >> '$LOGS/infinity.log' 2>&1; sleep 2; done"
tmux has-session -t qwen-api-gateway 2>/dev/null || tmux new-session -d -s qwen-api-gateway "while true; do '$CLUSTER/api/start-gateway.sh' >> '$LOGS/api-gateway.log' 2>&1; sleep 2; done"
tmux has-session -t qwen-stack-watch 2>/dev/null || tmux new-session -d -s qwen-stack-watch "$CLUSTER/qwen-stack-watch.sh >> '$LOGS/qwen-stack-watch.log' 2>&1"
EOF2
chmod 700 "$CLUSTER/start-after-reboot.sh"
( crontab -l 2>/dev/null | grep -vF "$CLUSTER/start-after-reboot.sh"; echo "@reboot $CLUSTER/start-after-reboot.sh" ) | crontab - || true

sleep 3

log "Bootstrap complete"
printf '\n=== RESCUE / API INFO ===\n'
printf 'TAILSCALE_IP=%s\n' "$TS_IP"
printf 'TAILSCALE_DNS=%s\n' "$TS_DNS"
printf 'PRIVATE_DESKTOP=%s\n' "$DESKTOP_URL"
printf 'INFINITY_MCP=%s/mcp\n' "$INF_PUBLIC"
printf 'INFINITY_OWNER_PASSWORD=%s\n' "$(cat "$OWNER_FILE")"
printf 'QWEN_API_BASE=https://%s/v1\n' "$TS_DNS"
printf 'QWEN_CHAT_ENDPOINT=https://%s/v1/chat/completions\n' "$TS_DNS"
printf 'QWEN_MODEL=qwen\n'
printf 'QWEN_API_KEY=%s\n' "$(cat "$API_KEY_FILE")"
printf 'VM2_IP=%s\n' "${VM2_IP:-not-found}"
printf 'VM2_RPC=%s\n' "$( [ "$VM2_READY" = 1 ] && echo ready || echo waiting )"
printf '\nTypingMind: Endpoint=https://%s/v1/chat/completions ; Authorization=Bearer <QWEN_API_KEY above> ; Context=65536\n' "$TS_DNS"
printf '\nDo not close the terminal until this message appears. Model download/build can take a while.\n'
