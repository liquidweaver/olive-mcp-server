# Python 3.11 + Node.js 22 (slim)
FROM nikolaik/python-nodejs:python3.11-nodejs22-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    UV_LINK_MODE=copy \
    MCPO_PORT=8000 \
    PATH=/root/.local/bin:$PATH

WORKDIR /app

# OS deps: git for cloning, curl for healthcheck, envsubst for templating
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl gettext-base bash ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Python deps: mcpo + CLI + demo servers
RUN pip install --no-cache-dir \
      uv \
      mcpo \
      "mcp[cli]" \
      mcp-server-calculator \
      sympy pydantic einsteinpy

# Enable pnpm (via Corepack)
RUN corepack enable

# Build args: pin branches/SHAs if you want
ARG FIREWALLA_REF=main
ARG FRED_REF=main
ARG SYMPY_REF=main

# Clone & build stdio servers
# - Install dev deps for build, then prune to production
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
 && git clone --depth 1 --branch "${SYMPY_REF}" https://github.com/sdiehl/sympy-mcp.git /tools/sympy-mcp

# mcpo config template (rendered with envsubst at runtime)
RUN cat > /app/mcpo.tmpl.json <<'JSON'
{
  "mcpServers": {
    "hf": {
      "type": "streamable-http",
      "url": "https://huggingface.co/mcp",
      "headers": {
        "Authorization": "Bearer ${HF_TOKEN}"
      }
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
    }
  }
}
JSON

# Entrypoint: render config and launch mcpo
RUN cat > /usr/local/bin/entrypoint.sh <<'BASH' \
 && chmod +x /usr/local/bin/entrypoint.sh
#!/usr/bin/env bash
set -euo pipefail
: "${MCPO_PORT:=8000}"

# Render /app/mcpo.json from template with env vars
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