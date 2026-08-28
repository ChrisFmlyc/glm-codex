#!/usr/bin/env bash
# Starts the LiteLLM proxy. Leave this running in its own terminal.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ -f .env ] || { echo "ERROR: .env not found. Copy .env.example to .env and fill it in."; exit 1; }
set -a; . ./.env; set +a

: "${GLM_BASE_URL:?missing in .env}"
: "${GLM_API_KEY:?missing in .env}"
: "${LITELLM_MASTER_KEY:?missing in .env}"
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
