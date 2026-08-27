#!/usr/bin/env bash
set -Eeuo pipefail

CL="$HOME/.qwen-cluster"
LOGS="$CL/logs"
RUN_INF="$CL/run-infinity.sh"
MUX="$CL/public-mux.mjs"
MUX_RUN="$CL/run-public-mux.sh"
mkdir -p "$LOGS"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }

command -v tailscale >/dev/null || fail "tailscale missing"
command -v node >/dev/null || fail "node missing"
[ -x "$RUN_INF" ] || fail "$RUN_INF missing"

TS_DNS="$(sudo tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"].get("DNSName","").rstrip("."))')"
[ -n "$TS_DNS" ] || fail "could not determine Tailscale DNS name"
PUBLIC="https://$TS_DNS"

log "Moving Infinity OAuth public base URL to standard HTTPS 443"
cp -f "$RUN_INF" "$RUN_INF.bak-before-443"
if grep -q '^export INFINITY_PUBLIC_BASE_URL=' "$RUN_INF"; then
  sed -i -E "s#^export INFINITY_PUBLIC_BASE_URL=.*#export INFINITY_PUBLIC_BASE_URL=\"$PUBLIC\"#" "$RUN_INF"
elif grep -q '^export DEVSPACE_PUBLIC_BASE_URL=' "$RUN_INF"; then
  sed -i -E "s#^export DEVSPACE_PUBLIC_BASE_URL=.*#export DEVSPACE_PUBLIC_BASE_URL=\"$PUBLIC\"#" "$RUN_INF"
else
  fail "could not find Infinity/Devspace public-base setting in $RUN_INF"
fi

tmux kill-session -t infinity-rescue 2>/dev/null || true
tmux new-session -d -s infinity-rescue \
  "while true; do '$RUN_INF' >> '$LOGS/infinity.log' 2>&1; sleep 2; done"

for _ in $(seq 1 30); do
  code="$(curl -sS -o /tmp/inf-oauth.json -w '%{http_code}' --max-time 2 http://127.0.0.1:7676/.well-known/oauth-authorization-server 2>/dev/null || true)"
  [ "$code" = "200" ] && break
  sleep 1
done
[ "${code:-}" = "200" ] || { tail -60 "$LOGS/infinity.log" >&2 || true; fail "Infinity did not restart cleanly"; }
if grep -q ':8443' /tmp/inf-oauth.json; then
  cat /tmp/inf-oauth.json >&2
  fail "OAuth metadata still references :8443"
fi

log "Installing standard-443 public multiplexer"
cat > "$MUX" <<'NODE'
import http from 'node:http';

const server = http.createServer((req, res) => {
  const url = req.url || '/';
  const qwen = url === '/health' || url.startsWith('/v1/');
  const port = qwen ? 18080 : 7676;
  const headers = { ...req.headers };
  headers.host = req.headers.host || 'localhost';

  const up = http.request({
    host: '127.0.0.1',
    port,
    method: req.method,
    path: url,
    headers,
  }, (ur) => {
    res.statusCode = ur.statusCode || 502;
    for (const [k, v] of Object.entries(ur.headers)) {
      if (v !== undefined) res.setHeader(k, v);
    }
    ur.pipe(res);
  });

  up.setTimeout(30 * 60 * 1000, () => up.destroy(new Error('upstream timeout')));
  up.on('error', (err) => {
    if (!res.headersSent) {
      res.statusCode = 502;
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ error: 'upstream unavailable', detail: err.message }));
    } else {
      res.destroy();
    }
  });
  req.pipe(up);
});

server.listen(18079, '127.0.0.1', () => {
  console.log('public mux listening on 127.0.0.1:18079');
});
NODE
node --check "$MUX"

cat > "$MUX_RUN" <<EOF
#!/usr/bin/env bash
exec node "$MUX"
EOF
chmod 700 "$MUX_RUN"

tmux kill-session -t qwen-public-mux 2>/dev/null || true
tmux new-session -d -s qwen-public-mux \
  "while true; do '$MUX_RUN' >> '$LOGS/public-mux.log' 2>&1; sleep 2; done"

for _ in $(seq 1 20); do
  nc -z -w1 127.0.0.1 18079 >/dev/null 2>&1 && break
  sleep 1
