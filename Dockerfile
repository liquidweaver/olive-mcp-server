# Node 22 on Debian 12 (bookworm)
FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    MCPO_PORT=8000 \
    VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:/root/.local/bin:${PATH}"

WORKDIR /app

# OS deps: Python, pip, venv, git, curl, envsubst, CA certs
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv \
      git curl gettext-base bash ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# --- Python virtualenv (avoid PEP 668) ---
RUN python3 -m venv "${VIRTUAL_ENV}"

# Python packages into venv
RUN pip install --no-cache-dir \
      uv \
      mcpo \
      "mcp[cli]" \
      mcp-server-calculator \
      sympy pydantic einsteinpy

# Enable pnpm via Corepack
RUN corepack enable

# Build args (pin if desired)
ARG FIREWALLA_REF=main
ARG FRED_REF=main
ARG SYMPY_REF=main
ARG WEB_SEARCH_REF=main

# Clone & build stdio servers (install dev deps to build, then prune)
RUN mkdir -p /tools \
 && git clone --depth 1 --branch "${FIREWALLA_REF}" https://github.com/amittell/firewalla-mcp-server.git /tools/firewalla-mcp-server \
 && cd /tools/firewalla-mcp-server \
 && npm_config_production=false npm ci \
 && npm run build \
 && npm prune --omit=dev \
 && git clone --depth 1 --branch "${FRED_REF}" https://github.com/stefanoamorelli/fred-mcp-server.git /tools/fred-mcp-server \
 && cd /tools/fred-mcp-server \
 && pnpm install --frozen-lockfile --prod=false \
 && pnpm build \
 && pnpm prune --prod \
 && git clone --depth 1 --branch "${SYMPY_REF}" https://github.com/sdiehl/sympy-mcp.git /tools/sympy-mcp \
 && git clone --depth 1 --branch "${WEB_SEARCH_REF}" https://github.com/mrkrsl/web-search-mcp.git /tools/web-search-mcp \
 && cd /tools/web-search-mcp \
 && npm_config_production=false npm ci \
 && npx playwright install-deps chromium firefox \
 && npx playwright install chromium firefox \
 && npm run build

# mcpo config template (env-substituted at runtime)
RUN cat > /app/mcpo.tmpl.json <<'JSON'
{
  "mcpServers": {
    "hf": {
      "type": "streamable-http",
      "url": "https://huggingface.co/mcp",
      "headers": { "Authorization": "Bearer ${HF_TOKEN}" }
    },
    "exa": {
      "type": "streamable-http",
      "url": "https://mcp.exa.ai/mcp?exaApiKey=${EXA_API_KEY}"
    },
    "firewalla": {
      "command": "node",
      "args": ["/tools/firewalla-mcp-server/dist/server.js"],
      "env": {
        "FIREWALLA_MSP_TOKEN": "${FIREWALLA_MSP_TOKEN}",
        "FIREWALLA_MSP_ID": "${FIREWALLA_MSP_ID}",
        "FIREWALLA_BOX_ID": "${FIREWALLA_BOX_ID}"
      }
    },
    "fred": {
      "command": "node",
      "args": ["/tools/fred-mcp-server/build/index.js"],
      "env": { "FRED_API_KEY": "${FRED_API_KEY}" }
    },
    "calculator": {
      "command": "python",
      "args": ["-m", "mcp_server_calculator"]
    },
    "sympy": {
      "command": "mcp",
      "args": ["run", "/tools/sympy-mcp/server.py"]
    },
    "web-search": {
      "command": "node",
      "args": ["/tools/web-search-mcp/dist/index.js"]
    }
  }
}
JSON

# Entrypoint: render config and launch mcpo (from venv)
RUN cat > /usr/local/bin/entrypoint.sh <<'BASH' \
 && chmod +x /usr/local/bin/entrypoint.sh
#!/usr/bin/env bash
set -euo pipefail
: "${MCPO_PORT:=8000}"
envsubst < /app/mcpo.tmpl.json > /app/mcpo.json
echo "==> Starting mcpo on 0.0.0.0:${MCPO_PORT}"
exec mcpo --host 0.0.0.0 --port "${MCPO_PORT}" \
  ${MCPO_API_KEY:+--api-key "$MCPO_API_KEY"} \
  --config /app/mcpo.json --hot-reload
BASH

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --retries=5 \
  CMD curl -fsS "http://127.0.0.1:${MCPO_PORT}/docs" >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]