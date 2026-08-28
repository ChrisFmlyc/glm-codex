#!/usr/bin/env bash
# Launches OpenAI Codex CLI against your GLM endpoint - NO proxy needed.
# vLLM serves the Responses API natively, which is what Codex speaks, so
# Codex connects straight to your pod.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ -f .env ] || { echo "ERROR: .env not found. Copy .env.example to .env and fill it in."; exit 1; }
set -a; . ./.env; set +a

: "${GLM_BASE_URL:?missing in .env - set it to your endpoint URL}"
: "${GLM_API_KEY:?missing in .env - set it to your endpoint key}"
MODEL="${GLM_MODEL_NAME:-glm53-uncensored}"
CTX="${GLM_MAX_CONTEXT:-1048576}"
OUT="${GLM_MAX_OUTPUT:-16384}"

command -v codex >/dev/null 2>&1 || {
  echo "ERROR: codex not installed. Install it with:  npm install -g @openai/codex"
  exit 1
}

# Scoped Codex home so we never touch the user's global ~/.codex config.
export CODEX_HOME="$ROOT/.codex-home"
mkdir -p "$CODEX_HOME"

cat > "$CODEX_HOME/config.toml" <<TOML
# Generated from .env by scripts/codex-glm.sh - do not edit by hand.
model = "$MODEL"
model_provider = "glm"

# Top-level, BEFORE the provider table (TOML tables capture everything after
# them). Without this Codex warns "metadata not found" and assumes a small
# window. Note: Codex currently caps custom providers near 258K regardless
# (upstream bug), so you may not get the full value.
model_context_window = $CTX
model_max_output_tokens = $OUT

[model_providers.glm]
name = "GLM (self-hosted)"
env_key = "GLM_API_KEY"
base_url = "$GLM_BASE_URL"
wire_api = "responses"
TOML

echo "Codex -> GLM at $GLM_BASE_URL (model $MODEL)"
exec codex "$@"