done
nc -z -w2 127.0.0.1 18079 >/dev/null 2>&1 || { tail -60 "$LOGS/public-mux.log" >&2 || true; fail "public mux did not listen"; }

log "Validating both services through the local mux"
LOCAL_OAUTH="$(curl -sS -o /tmp/mux-oauth.json -w '%{http_code}' --max-time 5 http://127.0.0.1:18079/.well-known/oauth-authorization-server || true)"
LOCAL_MCP="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:18079/mcp || true)"
LOCAL_QWEN_UNAUTH="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:18079/v1/models || true)"
KEY="$(cat "$CL/api.key")"
LOCAL_QWEN_AUTH="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer $KEY" http://127.0.0.1:18079/v1/models || true)"
PREFLIGHT="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X OPTIONS -H 'Origin: https://www.typingmind.com' -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: authorization,content-type' http://127.0.0.1:18079/v1/chat/completions || true)"

[ "$LOCAL_OAUTH" = "200" ] || fail "local mux OAuth expected 200, got $LOCAL_OAUTH"
[ "$LOCAL_MCP" = "401" ] || fail "local mux MCP expected 401, got $LOCAL_MCP"
[ "$LOCAL_QWEN_UNAUTH" = "401" ] || fail "local mux Qwen unauth expected 401, got $LOCAL_QWEN_UNAUTH"
[ "$LOCAL_QWEN_AUTH" = "200" ] || fail "local mux Qwen auth expected 200, got $LOCAL_QWEN_AUTH"
[ "$PREFLIGHT" = "204" ] || fail "TypingMind preflight expected 204, got $PREFLIGHT"
if grep -q ':8443' /tmp/mux-oauth.json; then fail "mux OAuth metadata still references :8443"; fi

log "Switching public port 443 to the multiplexer"
sudo tailscale funnel --bg --yes --https=443 http://127.0.0.1:18079
sleep 4

PUBLIC_OAUTH="$(curl -sS -o /tmp/public-oauth.json -w '%{http_code}' --max-time 15 "$PUBLIC/.well-known/oauth-authorization-server" 2>/dev/null || true)"
PUBLIC_MCP="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$PUBLIC/mcp" 2>/dev/null || true)"
PUBLIC_QWEN="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$PUBLIC/v1/models" 2>/dev/null || true)"
if [ "$PUBLIC_OAUTH" = "200" ] && grep -q ':8443' /tmp/public-oauth.json; then
  fail "public OAuth metadata still references :8443"
fi

# Make the mux survive VM reboot/restart. Funnel --bg persists in Tailscale state.
START="$CL/start-after-reboot.sh"
if [ -f "$START" ] && ! grep -q 'qwen-public-mux' "$START"; then
  tmp="$(mktemp)"
  {
    head -n 2 "$START"
    echo "tmux has-session -t qwen-public-mux 2>/dev/null || tmux new-session -d -s qwen-public-mux \"while true; do '$MUX_RUN' >> '$LOGS/public-mux.log' 2>&1; sleep 2; done\""
    tail -n +3 "$START"
  } > "$tmp"
  mv "$tmp" "$START"
  chmod 700 "$START"
fi

printf '\n=== STANDARD HTTPS MCP FIX ===\n'
printf 'NEW_MCP=%s/mcp\n' "$PUBLIC"
printf 'QWEN_API=%s/v1\n' "$PUBLIC"
printf 'LOCAL_OAUTH=%s\n' "$LOCAL_OAUTH"
printf 'LOCAL_MCP=%s\n' "$LOCAL_MCP"
printf 'LOCAL_QWEN_UNAUTH=%s\n' "$LOCAL_QWEN_UNAUTH"
printf 'LOCAL_QWEN_AUTH=%s\n' "$LOCAL_QWEN_AUTH"
printf 'TYPINGMIND_PREFLIGHT=%s\n' "$PREFLIGHT"
printf 'PUBLIC_OAUTH=%s\n' "$PUBLIC_OAUTH"
printf 'PUBLIC_MCP=%s\n' "$PUBLIC_MCP"
printf 'PUBLIC_QWEN_UNAUTH=%s\n' "$PUBLIC_QWEN"
printf 'OLD_8443=left-enabled-temporarily-for-rollback\n'
