# Launches Claude Code against your GLM endpoint via the local LiteLLM proxy.
# Environment is scoped to THIS process, so your normal `claude` is untouched.
#
# Usage: claude-glm.ps1 [-e C:\path	o\.env] [claude args...]
param(
  [Alias("e")][string]$EnvFile,
  [Parameter(ValueFromRemainingArguments=$true)]$Rest
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

function Resolve-EnvFile([string]$explicit) {
  if ($explicit) {
    if (-not (Test-Path $explicit)) { throw "--env file not found: $explicit" }
    return (Resolve-Path $explicit).Path
  }
  $d = (Get-Location).Path
  while ($d) {
    $c = Join-Path $d ".env"
    if (Test-Path $c) { return $c }
    $parent = Split-Path $d -Parent
    if (-not $parent -or $parent -eq $d) { break }
    $d = $parent
  }
  throw "no .env found in $((Get-Location).Path) or any parent. Pass one with -e <path>."
}

$envFilePath = Resolve-EnvFile $EnvFile
Write-Host "using env: $envFilePath" -ForegroundColor DarkGray
Get-Content $envFilePath | ForEach-Object {
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
$env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = if ($env:GLM_MAX_CONTEXT) { $env:GLM_MAX_CONTEXT } else { "1048576" }
$env:CLAUDE_CODE_MAX_OUTPUT_TOKENS  = if ($env:GLM_MAX_OUTPUT)  { $env:GLM_MAX_OUTPUT }  else { "16384" }

Write-Host "Claude Code -> GLM via LiteLLM (context $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS)" -ForegroundColor Green
if ($Rest) { claude @Rest } else { claude }
