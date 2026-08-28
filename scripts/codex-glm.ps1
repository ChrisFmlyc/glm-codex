# Launches OpenAI Codex CLI against your GLM endpoint - NO proxy needed.
# vLLM serves the Responses API natively, which is what Codex speaks, so
# Codex connects straight to your pod.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path "$root\.env")) {
  Write-Host "ERROR: .env not found. Copy .env.example to .env and fill it in." -ForegroundColor Red
  exit 1
}

Get-Content "$root\.env" | ForEach-Object {
  if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
    [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim(), "Process")
  }
}

if (-not $env:GLM_BASE_URL) { throw "GLM_BASE_URL missing from .env" }
if (-not $env:GLM_API_KEY)  { throw "GLM_API_KEY missing from .env" }
$model = if ($env:GLM_MODEL_NAME) { $env:GLM_MODEL_NAME } else { "glm53-uncensored" }

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
  Write-Host "ERROR: codex not installed. Install it with:  npm install -g @openai/codex" -ForegroundColor Red
  exit 1
}

# Scoped Codex home so we never touch the user's global ~/.codex config.
$env:CODEX_HOME = "$root\.codex-home"
New-Item -ItemType Directory -Force -Path $env:CODEX_HOME | Out-Null

$config = @"
# Generated from .env by scripts/codex-glm.ps1 - do not edit by hand.
model = "$model"
model_provider = "glm"

[model_providers.glm]
name = "GLM (self-hosted)"
env_key = "GLM_API_KEY"
base_url = "$env:GLM_BASE_URL"
wire_api = "responses"
"@
Set-Content -Path "$env:CODEX_HOME\config.toml" -Value $config -Encoding ascii

Write-Host "Codex -> GLM at $env:GLM_BASE_URL (model $model)" -ForegroundColor Green
codex @args
