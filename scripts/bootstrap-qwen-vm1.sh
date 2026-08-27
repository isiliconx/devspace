#!/usr/bin/env bash
set -Eeuo pipefail

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

# Permanent one-command recovery wrapper for disposable Cursor VMs.
# It repairs the native toolchain, runs the proven full bootstrap, fixes
# userspace-Tailscale llama RPC, validates Qwen/API/CORS end to end, and then
# rotates any bootstrap-time credentials so logs do not leave live secrets.
FULL_BOOTSTRAP_COMMIT="a00f7d79d1301c89142c900ae42f71ed5b973ec6"
RPC_FIX_COMMIT="40223005572dd0df138e7ec8ea65c2022f5d23ef"
FINALIZER_COMMIT="84d5789399003a9988485a7a045d01248382d158"
BASE_RAW="https://raw.githubusercontent.com/isiliconx/devspace"
FULL_BOOTSTRAP_URL="$BASE_RAW/$FULL_BOOTSTRAP_COMMIT/scripts/bootstrap-qwen-vm1.sh"
RPC_FIX_URL="$BASE_RAW/$RPC_FIX_COMMIT/scripts/fix-qwen-userspace-rpc.sh"
FINALIZER_URL="$BASE_RAW/$FINALIZER_COMMIT/scripts/finish-qwen-cluster.sh"

log "Repairing complete C/C++ linker toolchain"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl build-essential gcc g++ clang cmake ninja-build pkg-config

GXX_MAJOR="$(g++ -dumpfullversion -dumpversion 2>/dev/null | cut -d. -f1 || true)"
if [ -n "$GXX_MAJOR" ] && apt-cache show "libstdc++-${GXX_MAJOR}-dev" >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y \
    "libstdc++-${GXX_MAJOR}-dev" g++ build-essential
fi

printf 'int main(){return 0;}\n' >/tmp/qwen-cxx-smoke.cpp
g++ /tmp/qwen-cxx-smoke.cpp -o /tmp/qwen-cxx-smoke
/tmp/qwen-cxx-smoke
rm -f /tmp/qwen-cxx-smoke.cpp /tmp/qwen-cxx-smoke

# A failed compiler probe can leave an invalid CMake cache. Preserve the large
# llama.cpp git clone and delete only generated build output.
rm -rf "$HOME/llm/llama.cpp/build"

log "Running full VM1 recovery"
export CC=gcc
export CXX=g++
FULL=/tmp/qwen-full-bootstrap.sh
curl -fsSL --retry 10 --retry-all-errors "$FULL_BOOTSTRAP_URL" -o "$FULL"
chmod 700 "$FULL"
# Redact bootstrap-generated credentials from visible logs. The credentials are
# rotated again below after all validation completes.
bash "$FULL" \
  > >(sed -E 's/^(INFINITY_OWNER_PASSWORD|QWEN_API_KEY)=.*/\1=<redacted; rotated after validation>/') \
  2> >(sed -E 's/^(INFINITY_OWNER_PASSWORD|QWEN_API_KEY)=.*/\1=<redacted; rotated after validation>/' >&2)

log "Fixing userspace-Tailscale RPC transport"
curl -fsSL --retry 10 --retry-all-errors "$RPC_FIX_URL" | bash

log "Validating complete Qwen cluster"
curl -fsSL --retry 10 --retry-all-errors "$FINALIZER_URL" | bash

log "Rotating bootstrap credentials"
CL="$HOME/.qwen-cluster"
umask 077
openssl rand -hex 24 > "$CL/infinity-owner-token.new"
printf 'sk-qwen-%s\n' "$(openssl rand -hex 24)" > "$CL/api.key.new"
mv "$CL/infinity-owner-token.new" "$CL/infinity-owner-token"
mv "$CL/api.key.new" "$CL/api.key"
chmod 600 "$CL/infinity-owner-token" "$CL/api.key"

# Restart only consumers of the rotated credentials.
tmux kill-session -t infinity-rescue 2>/dev/null || true
tmux new-session -d -s infinity-rescue \
  "while true; do '$CL/run-infinity.sh' >> '$CL/logs/infinity.log' 2>&1; sleep 2; done"
tmux kill-session -t qwen-api-gateway 2>/dev/null || true
tmux new-session -d -s qwen-api-gateway \
  "while true; do '$CL/api/start-gateway.sh' >> '$CL/logs/api-gateway.log' 2>&1; sleep 2; done"
sleep 3

KEY="$(cat "$CL/api.key")"
UNAUTH="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/v1/models || true)"
AUTH="$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY" http://127.0.0.1:18080/v1/models || true)"
PREFLIGHT="$(curl -sS -o /dev/null -w '%{http_code}' -X OPTIONS -H 'Origin: https://www.typingmind.com' -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: authorization,content-type' http://127.0.0.1:18080/v1/chat/completions || true)"

printf '\n=== PERMANENT QWEN BOOTSTRAP COMPLETE ===\n'
printf 'QWEN_HEALTH=%s\n' "$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:18082/health || true)"
printf 'LOCAL_UNAUTH_MODELS=%s\n' "$UNAUTH"
printf 'LOCAL_AUTH_MODELS=%s\n' "$AUTH"
printf 'TYPINGMIND_PREFLIGHT=%s\n' "$PREFLIGHT"
printf 'TAILSCALE_DNS=%s\n' "$(sudo tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"].get("DNSName","").rstrip("."))')"
printf 'SECRETS=rotated-and-stored-locally\n'
printf 'QWEN_KEY_FILE=%s\n' "$CL/api.key"
printf 'INFINITY_OWNER_TOKEN_FILE=%s\n' "$CL/infinity-owner-token"
printf '\nUse the local files above when configuring clients. Do not paste their contents into chat.\n'
