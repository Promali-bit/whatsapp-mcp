#!/bin/sh
# Starts the WhatsApp bridge, the MCP server and the Caddy proxy in one container.
# If any of them exits, the container exits so Render restarts it.
set -eu

if [ -z "${MCP_SECRET_PATH:-}" ] || [ "${#MCP_SECRET_PATH}" -lt 24 ]; then
  echo "ERROR: set MCP_SECRET_PATH to a long random string (24+ chars) in Render > Environment." >&2
  exit 1
fi

if [ -z "${WHATSAPP_BRIDGE_TOKEN:-}" ]; then
  echo "NOTE: WHATSAPP_BRIDGE_TOKEN not set; the bridge will generate one in its store folder." >&2
fi

# 1. WhatsApp bridge (prints the pairing QR code to the logs on first run).
# Its output goes through a small filter that still prints every line to the
# logs, and also writes the current pairing state to qr-web/state.json, which
# the QR page at /<MCP_SECRET_PATH>/qr renders as a scannable image.
QR_STATE=/app/qr-web/state.json
printf '{"state":"starting","code":""}\n' > "$QR_STATE"
rm -f /tmp/bridge.fifo && mkfifo /tmp/bridge.fifo

mawk -W interactive -v out="$QR_STATE" '
  function save(state, code,   tmp) {
    tmp = out ".tmp"
    printf "{\"state\":\"%s\",\"code\":\"%s\"}\n", state, code > tmp
    close(tmp)
    system("mv " tmp " " out)
  }
  { print; fflush() }
  /Emitting QR code / {
    code = $0
    sub(/.*Emitting QR code /, "", code)
    gsub(/\033\[[0-9;]*m/, "", code)
    gsub(/[^A-Za-z0-9+\/=,@:#._-]/, "", code)
    save("waiting", code)
  }
  /QR code timed out/ { save("expired", "") }
  /Successfully connected and authenticated|Connected to WhatsApp!/ { save("connected", "") }
' < /tmp/bridge.fifo &

cd /app/whatsapp-bridge
./whatsapp-bridge > /tmp/bridge.fifo 2>&1 &
BRIDGE_PID=$!

# Wait for the bridge to create its database (first run waits for the QR scan, so cap it)
i=0
while [ ! -f /app/whatsapp-bridge/store/messages.db ] && [ $i -lt 60 ]; do
  sleep 1; i=$((i+1))
done

# 2. MCP server (streamable HTTP on 127.0.0.1:8000/mcp)
cd /app/whatsapp-mcp-server
uv run --frozen --no-dev main.py &
MCP_PID=$!

# 3. Public proxy on Render's $PORT
caddy run --config /app/Caddyfile --adapter caddyfile &
CADDY_PID=$!

echo "Ready. MCP endpoint: https://<your-service>.onrender.com/${MCP_SECRET_PATH}/mcp" >&2
echo "       QR pairing page: https://<your-service>.onrender.com/${MCP_SECRET_PATH}/qr" >&2

# Exit as soon as any process dies
while kill -0 "$BRIDGE_PID" 2>/dev/null && kill -0 "$MCP_PID" 2>/dev/null && kill -0 "$CADDY_PID" 2>/dev/null; do
  sleep 5
done
echo "A process exited; shutting down so Render restarts the service." >&2
kill "$BRIDGE_PID" "$MCP_PID" "$CADDY_PID" 2>/dev/null || true
exit 1
