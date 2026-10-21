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

# 1. WhatsApp bridge (prints the pairing QR code to the logs on first run)
cd /app/whatsapp-bridge
./whatsapp-bridge &
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

# Exit as soon as any process dies
while kill -0 "$BRIDGE_PID" 2>/dev/null && kill -0 "$MCP_PID" 2>/dev/null && kill -0 "$CADDY_PID" 2>/dev/null; do
  sleep 5
done
echo "A process exited; shutting down so Render restarts the service." >&2
kill "$BRIDGE_PID" "$MCP_PID" "$CADDY_PID" 2>/dev/null || true
exit 1
