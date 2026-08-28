#!/usr/bin/env bash
# Launches Claude Code against your GLM endpoint via the local LiteLLM proxy.
# Environment is scoped to THIS process, so your normal `claude` is untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ -f .env ] || { echo "ERROR: .env not found. Copy .env.example to .env and fill it in."; exit 1; }
set -a; . ./.env; set +a

PORT="${LITELLM_PORT:-4000}"

if ! curl -sf "http://127.0.0.1:$PORT/health/liveliness" >/dev/null 2>&1; then
  echo "ERROR: proxy not reachable on port $PORT."
  echo "Start it first:  ./scripts/start-proxy.sh"
  exit 1
fi

export ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
export ANTHROPIC_AUTH_TOKEN="$LITELLM_MASTER_KEY"
export ANTHROPIC_MODEL="glm53"
export ANTHROPIC_SMALL_FAST_MODEL="glm53-small"

# Claude Code resolves the context window from its OWN model list and never
# asks the proxy. An unrecognised name gets a small assumed window and
# aggressive auto-compaction. These are the only way to tell it the truth.
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="${GLM_MAX_CONTEXT:-1048576}"
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="${GLM_MAX_OUTPUT:-16384}"

echo "Claude Code -> GLM via LiteLLM (context ${CLAUDE_CODE_MAX_CONTEXT_TOKENS})"
exec claude "$@"
