#!/usr/bin/env bash
# Starts the LiteLLM proxy. Leave running in its own terminal.
#
# Usage: start-proxy.sh [-e /path/to/.env]
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

: "${GLM_BASE_URL:?missing in env file - set it to your endpoint URL}"
: "${GLM_API_KEY:?missing in env file - set it to your endpoint key}"
PORT="${LITELLM_PORT:-4000}"

VENV="$ROOT/.venv"
[ -x "$VENV/bin/litellm" ] || { echo "ERROR: litellm not installed. Run: ./scripts/install.sh"; exit 1; }

if [ -z "${LITELLM_MASTER_KEY:-}" ] || [ "$LITELLM_MASTER_KEY" = "sk-local-REPLACE_ME" ]; then
  GEN="sk-local-$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))' 2>/dev/null || python -c 'import secrets;print(secrets.token_urlsafe(24))')"
  if grep -q '^LITELLM_MASTER_KEY=' "$ENV_FILE"; then
    tmp="$(mktemp)"; sed "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=$GEN|" "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
  else
    printf '
LITELLM_MASTER_KEY=%s
' "$GEN" >> "$ENV_FILE"
  fi
  export LITELLM_MASTER_KEY="$GEN"
  echo "Generated a local proxy key and saved it to $ENV_FILE"
fi

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
echo "LiteLLM proxy  -> http://127.0.0.1:$PORT"
echo "backend        -> $GLM_BASE_URL"
echo "Ctrl+C to stop."
exec "$VENV/bin/litellm" --config "$ROOT/litellm/config.yaml" --host 127.0.0.1 --port "$PORT"
