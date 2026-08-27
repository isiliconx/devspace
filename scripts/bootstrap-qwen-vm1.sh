#!/usr/bin/env bash
set -Eeuo pipefail

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

# Hotfix wrapper for fresh Cursor Ubuntu images where clang/c++ exists but the
# libstdc++ development linker files are missing. After repairing the native
# toolchain, resume the pinned full bootstrap that already contains the proven
# Tailscale, Infinity, Qwen, VM2 RPC, gateway, watchdog, model and Whisper logic.
FULL_BOOTSTRAP_COMMIT="a00f7d79d1301c89142c900ae42f71ed5b973ec6"
FULL_BOOTSTRAP_URL="https://raw.githubusercontent.com/isiliconx/devspace/${FULL_BOOTSTRAP_COMMIT}/scripts/bootstrap-qwen-vm1.sh"

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

# The previous failed compiler probe leaves an incomplete CMake build tree.
# Preserve the 424 MiB git clone and delete only generated build output.
rm -rf "$HOME/llm/llama.cpp/build"

log "Toolchain fixed; resuming full VM1 recovery"
export CC=gcc
export CXX=g++
curl -fsSL --retry 10 --retry-all-errors "$FULL_BOOTSTRAP_URL" | bash
