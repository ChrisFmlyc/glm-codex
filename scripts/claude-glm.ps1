# Launches Claude Code against your GLM endpoint via the local LiteLLM proxy.
# Environment is scoped to THIS process, so your normal `claude` is untouched.
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

$port = if ($env:LITELLM_PORT) { $env:LITELLM_PORT } else { "4000" }

try {
  $null = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health/liveliness" -TimeoutSec 5 -UseBasicParsing
} catch {
  Write-Host "ERROR: proxy not reachable on port $port." -ForegroundColor Red
  Write-Host "Start it first:  .\scripts\start-proxy.ps1"
  exit 1
}

$env:ANTHROPIC_BASE_URL         = "http://127.0.0.1:$port"
$env:ANTHROPIC_AUTH_TOKEN       = $env:LITELLM_MASTER_KEY
$env:ANTHROPIC_MODEL            = "glm53"
$env:ANTHROPIC_SMALL_FAST_MODEL = "glm53-small"

# Claude Code resolves the context window from its OWN model list and never
# asks the proxy. An unrecognised name gets a small assumed window and
# aggressive auto-compaction. These are the only way to tell it the truth.
$env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = if ($env:GLM_MAX_CONTEXT) { $env:GLM_MAX_CONTEXT } else { "1048576" }
$env:CLAUDE_CODE_MAX_OUTPUT_TOKENS  = if ($env:GLM_MAX_OUTPUT)  { $env:GLM_MAX_OUTPUT }  else { "16384" }

Write-Host "Claude Code -> GLM via LiteLLM (context $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS)" -ForegroundColor Green
claude @args
