# Starts the LiteLLM proxy. Leave this running in its own terminal.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path "$root\.env")) {
  Write-Host "ERROR: .env not found. Copy .env.example to .env and fill it in." -ForegroundColor Red
  exit 1
}

# load .env into THIS process only
Get-Content "$root\.env" | ForEach-Object {
  if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
    [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim(), "Process")
  }
}

foreach ($v in @("GLM_BASE_URL","GLM_API_KEY")) {
  if (-not [Environment]::GetEnvironmentVariable($v)) { throw "$v missing from .env" }
}

# The master key only authenticates Claude Code to THIS local proxy. It never
# leaves the machine, so generate it once and persist it to .env.
if (-not $env:LITELLM_MASTER_KEY -or $env:LITELLM_MASTER_KEY -eq "sk-local-REPLACE_ME") {
  $bytes = New-Object byte[] 18
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $gen = "sk-local-" + [Convert]::ToBase64String($bytes).Replace("+","-").Replace("/","_").TrimEnd("=")
  $envFile = "$root\.env"
  $content = Get-Content $envFile
  if ($content -match '^LITELLM_MASTER_KEY=') {
    $content = $content -replace '^LITELLM_MASTER_KEY=.*', "LITELLM_MASTER_KEY=$gen"
    Set-Content -Path $envFile -Value $content -Encoding ascii
  } else {
    Add-Content -Path $envFile -Value "LITELLM_MASTER_KEY=$gen" -Encoding ascii
  }
  $env:LITELLM_MASTER_KEY = $gen
  Write-Host "Generated a local proxy key and saved it to .env" -ForegroundColor DarkGray
}
$port = if ($env:LITELLM_PORT) { $env:LITELLM_PORT } else { "4000" }

$exe = "$root\.venv\Scripts\litellm.exe"
if (-not (Test-Path $exe)) {
  Write-Host "ERROR: litellm not installed. Run: .\scripts\install.ps1" -ForegroundColor Red
  exit 1
}

# LiteLLM prints a Unicode banner; the default cp1252 console encoding kills
# startup with UnicodeEncodeError. Force UTF-8.
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

Write-Host "LiteLLM proxy  -> http://127.0.0.1:$port" -ForegroundColor Green
Write-Host "backend        -> $env:GLM_BASE_URL" -ForegroundColor DarkGray
Write-Host "Ctrl+C to stop.`n"

& $exe --config "$root\litellm\config.yaml" --host 127.0.0.1 --port $port
