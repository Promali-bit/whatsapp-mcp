# Dockerfile for running whatsapp-mcp on Render (or any container host).
# Runs three things in one container:
#   1. Go WhatsApp bridge   -> 127.0.0.1:8080 (private)
#   2. Python MCP server    -> 127.0.0.1:8000 (private, streamable HTTP at /mcp)
#   3. Caddy reverse proxy  -> 0.0.0.0:$PORT  (public, only reachable via a secret path)

# ---------- 1. Build the Go bridge ----------
FROM golang:1.26-bookworm AS bridge-build
WORKDIR /src
COPY whatsapp-bridge/go.mod whatsapp-bridge/go.sum ./
RUN go mod download
COPY whatsapp-bridge/ ./
# go-sqlite3 needs CGO
RUN CGO_ENABLED=1 go build -o /out/whatsapp-bridge .

# ---------- 2. Grab the Caddy binary ----------
FROM caddy:2 AS caddy

# ---------- 3. Runtime ----------
FROM python:3.12-slim-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg ca-certificates tini \
 && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
# The official caddy binary carries a file capability (cap_net_bind_service),
# which Render's runtime refuses to exec ("Operation not permitted"). We listen
# on a high port, so copy the bytes into a fresh file to drop the capability.
COPY --from=caddy /usr/bin/caddy /tmp/caddy-src
RUN cat /tmp/caddy-src > /usr/local/bin/caddy \
 && chmod 0755 /usr/local/bin/caddy \
 && rm /tmp/caddy-src

WORKDIR /app

# Python MCP server + deps (installed at build time so startup is fast)
COPY whatsapp-mcp-server/ ./whatsapp-mcp-server/
RUN cd whatsapp-mcp-server && uv sync --frozen --no-dev

# Go bridge binary. It keeps its data in ./store relative to its working dir,
# i.e. /app/whatsapp-bridge/store  <- mount the Render persistent disk HERE.
COPY --from=bridge-build /out/whatsapp-bridge ./whatsapp-bridge/whatsapp-bridge
RUN mkdir -p ./whatsapp-bridge/store

COPY Caddyfile start.sh ./
RUN chmod +x start.sh

ENV WHATSAPP_BRIDGE_PORT=8080 \
    WHATSAPP_API_URL=http://127.0.0.1:8080/api \
    WHATSAPP_DB_PATH=/app/whatsapp-bridge/store/messages.db \
    WHATSMEOW_DB_PATH=/app/whatsapp-bridge/store/whatsapp.db \
    WHATSAPP_MCP_TRANSPORT=http \
    WHATSAPP_MCP_HOST=127.0.0.1 \
    WHATSAPP_MCP_PORT=8000 \
    WEBHOOK_ENABLED=false \
    PORT=10000

EXPOSE 10000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/start.sh"]
