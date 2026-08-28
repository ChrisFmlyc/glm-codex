#!/usr/bin/env bash
# Launches Claude Code against your GLM endpoint via the local LiteLLM proxy.
# Environment is scoped to THIS process, so your normal `claude` is untouched.
#
# Usage: claude-glm.sh [-e /path/to/.env] [claude args...]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- resolve the .env file: -e/--env PATH, else nearest .env from cwd upward ---
ENV_FILE=""
FWD=()
while [ $# -gt 0 ]; do
  case "$1" in
    -e|--env) ENV_FILE="${2:-}"; shift 2 ;;
    *) FWD+=("$1"); shift ;;
  esac
done
set -- "${FWD[@]:-}"

if [ -n "$ENV_FILE" ]; then
  [ -f "$ENV_FILE" ] || { echo "ERROR: --env file not found: $ENV_FILE"; exit 1; }
else
  d="$PWD"
  while :; do
    if [ -f "$d/.env" ]; then ENV_FILE="$d/.env"; break; fi
    parent="$(dirname "$d")"; [ "$parent" = "$d" ] && break; d="$parent"
  done
  [ -n "$ENV_FILE" ] || { echo "ERROR: no .env found in $PWD or any parent directory."; echo "Pass one with:  $(basename "$0") -e /path/to/.env"; exit 1; }
fi
echo "using env: $ENV_FILE" >&2
set -a; . "$ENV_FILE"; set +a

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
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="${GLM_MAX_CONTEXT:-1048576}"
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="${GLM_MAX_OUTPUT:-16384}"

echo "Claude Code -> GLM via LiteLLM (context ${CLAUDE_CODE_MAX_CONTEXT_TOKENS})"
exec claude "$@"
