# Starts the LiteLLM proxy. Leave running in its own terminal.
#
# Usage: start-proxy.ps1 [-e C:\path	o\.env]
param(
  [Alias("e")][string]$EnvFile,
  [Parameter(Position=0, ValueFromRemainingArguments=$true)]$Rest
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

function Resolve-EnvFile([string]$explicit, [string]$repoRoot) {
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
  # final fallback: the repo's own .env (next to the scripts)
  $repoEnv = Join-Path $repoRoot ".env"
  if (Test-Path $repoEnv) { return $repoEnv }
  throw "no .env found in $((Get-Location).Path), any parent, or the repo ($repoRoot). Pass one with -e <path>."
}

$envFilePath = Resolve-EnvFile $EnvFile $root
Write-Host "using env: $envFilePath" -ForegroundColor DarkGray
Get-Content $envFilePath | ForEach-Object {
  if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
    [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim(), "Process")
  }
}

if (-not $env:GLM_BASE_URL) { throw "GLM_BASE_URL missing from env file" }
if (-not $env:GLM_API_KEY)  { throw "GLM_API_KEY missing from env file" }
$port = if ($env:LITELLM_PORT) { $env:LITELLM_PORT } else { "4000" }

$exe = "$root\.venv\Scripts\litellm.exe"
if (-not (Test-Path $exe)) { throw "litellm not installed. Run: .\scripts\install.ps1" }

# The master key only authenticates Claude Code to THIS local proxy. Generate
# one on first run and persist it to the resolved env file.
if (-not $env:LITELLM_MASTER_KEY -or $env:LITELLM_MASTER_KEY -eq "sk-local-REPLACE_ME") {
  $bytes = New-Object byte[] 18
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $gen = "sk-local-" + [Convert]::ToBase64String($bytes).Replace("+","-").Replace("/","_").TrimEnd("=")
  $content = Get-Content $envFilePath
  if ($content -match '^LITELLM_MASTER_KEY=') {
    $content = $content -replace '^LITELLM_MASTER_KEY=.*', "LITELLM_MASTER_KEY=$gen"
    Set-Content -Path $envFilePath -Value $content -Encoding ascii
  } else {
    Add-Content -Path $envFilePath -Value "LITELLM_MASTER_KEY=$gen" -Encoding ascii
  }
  $env:LITELLM_MASTER_KEY = $gen
  Write-Host "Generated a local proxy key and saved it to $envFilePath" -ForegroundColor DarkGray
}

$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
Write-Host "LiteLLM proxy  -> http://127.0.0.1:$port" -ForegroundColor Green
Write-Host "backend        -> $env:GLM_BASE_URL" -ForegroundColor DarkGray
Write-Host "Ctrl+C to stop.`n"
& $exe --config "$root\litellm\config.yaml" --host 127.0.0.1 --port $port
