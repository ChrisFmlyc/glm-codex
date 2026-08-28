#!/usr/bin/env bash
# One-time setup: creates a virtualenv and installs LiteLLM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null || { echo "ERROR: $PY not found. Install Python 3.10+."; exit 1; }

echo "Checking the LiteLLM release before installing..."
LATEST=$(curl -s https://pypi.org/pypi/litellm/json | "$PY" -c "import sys,json; print(json.load(sys.stdin)['info']['version'])")
case "$LATEST" in
  1.82.7|1.82.8)
    echo "REFUSING: litellm $LATEST is a known-compromised release."
    echo "Pin a different version manually."
    exit 1;;
esac
echo "  latest is $LATEST - proceeding."

"$PY" -m venv .venv
./.venv/bin/python -m pip install --upgrade pip
./.venv/bin/python -m pip install "litellm[proxy]"

echo
echo "Installed. Next:"
echo "  1. cp .env.example .env   and fill in your endpoint URL + key"
echo "  2. ./scripts/start-proxy.sh"
echo "  3. ./scripts/claude-glm.sh"
