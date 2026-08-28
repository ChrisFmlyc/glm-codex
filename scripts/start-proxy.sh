#!/usr/bin/env bash
# Starts the LiteLLM proxy. Leave this running in its own terminal.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ -f .env ] || { echo "ERROR: .env not found. Copy .env.example to .env and fill it in."; exit 1; }
set -a; . ./.env; set +a

: "${GLM_BASE_URL:?missing in .env - set it to your endpoint URL}"
: "${GLM_API_KEY:?missing in .env - set it to your endpoint key}"

# The master key only authenticates Claude Code to THIS local proxy. It never
# leaves the machine, so there is no reason to make the user invent one.
# Generate it once and persist it to .env.
if [ -z "${LITELLM_MASTER_KEY:-}" ] || [ "$LITELLM_MASTER_KEY" = "sk-local-REPLACE_ME" ]; then
  GEN="sk-local-$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))' 2>/dev/null         || python -c 'import secrets; print(secrets.token_urlsafe(24))')"
  if grep -q '^LITELLM_MASTER_KEY=' .env; then
    tmp=$(mktemp); sed "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=$GEN|" .env > "$tmp" && mv "$tmp" .env
  else
    printf '
LITELLM_MASTER_KEY=%s
' "$GEN" >> .env
  fi
  export LITELLM_MASTER_KEY="$GEN"
  echo "Generated a local proxy key and saved it to .env"
fi
PORT="${LITELLM_PORT:-4000}"

VENV="$ROOT/.venv"
if [ ! -x "$VENV/bin/litellm" ]; then
  echo "ERROR: litellm not installed. Run: ./scripts/install.sh"
  exit 1
fi

# LiteLLM prints a Unicode banner; force UTF-8 so it cannot die on encoding.
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

echo "LiteLLM proxy  -> http://127.0.0.1:$PORT"
echo "backend        -> $GLM_BASE_URL"
echo "Ctrl+C to stop."
echo

exec "$VENV/bin/litellm" --config "$ROOT/litellm/config.yaml" --host 127.0.0.1 --port "$PORT"
